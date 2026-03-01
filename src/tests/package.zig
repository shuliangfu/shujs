//! 包管理单元测试：lockfile 与 npmrc 的加载/释放契约，防止 GPA 泄漏回归。
//! 运行：zig build test

const std = @import("std");
const lockfile = @import("../package/lockfile.zig");
const npmrc = @import("../package/npmrc.zig");

// 验证 lockfile.load 返回的 map：调用方须先 free 各 key/value 再 deinit，否则泄漏。
test "lockfile.load: free entries then deinit (no leak)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const lock_path = try std.fmt.allocPrint(allocator, "{s}/shu.lock", .{dir_path});
    defer allocator.free(lock_path);
    try tmp.dir.writeFile("shu.lock",
        \\{"packages":{"preact":"10.0.0","lodash":"4.17.21"}}
    );
    var locked = lockfile.load(allocator, lock_path) catch return;
    defer {
        var it = locked.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        locked.deinit();
    }
    try std.testing.expect(locked.get("preact") != null);
    try std.testing.expectEqualStrings(locked.get("preact").?, "10.0.0");
    try std.testing.expect(locked.get("lodash") != null);
    try std.testing.expectEqualStrings(locked.get("lodash").?, "4.17.21");
}

// 验证 lockfile.load 文件不存在时返回空 map，无需 free 条目。
test "lockfile.load: file not found returns empty map" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const lock_path = try std.fmt.allocPrint(allocator, "{s}/nonexistent.shu.lock", .{dir_path});
    defer allocator.free(lock_path);
    var locked = lockfile.load(allocator, lock_path) catch return;
    defer locked.deinit();
    try std.testing.expect(locked.count() == 0);
}

// 验证 npmrc.getRegistryForPackage：无 .npmrc 时返回默认 URL；内部会正确释放 load() 的 map 条目（防泄漏）。
test "npmrc.getRegistryForPackage: no .npmrc returns default URL" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const url = npmrc.getRegistryForPackage(allocator, dir_path, "preact") catch return;
    defer allocator.free(url);
    try std.testing.expect(std.mem.eql(u8, url, npmrc.DEFAULT_REGISTRY_URL));
}

// 验证有 .npmrc 时 getRegistryForPackage 返回配置的 registry，且 map 条目被正确释放。
test "npmrc.getRegistryForPackage: with .npmrc returns configured registry" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    try tmp.dir.writeFile(".npmrc", "registry=https://custom.registry.example/\n");
    const url = npmrc.getRegistryForPackage(allocator, dir_path, "preact") catch return;
    defer allocator.free(url);
    try std.testing.expect(std.mem.eql(u8, url, "https://custom.registry.example/"));
}
