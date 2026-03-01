// shu help 子命令：集中输出全局用法与各子命令简要说明
// 支持 shu help、shu help <subcommand>；--help 仍由 main 与各子命令处理
// 输出格式对齐 deno -h：分组 Commands（Execution / Dependency / Tooling 等）
// 在 TTY 下使用 ANSI 颜色美化；管道/重定向时自动禁用颜色

const std = @import("std");
const version = @import("version.zig");

// ANSI 转义：仅当 stdout 为 TTY 时启用，避免管道/重定向时输出乱码
const SGR = struct {
    reset: []const u8 = "",
    bold: []const u8 = "",
    dim: []const u8 = "",
    cyan: []const u8 = "",
    green: []const u8 = "",
    yellow: []const u8 = "",
    fn withColor(use: bool) SGR {
        if (!use) return .{};
        return .{
            .reset = "\x1b[0m",
            .bold = "\x1b[1m",
            .dim = "\x1b[2m",
            .cyan = "\x1b[36m",
            .green = "\x1b[32m",
            .yellow = "\x1b[33m",
        };
    }
};

const CmdHelp = struct { name: []const u8, desc: []const u8 };

// --- 按 deno 风格分组 ---
const Execution = [_]CmdHelp{
    .{ .name = "run", .desc = "Run a .js/.ts/.tsx file or package.json script" },
    .{ .name = "eval", .desc = "Evaluate code string (like node -e)" },
    .{ .name = "repl", .desc = "Start interactive REPL" },
    .{ .name = "task", .desc = "Run or list package.json scripts (alias: tasks)" },
    .{ .name = "x", .desc = "Run a package binary without installing (like npx)" },
};
const Dependency = [_]CmdHelp{
    .{ .name = "install, -i", .desc = "Install dependencies to node_modules (package.json / lockfile)" },
    .{ .name = "add", .desc = "Add dependency and run install (npm or jsr:)" },
    .{ .name = "remove", .desc = "Remove dependency from package.json" },
    .{ .name = "update", .desc = "Update dependencies within version range" },
    .{ .name = "outdated", .desc = "List outdated dependencies" },
    .{ .name = "list", .desc = "List installed packages (alias: ls)" },
    .{ .name = "link", .desc = "Link a local package into node_modules" },
    .{ .name = "unlink", .desc = "Unlink a linked package" },
    .{ .name = "cache", .desc = "Pre-fetch and cache dependencies" },
    .{ .name = "why", .desc = "Explain why a package is installed" },
};
const Tooling = [_]CmdHelp{
    .{ .name = "build", .desc = "Compile or bundle entry to JS" },
    .{ .name = "test", .desc = "Discover and run tests" },
    .{ .name = "check", .desc = "Type-check TS/JS" },
    .{ .name = "lint", .desc = "Lint code" },
    .{ .name = "fmt", .desc = "Format code" },
    .{ .name = "compiler", .desc = "Bundle entry into a standalone executable" },
    .{ .name = "preview", .desc = "Preview static site (dev server)" },
    .{ .name = "serve", .desc = "Serve static files (production-style)" },
    .{ .name = "doc", .desc = "Generate API docs from JSDoc/TS" },
};
const Project = [_]CmdHelp{
    .{ .name = "init", .desc = "Initialize a new project (package.json, etc.)" },
    .{ .name = "create", .desc = "Create project from template" },
    .{ .name = "pack", .desc = "Create a tarball from package.json" },
    .{ .name = "publish", .desc = "Publish to npm or registry" },
    .{ .name = "clean", .desc = "Remove cache and build artifacts" },
};
const Registry = [_]CmdHelp{
    .{ .name = "login", .desc = "Log in to registry" },
    .{ .name = "logout", .desc = "Log out from registry" },
    .{ .name = "whoami", .desc = "Show current registry user" },
    .{ .name = "search", .desc = "Search registry for packages" },
    .{ .name = "audit", .desc = "Audit dependencies for vulnerabilities" },
};
const Info = [_]CmdHelp{
    .{ .name = "version, -v", .desc = "Print shu version" },
    .{ .name = "help, -h", .desc = "Print this help; use 'shu help <cmd>' for details" },
    .{ .name = "info", .desc = "Show dependency tree or module resolution info" },
    .{ .name = "doctor", .desc = "Diagnose environment" },
    .{ .name = "upgrade", .desc = "Upgrade shu binary" },
    .{ .name = "completions", .desc = "Generate shell completion script" },
    .{ .name = "env", .desc = "Print environment (e.g. for run)" },
    .{ .name = "config", .desc = "Read or write global/project config" },
    .{ .name = "inspect", .desc = "Run with DevTools/Inspector" },
    .{ .name = "trace", .desc = "Trace module load / require chain" },
};

