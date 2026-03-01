//! Shu.fs 单元测试：在临时目录下运行 shu --allow-read --allow-write -e "script" 覆盖 readSync/writeSync、readdirSync、mkdirSync、existsSync、statSync、unlinkSync、rmdirSync、renameSync、copySync、appendSync、realpathSync、lstat、truncate、access、isEmptyDir、size、isFile、isDirectory、readdirWithStats、ensureFile、mkdirRecursiveSync、rmdirRecursiveSync 等。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const runShuWithScriptInDir = @import("shu_run.zig").runShuWithScriptInDir;

fn runInDir(allocator: std.mem.Allocator, dir: []const u8, script: []const u8) ![]const u8 {
    return runShuWithScriptInDir(allocator, script, &.{ "--allow-read", "--allow-write" }, dir);
}

test "Shu.fs.writeSync and readSync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out = try runInDir(allocator, dir_path,
        \\Shu.fs.writeSync('f.txt', 'hello');
        \\console.log(Shu.fs.readSync('f.txt'));
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "Shu.fs.appendSync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out = try runInDir(allocator, dir_path,
        \\Shu.fs.writeSync('a.txt', 'a');
        \\Shu.fs.appendSync('a.txt', 'b');
        \\console.log(Shu.fs.readSync('a.txt'));
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ab", out);
}

test "Shu.fs.existsSync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out = try runInDir(allocator, dir_path,
        \\Shu.fs.writeSync('x.txt', '');
        \\console.log(Shu.fs.existsSync('x.txt'), Shu.fs.existsSync('nonexistent'));
    );
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "false") != null);
}

test "Shu.fs.mkdirSync and readdirSync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out = try runInDir(allocator, dir_path,
        \\Shu.fs.mkdirSync('d');
        \\Shu.fs.writeSync('d/f.txt', '');
        \\const names = Shu.fs.readdirSync('d');
        \\console.log(names.length, names[0]);
    );
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "f.txt") != null);
}

test "Shu.fs.statSync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out = try runInDir(allocator, dir_path,
        \\Shu.fs.writeSync('s.txt', 'abc');
        \\const st = Shu.fs.statSync('s.txt');
        \\console.log(st.isFile, st.isDirectory, st.size);
    );
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "3") != null);
}

test "Shu.fs.unlinkSync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out = try runInDir(allocator, dir_path,
        \\Shu.fs.writeSync('u.txt', '');
        \\Shu.fs.unlinkSync('u.txt');
        \\console.log(Shu.fs.existsSync('u.txt'));
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("false", out);
}

test "Shu.fs.renameSync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out = try runInDir(allocator, dir_path,
        \\Shu.fs.writeSync('old.txt', 'data');
        \\Shu.fs.renameSync('old.txt', 'new.txt');
        \\console.log(Shu.fs.existsSync('old.txt'), Shu.fs.readSync('new.txt'));
    );
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "data") != null);
}

test "Shu.fs.copySync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out = try runInDir(allocator, dir_path,
        \\Shu.fs.writeSync('src.txt', 'copied');
        \\Shu.fs.copySync('src.txt', 'dst.txt');
        \\console.log(Shu.fs.readSync('dst.txt'));
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("copied", out);
}

test "Shu.fs.mkdirRecursiveSync and rmdirRecursiveSync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out = try runInDir(allocator, dir_path,
        \\Shu.fs.mkdirRecursiveSync('a/b/c');
        \\Shu.fs.writeSync('a/b/c/f.txt', '');
        \\Shu.fs.rmdirRecursiveSync('a');
        \\console.log(Shu.fs.existsSync('a'));
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("false", out);
}

test "Shu.fs.realpathSync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out = try runInDir(allocator, dir_path,
        \\Shu.fs.writeSync('r.txt', '');
        \\const r = Shu.fs.realpathSync('r.txt');
        \\console.log(r.length > 0, r.indexOf('r.txt') >= 0);
    );
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "true") != null);
}

test "Shu.fs.sizeSync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out = try runInDir(allocator, dir_path,
        \\Shu.fs.writeSync('size.txt', '12345');
        \\console.log(Shu.fs.sizeSync('size.txt'));
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("5", out);
}

test "Shu.fs.isFileSync and isDirectorySync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out = try runInDir(allocator, dir_path,
        \\Shu.fs.writeSync('file.txt', '');
        \\Shu.fs.mkdirSync('mydir');
        \\console.log(Shu.fs.isFileSync('file.txt'), Shu.fs.isDirectorySync('file.txt'), Shu.fs.isDirectorySync('mydir'));
    );
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "false") != null);
}

test "Shu.fs.isEmptyDirSync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out = try runInDir(allocator, dir_path,
        \\Shu.fs.mkdirSync('empty');
        \\Shu.fs.mkdirSync('full');
        \\Shu.fs.writeSync('full/x', '');
        \\console.log(Shu.fs.isEmptyDirSync('empty'), Shu.fs.isEmptyDirSync('full'));
    );
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "false") != null);
}

test "Shu.fs.ensureFileSync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out = try runInDir(allocator, dir_path,
        \\Shu.fs.ensureFileSync('ef.txt');
        \\Shu.fs.ensureFileSync('ef.txt');
        \\console.log(Shu.fs.existsSync('ef.txt'), Shu.fs.readSync('ef.txt').length);
    );
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0") != null);
}

test "Shu.fs.truncateSync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out = try runInDir(allocator, dir_path,
        \\Shu.fs.writeSync('tr.txt', 'abcdef');
        \\Shu.fs.truncateSync('tr.txt', 3);
        \\console.log(Shu.fs.readSync('tr.txt'));
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("abc", out);
}

test "Shu.fs.readdirWithStatsSync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out = try runInDir(allocator, dir_path,
        \\Shu.fs.writeSync('ws.txt', 'x');
        \\const entries = Shu.fs.readdirWithStatsSync('.');
        \\console.log(entries.length >= 1 ? entries[0].name : '');
    );
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "ws.txt") != null);
}

test "Shu.fs.rmdirSync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out = try runInDir(allocator, dir_path,
        \\Shu.fs.mkdirSync('rmd');
        \\Shu.fs.rmdirSync('rmd');
        \\console.log(Shu.fs.existsSync('rmd'));
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("false", out);
}

test "Shu.fs.readFileSync and writeFileSync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out = try runInDir(allocator, dir_path,
        \\Shu.fs.writeFileSync('wf.txt', 'node-style');
        \\console.log(Shu.fs.readFileSync('wf.txt'));
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("node-style", out);
}
