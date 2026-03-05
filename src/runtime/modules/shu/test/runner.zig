// shu:test 内部：suite/test 树与执行状态，run() 时构建 JS 对象树供 JS 侧 runner 脚本执行
// 与 node:test 语义对齐：describe/it、beforeAll/afterAll/beforeEach/afterEach、skip/skipIf/todo/only
// 所有权：buildJobList [Allocates] 返回的 ArrayListUnmanaged(Job) 由调用方 deinit(allocator)；Suite/TestEntry 内 name、skip_message 等由 suite 生命周期持有并在 suite 释放时 free。

const std = @import("std");
const jsc = @import("jsc");

/// 单条测试用例：name、回调、选项（skip/todo/only/skipIf/timeout）
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
    /// 超时毫秒数，与 node:test 的 it(..., { timeout }) 对齐；当前仅解析存储，实际计时可后续接入
    timeout_ms: ?u32 = null,
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

/// 后序遍历填充 s 及其子树的 only_in_subtree；run() 构建 job 列表前由 mod 调用一次 root。
pub fn computeOnlyInSubtree(s: *Suite) void {
    for (s.children.items) |c| {
        computeOnlyInSubtree(c);
    }
    var any_only = s.only;
    for (s.tests.items) |*t| {
        if (t.only) {
            any_only = true;
            break;
        }
    }
    if (!any_only) {
        for (s.children.items) |c| {
            if (c.only_in_subtree) {
                any_only = true;
                break;
            }
        }
    }
    s.only_in_subtree = any_only;
}

/// 后序遍历填充 s 及其子树的 todo_in_subtree；--todo 时 buildJobList 只加入标记 todo 的用例，本字段用于剪枝。
pub fn computeTodoInSubtree(s: *Suite) void {
    for (s.children.items) |c| {
        computeTodoInSubtree(c);
    }
    var any_todo = false;
    for (s.tests.items) |*t| {
        if (t.todo) {
            any_todo = true;
            break;
        }
    }
    if (!any_todo) {
        for (s.children.items) |c| {
            if (c.todo_in_subtree) {
                any_todo = true;
                break;
            }
        }
    }
    s.todo_in_subtree = any_todo;
}

/// [Allocates] 从根 suite DFS 构建任务队列；has_only 为 true 时只加入标记 only 的 suite/测试；todo_only 为 true 时只加入标记 todo 的用例（需先调用 computeTodoInSubtree）。返回的 ArrayListUnmanaged(Job) 由调用方 deinit(allocator)。
pub fn buildJobList(allocator: std.mem.Allocator, root: *Suite, has_only: bool, todo_only: bool) std.ArrayListUnmanaged(Job) {
    var list: std.ArrayListUnmanaged(Job) = .{};
    appendSuiteJobs(allocator, &list, root, has_only, todo_only);
    return list;
}

/// [Allocates] 返回 suite 链（根到叶）加测试名拼成的完整名称，如 "Suite A > Suite B > test name"。调用方负责 free。
pub fn getFullTestName(allocator: std.mem.Allocator, suite: *Suite, test_idx: usize) ![]const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .{};
    defer parts.deinit(allocator);
    var s: ?*Suite = suite;
    while (s) |n| : (s = n.parent) {
        if (n.name.len > 0) try parts.append(allocator, n.name);
    }
    std.mem.reverse([]const u8, parts.items);
    const t_name = suite.tests.items[test_idx].name;
    if (parts.items.len == 0) return allocator.dupe(u8, t_name);
    var out = std.ArrayList(u8).initCapacity(allocator, 64) catch return error.OutOfMemory;
    defer out.deinit(allocator);
    for (parts.items, 0..) |p, i| {
        if (i > 0) try out.appendSlice(allocator, " > ");
        try out.appendSlice(allocator, p);
    }
    try out.appendSlice(allocator, " > ");
    try out.appendSlice(allocator, t_name);
    return out.toOwnedSlice(allocator);
}

