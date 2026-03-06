//! 高性能无锁环形缓冲区（ring_buffer.zig）
//!
//! 职责：
//!   - 提供单生产者单消费者（SPSC）无锁队列实现，用于高性能线程间通信。
//!   - 实现硬件级的伪共享（False Sharing）防御。
//!
//! 极致压榨亮点：
//!   1. **缓存行对齐隔离**：`head` 与 `tail` 严格按 `std.atomic.cache_line` 对齐并隔离，消除核间缓存一致性风暴。
//!   2. **本地索引缓存**：在 `push`/`pop` 过程中优先使用 `cached_head`/`cached_tail`，显著减少昂贵的原子指令执行频率。
//!   3. **批量操作优化**：提供 `pushBatch` 与 `popBatch` 接口，仅需一次原子操作即可传输整块数据，压榨内存带宽。
//!   4. **对齐内存分配**：底层数据区采用缓存行对齐分配，确保 SIMD 盲读与 DMA 操作的硬件友好性。
//!   5. **内存顺序细化**：精细控制 `.monotonic` 与 `.release` 屏障，在保证正确性的前提下提供最高吞吐量。
//!
//! 适用规范：
//!   - 遵循 00 §3.5（无锁环形缓冲区）、§5.3（伪共享防御）。
//!
//! [Allocates] 缓冲区由 `init` 分配，调用方负责 `deinit`。

const std = @import("std");

/// 缓存行大小，用于 head/tail 填充隔离（§5.3）
const CACHE_LINE = std.atomic.cache_line;

/// 单生产者单消费者、固定容量、无锁环形缓冲区
/// T 需为指针或 usize 等单字类型，保证原子读写
/// head 与 tail 显式 align(CACHE_LINE)，各占独立缓存行，避免 False Sharing（00 §5.3）
pub fn RingBuffer(comptime T: type) type {
    return struct {
        /// 只读字段，缓存在各核 (§1.4)
        buffer: []T align(CACHE_LINE),
        mask: usize,

        /// 生产者独占缓存行 (§5.3)
        _pad_prod: [CACHE_LINE]u8 align(CACHE_LINE) = undefined,
        /// 生产者写索引
        tail: std.atomic.Value(usize),
        /// 消费者 head 的本地副本，减少跨核 .acquire 频率
        cached_head: usize = 0,

        /// 消费者独占缓存行 (§5.3)
        _pad_cons: [CACHE_LINE]u8 align(CACHE_LINE) = undefined,
        /// 消费者读索引
        head: std.atomic.Value(usize),
        /// 生产者 tail 的本地副本，减少跨核 .acquire 频率
        cached_tail: usize = 0,

        const Self = @This();

        /// 容量必须为 2 的幂，便于用 mask 取模
        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const cap = std.math.ceilPowerOfTwo(usize, capacity) catch return error.CapacityTooLarge;
            // 极致优化：Buffer 物理对齐缓存行，避免首尾元素与结构体字段 False Sharing
            const buffer = try allocator.alignedAlloc(T, std.mem.Alignment.fromByteUnits(CACHE_LINE), cap);
            @memset(buffer, @as(T, if (T == usize) 0 else undefined));
            return .{
                .buffer = buffer,
                .mask = cap - 1,
                .tail = std.atomic.Value(usize).init(0),
                .head = std.atomic.Value(usize).init(0),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buffer);
            self.* = undefined;
        }

        // Hot-path
        /// 生产者：入队一元素，队满返回 false（§5.2 热路径 inline）
        pub inline fn push(self: *Self, value: T) bool {
            @setRuntimeSafety(false);
            const t = self.tail.load(.monotonic);
            // 极致压榨：先看本地缓存的 head，减少跨核缓存一致性流量 (§3.6)
            if (t - self.cached_head >= self.buffer.len) {
                self.cached_head = self.head.load(.acquire);
                if (t - self.cached_head >= self.buffer.len) return false;
            }
            self.buffer[t & self.mask] = value;
            self.tail.store(t + 1, .release);
            return true;
        }

        // Hot-path
        /// 消费者：出队一元素，队空返回 null（§5.2 热路径 inline）
        pub inline fn pop(self: *Self) ?T {
            @setRuntimeSafety(false);
            const h = self.head.load(.monotonic);
            // 极致压榨：先看本地缓存的 tail
            if (h >= self.cached_tail) {
                self.cached_tail = self.tail.load(.acquire);
                if (h >= self.cached_tail) return null;
            }
            const value = self.buffer[h & self.mask];
            self.head.store(h + 1, .release);
            return value;
        }

        /// 生产者：批量入队（零拷贝思想 §3.4）
        pub inline fn pushBatch(self: *Self, items: []const T) usize {
            @setRuntimeSafety(false);
            const t = self.tail.load(.monotonic);
            var available = self.buffer.len - (t - self.cached_head);
            if (available < items.len) {
                self.cached_head = self.head.load(.acquire);
                available = self.buffer.len - (t - self.cached_head);
            }
            const n = @min(available, items.len);
            if (n == 0) return 0;

            for (0..n) |i| {
                self.buffer[(t + i) & self.mask] = items[i];
            }
            self.tail.store(t + n, .release);
            return n;
        }

        /// 消费者：批量出队
        pub inline fn popBatch(self: *Self, out: []T) usize {
            @setRuntimeSafety(false);
            const h = self.head.load(.monotonic);
            var available = self.cached_tail - h;
            if (available < out.len) {
                self.cached_tail = self.tail.load(.acquire);
                available = self.cached_tail - h;
            }
            const n = @min(available, out.len);
            if (n == 0) return 0;

            for (0..n) |i| {
                out[i] = self.buffer[(h + i) & self.mask];
            }
            self.head.store(h + n, .release);
            return n;
        }

        // Hot-path
        /// 当前队列内元素数量（近似，多线程下可能瞬时不准）（§5.2 热路径 inline）
        pub inline fn count(self: *const Self) usize {
            const t = self.tail.load(.acquire);
            const h = self.head.load(.acquire);
            return t -% h;
        }
    };
}
