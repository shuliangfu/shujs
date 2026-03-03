//! shu update 子命令（cli/update.zig）
//!
//! 职责
//!   - 无参数：对 package.json 中 dependencies 与 devDependencies 按当前版本范围重新向 registry 解析，更新 shu.lock 后执行 install。
//!   - 有包名参数：仅更新这些包及其依赖，再写回 lockfile 并 install。
//!   - 无 package.json 时提示并返回 ManifestNotFound。
//!
//! 主要 API
//!   - update(allocator, parsed, positional)：入口；依赖 manifest、lockfile、registry、pkg_install、io_core。
//!
//! 约定
//!   - 面向用户输出为英文；参考 PACKAGE_DESIGN.md §3.3、01-代码规则。

const std = @import("std");
const args = @import("args.zig");
const version = @import("version.zig");
const manifest = @import("../package/manifest.zig");
const lockfile = @import("../package/lockfile.zig");
const registry = @import("../package/registry.zig");
const npmrc = @import("../package/npmrc.zig");
const pkg_install = @import("../package/install.zig");
const io_core = @import("io_core");

/// 执行 shu update [包名...]：若无参数则对所有 dependencies 与 devDependencies 按当前版本范围重新向 registry 解析，更新 shu.lock 后 install；若有包名则仅更新这些包。
pub fn update(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = parsed;
    try version.printCommandHeader("update");
    var cwd_buf: [1024]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch return error.CwdFailed;
    const cwd_owned = allocator.dupe(u8, cwd) catch return error.OutOfMemory;
    defer allocator.free(cwd_owned);

    var loaded = manifest.Manifest.load(allocator, cwd_owned) catch |e| {
        if (e == error.ManifestNotFound) {
            try printToStdout("shu update: no manifest (package.json or deno.json) in current directory\n", .{});
            return e;
        }
        return e;
    };
    defer loaded.arena.deinit();
    const m = &loaded.manifest;

    const lock_path = try io_core.pathJoin(allocator, &.{ cwd_owned, lockfile.lock_file_name });
    defer allocator.free(lock_path);
    var locked = lockfile.load(allocator, lock_path) catch std.StringArrayHashMap([]const u8).init(allocator);
    defer {
        var it = locked.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        locked.deinit();
    }

    var resolved = std.StringArrayHashMap([]const u8).init(allocator);
    defer resolved.deinit();
    defer {
        var it = resolved.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
    }

    // 先复制现有 lock，再覆盖要更新的包
    var lock_it = locked.iterator();
    while (lock_it.next()) |e| {
        try resolved.put(try allocator.dupe(u8, e.key_ptr.*), try allocator.dupe(u8, e.value_ptr.*));
    }

    const resolveOne = struct {
        fn f(
            alloc: std.mem.Allocator,
            project_dir: []const u8,
            name: []const u8,
            version_spec: []const u8,
            resolved_map: *std.StringArrayHashMap([]const u8),
        ) void {
            const registry_url = npmrc.getRegistryForPackage(alloc, project_dir, name) catch return;
            defer alloc.free(registry_url);
            const res = registry.resolveVersionAndTarball(alloc, registry_url, name, version_spec, null) catch return;
            defer alloc.free(res.version);
            defer alloc.free(res.tarball_url);
            if (resolved_map.getPtr(name)) |val_ptr| {
                alloc.free(val_ptr.*);
                val_ptr.* = alloc.dupe(u8, res.version) catch return;
            } else {
                resolved_map.put(alloc.dupe(u8, name) catch return, alloc.dupe(u8, res.version) catch return) catch return;
            }
        }
    }.f;

    if (positional.len == 0) {
        var it = m.dependencies.iterator();
        while (it.next()) |e| {
            resolveOne(allocator, cwd_owned, e.key_ptr.*, e.value_ptr.*, &resolved);
        }
        var dev_it = m.dev_dependencies.iterator();
        while (dev_it.next()) |e| {
            resolveOne(allocator, cwd_owned, e.key_ptr.*, e.value_ptr.*, &resolved);
        }
    } else {
        for (positional) |name| {
            if (m.dependencies.get(name)) |spec| {
                resolveOne(allocator, cwd_owned, name, spec, &resolved);
            } else if (m.dev_dependencies.get(name)) |spec| {
                resolveOne(allocator, cwd_owned, name, spec, &resolved);
            } else {
                try printToStdout("shu update: {s} not in dependencies or devDependencies\n", .{name});
            }
        }
    }

    try lockfile.saveFromResolved(allocator, lock_path, resolved, null, null);
    try pkg_install.install(allocator, cwd_owned, null, null, null);
    try printToStdout("\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
