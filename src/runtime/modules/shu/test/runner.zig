// shu:test 内部：suite/test 树与执行状态，run() 时构建 JS 对象树供 JS 侧 runner 脚本执行
// 与 node:test 语义对齐：describe/it、beforeAll/afterAll/beforeEach/afterEach、skip/skipIf/todo/only

const std = @import("std");
const jsc = @import("jsc");

/// 单条测试用例：name、回调、选项（skip/todo/only/skipIf）
pub const TestEntry = struct {
    name: []const u8,
    fn_ref: jsc.JSValueRef,
    skip: bool = false,
    skip_message: ?[]const u8 = null,
    todo: bool = false,
    todo_message: ?[]const u8 = null,
    only: bool = false,
    /// skipIf(condition)：条件为 true 时跳过；由 Zig 执行时通过 JSC 求值
    skip_if_ref: ?jsc.JSValueRef = null,
};

/// 钩子任务载荷：suite + 钩子索引
const HookJob = struct { suite: *Suite, idx: usize };
/// 测试任务载荷：suite + 测试索引
const TestJob = struct { suite: *Suite, test_idx: usize };
/// 单步执行任务：钩子或测试；run() 时按序执行，支持 Promise 链
pub const Job = union(enum) {
    before_all: HookJob,
    after_all: HookJob,
    before_each: HookJob,
    after_each: HookJob,
    /// 执行单条测试（避免与 Zig 关键字 test 冲突）
    run_test: TestJob,
};

/// 从根 suite DFS 构建任务队列；has_only 为 true 时只加入标记 only 的测试
pub fn buildJobList(allocator: std.mem.Allocator, root: *Suite, has_only: bool) std.ArrayList(Job) {
    var list = std.ArrayList(Job).initCapacity(allocator, 0) catch unreachable;
    appendSuiteJobs(allocator, &list, root, has_only);
    return list;
}

fn appendSuiteJobs(allocator: std.mem.Allocator, list: *std.ArrayList(Job), s: *Suite, has_only: bool) void {
    for (0..s.before_all.items.len) |i| {
        list.append(allocator, .{ .before_all = .{ .suite = s, .idx = i } }) catch return;
    }
    for (0..s.tests.items.len) |i| {
        if (has_only and !s.tests.items[i].only) continue;
        for (0..s.before_each.items.len) |j| {
            list.append(allocator, .{ .before_each = .{ .suite = s, .idx = j } }) catch return;
        }
        list.append(allocator, .{ .run_test = .{ .suite = s, .test_idx = i } }) catch return;
        for (0..s.after_each.items.len) |j| {
            list.append(allocator, .{ .after_each = .{ .suite = s, .idx = j } }) catch return;
        }
    }
    for (s.children.items) |c| {
        appendSuiteJobs(allocator, list, c, has_only);
    }
    for (0..s.after_all.items.len) |i| {
        list.append(allocator, .{ .after_all = .{ .suite = s, .idx = i } }) catch return;
    }
}

/// 单个 suite：name、子 suite、测试列表、四个钩子列表
pub const Suite = struct {
    name: []const u8,
    parent: ?*Suite = null,
    children: std.ArrayList(*Suite),
    tests: std.ArrayList(TestEntry),
    before_all: std.ArrayList(jsc.JSValueRef),
    after_all: std.ArrayList(jsc.JSValueRef),
    before_each: std.ArrayList(jsc.JSValueRef),
    after_each: std.ArrayList(jsc.JSValueRef),
    only: bool = false,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Suite) void {
        for (self.children.items) |c| {
            c.deinit();
            self.allocator.destroy(c);
        }
        self.children.deinit(self.allocator);
        for (self.tests.items) |*t| {
            if (t.skip_message) |s| self.allocator.free(s);
            if (t.todo_message) |s| self.allocator.free(s);
        }
        self.tests.deinit(self.allocator);
        self.before_all.deinit(self.allocator);
        self.after_all.deinit(self.allocator);
        self.before_each.deinit(self.allocator);
        self.after_each.deinit(self.allocator);
    }
};

/// 根 runner 状态：当前 suite 栈、根 suite；由 mod.zig 在 describe/it/run 中访问
pub const RunnerState = struct {
    allocator: std.mem.Allocator,
    root: Suite,
    /// describe() 进入时 push，退出时 pop；it()/beforeAll() 等注册到 stack[top]
    suite_stack: std.ArrayList(*Suite),
    /// 是否有任意 test/suite 标记了 only；run 时若为 true 则只跑 only
    has_only: bool = false,

    pub fn create(allocator: std.mem.Allocator) !*RunnerState {
        const self = allocator.create(RunnerState) catch return error.OutOfMemory;
        self.root = .{
            .name = "",
            .children = std.ArrayList(*Suite).initCapacity(allocator, 0) catch return error.OutOfMemory,
            .tests = std.ArrayList(TestEntry).initCapacity(allocator, 0) catch return error.OutOfMemory,
            .before_all = std.ArrayList(jsc.JSValueRef).initCapacity(allocator, 0) catch return error.OutOfMemory,
            .after_all = std.ArrayList(jsc.JSValueRef).initCapacity(allocator, 0) catch return error.OutOfMemory,
            .before_each = std.ArrayList(jsc.JSValueRef).initCapacity(allocator, 0) catch return error.OutOfMemory,
            .after_each = std.ArrayList(jsc.JSValueRef).initCapacity(allocator, 0) catch return error.OutOfMemory,
            .allocator = allocator,
        };
        self.suite_stack = std.ArrayList(*Suite).initCapacity(allocator, 0) catch return error.OutOfMemory;
        self.allocator = allocator;
        self.has_only = false;
        return self;
    }

    pub fn destroy(self: *RunnerState) void {
        self.root.deinit();
        self.suite_stack.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// 当前正在注册的 suite（describe 回调内）；栈顶
    pub fn currentSuite(self: *RunnerState) ?*Suite {
        if (self.suite_stack.items.len == 0) return null;
        return self.suite_stack.items[self.suite_stack.items.len - 1];
    }

    /// 入栈；describe(name, fn) 内先 push(suite) 再调 fn
    pub fn pushSuite(self: *RunnerState, suite: *Suite) void {
        self.suite_stack.append(self.allocator, suite) catch {};
    }

    /// 出栈；describe 的 fn 返回后 pop
    pub fn popSuite(self: *RunnerState) void {
        if (self.suite_stack.items.len > 0) _ = self.suite_stack.pop();
    }
};