fn appendSuiteJobs(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(Job), s: *Suite, has_only: bool, todo_only: bool) void {
    if (s.skip) {
        for (s.children.items) |c| {
            appendSuiteJobs(allocator, list, c, has_only, todo_only);
        }
        return;
    }
    if (has_only and !s.only and !s.only_in_subtree) {
        for (s.children.items) |c| {
            appendSuiteJobs(allocator, list, c, has_only, todo_only);
        }
        return;
    }
    if (todo_only and !s.todo_in_subtree) {
        for (s.children.items) |c| {
            appendSuiteJobs(allocator, list, c, has_only, todo_only);
        }
        return;
    }
    for (0..s.before_all.items.len) |i| {
        list.append(allocator, .{ .before_all = .{ .suite = s, .idx = i } }) catch return;
    }
    for (0..s.tests.items.len) |i| {
        if (has_only and !s.tests.items[i].only) continue;
        if (todo_only and !s.tests.items[i].todo) continue;
        for (0..s.before_each.items.len) |j| {
            list.append(allocator, .{ .before_each = .{ .suite = s, .idx = j } }) catch return;
        }
        list.append(allocator, .{ .run_test = .{ .suite = s, .test_idx = i } }) catch return;
        for (0..s.after_each.items.len) |j| {
            list.append(allocator, .{ .after_each = .{ .suite = s, .idx = j } }) catch return;
        }
    }
    for (s.children.items) |c| {
        appendSuiteJobs(allocator, list, c, has_only, todo_only);
    }
    for (0..s.after_all.items.len) |i| {
        list.append(allocator, .{ .after_all = .{ .suite = s, .idx = i } }) catch return;
    }
}

/// 单个 suite：name、子 suite、测试列表、四个钩子列表（Unmanaged 容器，显式传 allocator）
pub const Suite = struct {
    name: []const u8,
    parent: ?*Suite = null,
    children: std.ArrayListUnmanaged(*Suite),
    tests: std.ArrayListUnmanaged(TestEntry),
    before_all: std.ArrayListUnmanaged(jsc.JSValueRef),
    after_all: std.ArrayListUnmanaged(jsc.JSValueRef),
    before_each: std.ArrayListUnmanaged(jsc.JSValueRef),
    after_each: std.ArrayListUnmanaged(jsc.JSValueRef),
    /// describe.only 时置 true；与 only_in_subtree 一起用于 buildJobList 的 only 过滤
    only: bool = false,
    /// describe.skip / describe.ignore 时置 true；该 suite 的钩子与测试不加入 job 列表
    skip: bool = false,
    /// 本 suite 或子树内是否有 only；由 computeOnlyInSubtree 填充，buildJobList 前必须已算好
    only_in_subtree: bool = false,
    /// 本 suite 或子树内是否有 todo；由 computeTodoInSubtree 填充，--todo 时 buildJobList 前必须已算好
    todo_in_subtree: bool = false,
    /// describe(name, fn, { timeout }) 的 timeout，子 suite 与 it 继承（子级覆盖）
    timeout_ms: ?u32 = null,
    /// describe(name, fn, { skipIf }) 的 skipIf，子 suite 与 it 继承（子级覆盖）
    skip_if_ref: ?jsc.JSValueRef = null,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Suite) void {
        for (self.children.items) |c| {
            c.deinit();
            self.allocator.destroy(c);
        }
        self.children.deinit(self.allocator);
        for (self.tests.items) |*t| {
            self.allocator.free(t.name);
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
    /// describe() 进入时 push，退出时 pop；it()/beforeAll() 等注册到 stack[top]（Unmanaged，显式传 allocator）
    suite_stack: std.ArrayListUnmanaged(*Suite),
    /// 是否有任意 test/suite 标记了 only；run 时若为 true 则只跑 only
    has_only: bool = false,

    pub fn create(allocator: std.mem.Allocator) !*RunnerState {
        const self = allocator.create(RunnerState) catch return error.OutOfMemory;
        self.root = .{
            .name = "",
            .children = .{},
            .tests = .{},
            .before_all = .{},
            .after_all = .{},
            .before_each = .{},
            .after_each = .{},
            .allocator = allocator,
        };
        self.suite_stack = .{};
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
