// Zig 构建配置，定义编译目标与依赖
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1 顶层目录与模块
// Zig 0.16.0-dev：使用 root_module，需先 addModule 再 addExecutable
// 跨平台 JSC：macOS 用系统框架；Linux/Windows 可选 -Djsc_prefix=<dir> 链接 WebKit JSC
//
// 版本号：发布时只改 build() 内 shu_version 一处；会注入 build_options.zig，供 cli/version.zig 使用。建议与 package.json "version" 保持一致。

const std = @import("std");

pub fn build(b: *std.Build) void {
    // CLI 版本号：发布新版本时只改此处；可选通过 -Dversion=x.y.z 覆盖（如 CI 打 tag 时传入）。
    const shu_version = b.option([]const u8, "version", "Shu CLI version (default: 0.1.0)") orelse "0.1.0";

    const target = b.standardTargetOptions(.{});
    // 优化模式：Debug（默认）| ReleaseSafe | ReleaseFast | ReleaseSmall
    // 减小体积：zig build -Doptimize=ReleaseSmall；再配合 strip 可进一步缩小
    const optimize = b.standardOptimizeOption(.{});

    // Cross-platform JSC: macOS 用系统自带框架，不需要 deps/install-*；仅 Linux/Windows 需要 -Djsc_prefix 或自动尝试 install-linux / install-windows
    const is_macos = target.result.os.tag == .macos;
    var have_webkit_jsc = false;
    var jsc_prefix_used: []const u8 = "";
    if (!is_macos) {
        const jsc_prefix_opt = b.option([]const u8, "jsc_prefix", "WebKit JSC root (include/ and lib/) for Linux/Windows; default: Linux=install-linux, Windows=install-windows");
        const default_path: []const u8 = switch (target.result.os.tag) {
            .windows => "deps/install-windows",
            else => "deps/install-linux",
        };
        const path_to_try = if (jsc_prefix_opt) |p| if (p.len > 0) p else default_path else default_path;
        // Zig 0.16.0-dev：std.fs.cwd() 已移除，改用 std.Io.Dir.cwd().openDir(io, path, .{})
        const dir = std.Io.Dir.cwd().openDir(b.graph.io, path_to_try, .{}) catch null;
        if (dir) |d| {
            d.close(b.graph.io);
            have_webkit_jsc = true;
            jsc_prefix_used = path_to_try;
        }
    }

    // TLS（HTTPS）：默认开启，供 Shu.server options.tls 使用；需系统已安装 OpenSSL（libssl, libcrypto）。用 -Dtls=false 可关闭以减小体积或避免 OpenSSL 依赖
    const have_tls = b.option(bool, "tls", "Enable TLS (HTTPS) for Shu.server; requires OpenSSL (default: true)") orelse true;

    // Linux io_uring：目标为 Linux 时固定用 io_uring 做就绪检测（更高效），无构建选项。
    const use_io_uring = target.result.os.tag == .linux;
    // Windows IOCP：目标为 Windows 时默认用 I/O 完成端口做 accept，可 -Duse_iocp=false 回退到 poll。
    const use_iocp = b.option(bool, "use_iocp", "Use IOCP on Windows for accept (default: true when targeting Windows)") orelse (target.result.os.tag == .windows);

    // 00 §7.1 A：ReleaseFast 且 x86/x86_64 时要求 AVX2，避免 SIMD 静默退化为标量（libs/simd_scan 等依赖 @Vector）
    const is_x86 = target.result.cpu.arch == .x86_64 or target.result.cpu.arch == .x86;
    const has_avx2 = if (is_x86) std.Target.x86.featureSetHas(target.result.cpu.features, .avx2) else true;
    if (optimize == .ReleaseFast and is_x86 and !has_avx2) {
        const fail_step = b.addSystemCommand(&.{
            "sh",
            "-c",
            "echo 'error: ReleaseFast build for x86/x86_64 requires AVX2 to avoid silent SIMD scalar fallback (00 §7.1 A). Use -Dcpu=x86_64_v3 or -Dcpu=native.' >&2; exit 1",
        });
        b.getInstallStep().dependOn(&fail_step.step);
    }

    // 生成 build_options.zig，供 runtime/engine.zig 判断是否初始化 JSC；have_tls 供 server/tls.zig；use_io_uring/use_iocp 供 server/mod.zig；version 供 cli/version.zig
    const build_options_content = b.fmt(
        "// 由 build.zig 生成，勿手改\npub const have_webkit_jsc = {};\npub const have_tls = {};\npub const use_io_uring = {};\npub const use_iocp = {};\npub const version = \"{s}\";\n",
        .{ have_webkit_jsc, have_tls, use_io_uring, use_iocp, shu_version },
    );
    const write_files = b.addWriteFiles();
    const build_options_zig = write_files.add("build_options.zig", build_options_content);

    const module_opts: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    };
    const root_module = b.createModule(module_opts);

    // 供 engine.zig 使用：@import("build_options").have_webkit_jsc
    const build_options_module = b.createModule(.{
        .root_source_file = build_options_zig,
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("build_options", build_options_module);

    // 系统状态（平台、CPU/内存/磁盘/网络），供并发上限等使用；先创建以便 libs_process 依赖
    const libs_os_module = b.createModule(.{
        .root_source_file = b.path("src/libs/os.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("libs_os", libs_os_module);

    // 进程级状态（io / environ），main 设置，CLI、io、runtime 等共用；依赖 libs_os 做并发上限的运行时探测
    const libs_process_module = b.createModule(.{
        .root_source_file = b.path("src/libs/process.zig"),
        .target = target,
        .optimize = optimize,
    });
    libs_process_module.addImport("libs_os", libs_os_module);
    root_module.addImport("libs_process", libs_process_module);

    // 统一错误码与 reportToStderr，CLI、package、runtime 等共用；依赖 libs_process
    const errors_module = b.createModule(.{
        .root_source_file = b.path("src/errors.zig"),
        .target = target,
        .optimize = optimize,
    });
    errors_module.addImport("libs_process", libs_process_module);
    root_module.addImport("errors", errors_module);

    // TLS 模块：-Dtls 时提供 TlsContext/TlsStream，供 server/net/tls 使用；实现位于 shu/lib/tls
    const shu_lib_tls = "src/runtime/modules/shu/lib/tls";
    const tls_module = b.createModule(.{
        .root_source_file = b.path(shu_lib_tls ++ "/tls.zig"),
        .target = target,
        .optimize = optimize,
    });
    tls_module.addImport("build_options", build_options_module);
    if (have_tls) {
        // tls.zig 内 @cImport("tls.h") 需能找到 lib/tls/tls.h
        tls_module.addIncludePath(.{ .cwd_relative = shu_lib_tls });
    }
    root_module.addImport("tls", tls_module);

    // HTTP/2：帧解析与 HPACK，供 TLS ALPN h2 时使用
    const http2_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/modules/shu/server/http2.zig"),
        .target = target,
        .optimize = optimize,
    });
    const hpack_huffman_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/modules/shu/server/hpack_huffman.zig"),
        .target = target,
        .optimize = optimize,
    });
    http2_module.addImport("hpack_huffman", hpack_huffman_module);
    root_module.addImport("http2", http2_module);
    // 供 http2 子模块解析 @import("hpack_huffman")（Zig 从 root 解析依赖时需在 root 可见）
    root_module.addImport("hpack_huffman", hpack_huffman_module);

    // Windows IOCP：仅 Windows 目标时 use_iocp 为 true，供 server 用完成端口做 accept
    const iocp_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/modules/shu/server/iocp.zig"),
        .target = target,
        .optimize = optimize,
    });
    iocp_module.addImport("build_options", build_options_module);
    root_module.addImport("iocp", iocp_module);

    // 高性能 I/O 核心：统一 API，按平台分派；实现已迁至 libs/io.zig（原 io_core/mod.zig）
    const io_core_module = b.createModule(.{
        .root_source_file = b.path("src/libs/io.zig"),
        .target = target,
        .optimize = optimize,
    });
    io_core_module.addImport("libs_process", libs_process_module);
    root_module.addImport("libs_io", io_core_module);

    // 仅解压 API（gzip/deflate/br），无 jsc 依赖，供 io_core/http raw_body 自动解压与 package/registry 等使用；根为 zlib/decode.zig
    const shu_zlib_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/modules/shu/zlib/decode.zig"),
        .target = target,
        .optimize = optimize,
    });
    shu_zlib_module.addIncludePath(.{ .cwd_relative = "deps/brotli/c/include" });
    root_module.addImport("shu_zlib", shu_zlib_module);
    io_core_module.addImport("shu_zlib", shu_zlib_module);

    // 未链接 JSC 时使用 jsc_stub.zig，避免未定义符号；macOS 或 -Djsc_prefix 时用真实 jsc.zig
    const use_real_jsc = is_macos or have_webkit_jsc;
    const jsc_src = if (use_real_jsc) b.path("src/runtime/jsc.zig") else b.path("src/runtime/jsc_stub.zig");
    const jsc_module = b.createModule(.{
        .root_source_file = jsc_src,
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("jsc", jsc_module);

    // Comprezz：纯 Zig gzip 压缩，供 server 响应 Content-Encoding: gzip
    const comprezz_module = b.createModule(.{
        .root_source_file = b.path("deps/comprezz/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("comprezz", comprezz_module);

    const exe = b.addExecutable(.{
        .name = "shu",
        .root_module = root_module,
    });

    // 发布时去掉调试符号以减小体积（ReleaseSmall 时效果明显）；Debug 时保留以便堆栈
    exe.root_module.strip = (optimize != .Debug);

    // TLS：-Dtls 时加入 lib/tls/tls.c 并链接 OpenSSL；tls.c 需能找到 tls.h
    if (have_tls) {
        exe.root_module.addCSourceFiles(.{ .files = &[_][]const u8{"src/runtime/modules/shu/lib/tls/tls.c"}, .flags = &.{} });
        exe.root_module.addIncludePath(.{ .cwd_relative = "src/runtime/modules/shu/lib/tls" });
        exe.root_module.linkSystemLibrary("ssl", .{});
        exe.root_module.linkSystemLibrary("crypto", .{});
    }

    // Brotli（br）压缩与解压：deps/brotli 编码端 + 解码端 C 源，供 server 响应压缩与 npm tarball br 解压
    const brotli_include = "deps/brotli/c/include";
    exe.root_module.addIncludePath(.{ .cwd_relative = brotli_include });
    exe.root_module.link_libc = true;
    const brotli_sources = [_][]const u8{
        "deps/brotli/c/common/constants.c",
        "deps/brotli/c/common/context.c",
        "deps/brotli/c/common/dictionary.c",
        "deps/brotli/c/common/platform.c",
        "deps/brotli/c/common/shared_dictionary.c",
        "deps/brotli/c/common/transform.c",
        "deps/brotli/c/enc/backward_references.c",
        "deps/brotli/c/enc/backward_references_hq.c",
        "deps/brotli/c/enc/bit_cost.c",
        "deps/brotli/c/enc/block_splitter.c",
        "deps/brotli/c/enc/brotli_bit_stream.c",
        "deps/brotli/c/enc/cluster.c",
        "deps/brotli/c/enc/command.c",
        "deps/brotli/c/enc/compound_dictionary.c",
        "deps/brotli/c/enc/compress_fragment.c",
        "deps/brotli/c/enc/compress_fragment_two_pass.c",
        "deps/brotli/c/enc/dictionary_hash.c",
        "deps/brotli/c/enc/encode.c",
        "deps/brotli/c/enc/encoder_dict.c",
        "deps/brotli/c/enc/entropy_encode.c",
        "deps/brotli/c/enc/fast_log.c",
        "deps/brotli/c/enc/histogram.c",
        "deps/brotli/c/enc/literal_cost.c",
        "deps/brotli/c/enc/memory.c",
        "deps/brotli/c/enc/metablock.c",
        "deps/brotli/c/enc/static_dict.c",
        "deps/brotli/c/enc/utf8_util.c",
        // 解码端：供 decompressBrotli（如 npm tarball Content-Encoding: br）使用
        "deps/brotli/c/dec/bit_reader.c",
        "deps/brotli/c/dec/decode.c",
        "deps/brotli/c/dec/huffman.c",
        "deps/brotli/c/dec/state.c",
    };
    exe.root_module.addCSourceFiles(.{ .files = &brotli_sources, .flags = &.{} });
    switch (target.result.os.tag) {
        .linux => exe.root_module.addCMacro("OS_LINUX", "1"),
        .freebsd => exe.root_module.addCMacro("OS_FREEBSD", "1"),
        .macos => exe.root_module.addCMacro("OS_MACOSX", "1"),
        else => {},
    }

    // Windows：libs_os 的 getProcessRssKb 需要 psapi（GetProcessMemoryInfo）
    if (target.result.os.tag == .windows) exe.root_module.linkSystemLibrary("psapi", .{});

    // macOS：链接系统 JavaScriptCore 与 CoreFoundation（runLoop 单次迭代以驱动 JSC Promise 微任务）
    if (is_macos) {
        exe.root_module.linkFramework("JavaScriptCore", .{});
        exe.root_module.linkFramework("CoreFoundation", .{});
    }

    // Linux/Windows：若 have_webkit_jsc 则链接 jsc_prefix_used（即 -Djsc_prefix 或默认 deps/webkit/install）
    if (have_webkit_jsc) {
        const prefix = jsc_prefix_used;
        exe.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
        exe.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
        exe.root_module.linkSystemLibrary("JavaScriptCore", .{}); // 或按实际库名调整，如 jsc
    } else if (!is_macos) {
        const fail_step = b.addSystemCommand(&.{
            "sh",
            "-c",
            "echo 'error: Linux/Windows build requires a valid -Djsc_prefix=<WebKit JSC root>. See src/runtime/engine/BUILTINS.md for how to obtain WebKit JSC.' >&2; exit 1",
        });
        b.getInstallStep().dependOn(&fail_step.step);
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run shu CLI");
    run_step.dependOn(&run_cmd.step);

    // 单元测试：入口为 src/test_runner.zig，模块根为 src/；拉入 server/http2.zig 时需能解析 hpack_huffman
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/test_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("hpack_huffman", hpack_huffman_module);
    test_module.addImport("libs_io", io_core_module);
    test_module.addImport("errors", errors_module);
    test_module.addImport("libs_process", libs_process_module);
    const test_exe = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run all tests (目标：全面覆盖)");
    test_step.dependOn(&run_tests.step);
    // path/fs 等测试需运行 zig-out/bin/shu，故 test 前先执行 install
    run_tests.step.dependOn(b.getInstallStep());

    // 从 BUILTINS.md 自动生成 JS API 参考文档（输出到 docs/JS_API_REFERENCE.md）
    const gen_docs = b.addSystemCommand(&.{
        "zig",
        "run",
        "scripts/generate_js_api_docs.zig",
    });
    gen_docs.setCwd(.{ .cwd_relative = "." });
    const js_api_docs_step = b.step("js-api-docs", "Generate docs/JS_API_REFERENCE.md from BUILTINS.md");
    js_api_docs_step.dependOn(&gen_docs.step);
}
