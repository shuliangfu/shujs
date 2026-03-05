//! Shu.report 集成测试：通过 shu -e 执行脚本，覆盖 getReport、writeReport。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.report.getReport: returns string" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const report = require('shu:report');
        \\const s = report.getReport();
        \\console.log(typeof s === 'string' && s.length > 0 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.report.getReport: contains diagnostic header" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const report = require('shu:report');
        \\const s = report.getReport();
        \\console.log(s.indexOf('diagnostic') >= 0 || s.indexOf('Shu') >= 0 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.report.writeReport: no args does not throw" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const report = require('shu:report');
        \\report.writeReport();
        \\console.log('ok');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.report.writeReport: with filename" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const report = require('shu:report');
        \\const fs = require('shu:fs');
        \\const tmp = require('shu:os').tmpdir() + '/shu-report-test-' + Date.now();
        \\report.writeReport(tmp);
        \\const ok = fs.existsSync(tmp);
        \\try { fs.unlinkSync(tmp); } catch(e) {}
        \\console.log(ok ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}
