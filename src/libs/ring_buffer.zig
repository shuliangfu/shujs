// 无锁单生产者单消费者环形队列（RingBuffer），平台无关。
//
// 职责
//   - 在 Thread-per-Core 架构下，用于线程间传递任务或描述符（如 fd、user_data 等）；
//   - 单生产者单消费者（SPSC）、固定容量、无锁，T 需为指针或 usize 等单字类型以保证原子读写。
//
// 约束与约定
//   - 容量在 init 时取不小于 capacity 的最小 2 的幂，便于用 mask 取模；
//   - 多生产者场景需改用 MPSC 或 per-core 队列，本实现不保证正确性。
//
// 性能与规范
//   - §5.3 假共享防护：head 与 tail 之间插入缓存行填充，使两原子变量不在同一 64 字节缓存行，避免 False Sharing；
//   - §5.2 热路径：push、pop、count 为 inline fn，减少调用开销。
//
// 内存
//   - init(allocator, capacity) 使用传入的 allocator 分配 buffer；deinit(allocator) 由调用方调用，负责 free。

const std = @import("std");

/// 缓存行大小，用于 head/tail 填充隔离（§5.3）
const CACHE_LINE = 64;

/// 单生产者单消费者、固定容量、无锁环形缓冲区
/// T 需为指针或 usize 等单字类型，保证原子读写
/// head 与 tail 之间填充至不同 cache line，避免跨线程写同一行
pub fn RingBuffer(comptime T: type) type {
    return struct {
        buffer: []T,
        mask: usize,
        head: std.atomic.Value(usize),
        /// 填充使 tail 与 head 不在同一缓存行（§5.3 跨线程原子隔离）
        _pad_head_tail: [CACHE_LINE - @sizeOf(std.atomic.Value(usize))]u8 = undefined,
        tail: std.atomic.Value(usize),

        const Self = @This();

        /// 容量必须为 2 的幂，便于用 mask 取模
        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const cap = std.math.ceilPowerOfTwo(usize, capacity) catch return error.CapacityTooLarge;
            const buffer = try allocator.alloc(T, cap);
            @memset(buffer, @as(T, if (T == usize) 0 else undefined));
            return .{
                .buffer = buffer,
                .mask = cap - 1,
                .head = std.atomic.Value(usize).init(0),
                .tail = std.atomic.Value(usize).init(0),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buffer);
            self.* = undefined;
        }

        /// 生产者：入队一元素，队满返回 false（§5.2 热路径 inline）
        pub inline fn push(self: *Self, value: T) bool {
            const tail = self.tail.load(.monotonic);
            if (tail - self.head.load(.acquire) >= self.buffer.len) return false;
            self.buffer[tail & self.mask] = value;
            self.tail.store(tail + 1, .release);
            return true;
        }

        /// 消费者：出队一元素，队空返回 null（§5.2 热路径 inline）
        pub inline fn pop(self: *Self) ?T {
            const head = self.head.load(.monotonic);
            if (head >= self.tail.load(.acquire)) return null;
            const value = self.buffer[head & self.mask];
            self.head.store(head + 1, .release);
            return value;
        }

        /// 当前队列内元素数量（近似，多线程下可能瞬时不准）（§5.2 热路径 inline）
        pub inline fn count(self: *const Self) usize {
            const t = self.tail.load(.acquire);
            const h = self.head.load(.acquire);
            if (t >= h) return t - h;
            return 0;
        }
    };
}