const Category = struct { title: []const u8, commands: []const CmdHelp };
const CATEGORIES = [_]Category{
    .{ .title = "Execution", .commands = &Execution },
    .{ .title = "Dependency management", .commands = &Dependency },
    .{ .title = "Tooling", .commands = &Tooling },
    .{ .title = "Project", .commands = &Project },
    .{ .title = "Registry", .commands = &Registry },
    .{ .title = "Info & config", .commands = &Info },
};

/// 打印全局用法（deno 风格：分组 Commands）；在 TTY 下输出 ANSI 颜色
pub fn printGlobalUsage() !void {
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;
    const use_color = std.posix.isatty(1); // stdout
    const sgr = SGR.withColor(use_color);

    // 标题：粗体 + 青色
    try out.print("{s}{s}shu{s}: A JavaScript / TypeScript runtime (Node / Deno / Bun compatible){s}\n\n", .{ sgr.bold, sgr.cyan, sgr.reset, sgr.reset });
    // Usage / Options / Commands 小节标题：青色
    try out.print("{s}Usage{s}: {s}shu [OPTIONS] [COMMAND]{s}\n\n", .{ sgr.cyan, sgr.reset, sgr.dim, sgr.reset });
    try out.print("{s}Options{s}:\n", .{ sgr.cyan, sgr.reset });
    try out.print("  {s}--version, -v{s}     Print version\n", .{ sgr.yellow, sgr.reset });
    try out.print("  {s}--allow-net{s}       Allow network access\n", .{ sgr.yellow, sgr.reset });
    try out.print("  {s}--allow-read{s}      Allow file system read\n", .{ sgr.yellow, sgr.reset });
    try out.print("  {s}--allow-env{s}       Allow environment access\n", .{ sgr.yellow, sgr.reset });
    try out.print("  {s}--allow-write{s}     Allow file system write\n", .{ sgr.yellow, sgr.reset });
    try out.print("  {s}--help, -h{s}        Show this help\n\n", .{ sgr.yellow, sgr.reset });
    try out.print("{s}Commands{s}:\n\n", .{ sgr.cyan, sgr.reset });

    var name_buf: [32]u8 = undefined;
    for (CATEGORIES) |cat| {
        try out.print("  {s}{s}{s}:\n", .{ sgr.cyan, cat.title, sgr.reset });
        for (cat.commands) |c| {
            const padded = std.fmt.bufPrint(&name_buf, "{s:<20}", .{c.name}) catch c.name;
            try out.print("    {s}{s}{s}  {s}\n", .{ sgr.green, padded, sgr.reset, c.desc });
        }
        try out.writeAll("\n");
    }
    try out.print("{s}Tip{s}: Run 'shu help <command>' for command-specific help.\n", .{ sgr.dim, sgr.reset });
    try out.print("{s}Version{s}: {s}\n", .{ sgr.dim, sgr.reset, version.VERSION });
    try out.flush();
}

/// 返回子命令简短说明（用于 shu help <cmd>）；匹配主名或 "name, -x" 形式（逗号前/后均匹配）
fn getSubcommandDescription(cmd: []const u8) ?[]const u8 {
    for (CATEGORIES) |cat| {
        for (cat.commands) |c| {
            if (std.mem.eql(u8, c.name, cmd)) return c.desc;
            if (std.mem.indexOf(u8, c.name, ",")) |comma_pos| {
                if (std.mem.eql(u8, std.mem.trim(u8, c.name[0..comma_pos], " "), cmd)) return c.desc;
                const after = std.mem.trim(u8, c.name[comma_pos + 1 ..], " ");
                if (std.mem.eql(u8, after, cmd)) return c.desc;
            }
        }
    }
    if (std.mem.eql(u8, cmd, "ls")) return "Alias for list. List installed packages.";
    if (std.mem.eql(u8, cmd, "tasks")) return "Alias for task. Run or list package.json scripts.";
    return null;
}

/// 执行 shu help [subcommand]：无参数时打印全局用法，有参数时打印该子命令简要说明
pub fn help(allocator: std.mem.Allocator, positional: []const []const u8) !void {
    _ = allocator;
    if (positional.len == 0) {
        try printGlobalUsage();
        return;
    }
    const cmd = positional[0];
    if (getSubcommandDescription(cmd)) |desc| {
        var buf: [256]u8 = undefined;
        var w = std.fs.File.stdout().writer(&buf);
        try w.interface.print("shu {s}: {s}\n", .{ cmd, desc });
        try w.interface.flush();
    } else {
        var buf: [128]u8 = undefined;
        var w = std.fs.File.stdout().writer(&buf);
        try w.interface.print("Unknown subcommand: {s}. Run 'shu help' for usage.\n", .{cmd});
        try w.interface.flush();
    }
}
