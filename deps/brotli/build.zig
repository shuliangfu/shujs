const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig 0.16.0-dev：用 createModule + addLibrary 替代已移除的 addStaticLibrary
    // 体积优化：strip 去掉符号；用 zig build -Doptimize=ReleaseSmall 可把 .a 从约 7MB 压到 ~700KB
    const root = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    const lib = b.addLibrary(.{
        .name = "brotli",
        .root_module = root,
        .linkage = .static,
    });

    lib.linkLibC();
    lib.addIncludePath(b.path("c/include"));
    lib.addCSourceFiles(.{ .files = &sources, .flags = &.{} });
    lib.installHeadersDirectory(b.path("c/include/brotli"), "brotli", .{});

    switch (target.result.os.tag) {
        .linux => lib.root_module.addCMacro("OS_LINUX", "1"),
        .freebsd => lib.root_module.addCMacro("OS_FREEBSD", "1"),
        .macos => lib.root_module.addCMacro("OS_MACOSX", "1"),
        else => {},
    }

    b.installArtifact(lib);
}

// 仅压缩端（encode），不解压（dec）；服务端响应 br 压缩用
const sources = [_][]const u8{
    "c/common/constants.c",
    "c/common/context.c",
    "c/common/dictionary.c",
    "c/common/platform.c",
    "c/common/shared_dictionary.c",
    "c/common/transform.c",
    "c/enc/backward_references.c",
    "c/enc/backward_references_hq.c",
    "c/enc/bit_cost.c",
    "c/enc/block_splitter.c",
    "c/enc/brotli_bit_stream.c",
    "c/enc/cluster.c",
    "c/enc/command.c",
    "c/enc/compound_dictionary.c",
    "c/enc/compress_fragment.c",
    "c/enc/compress_fragment_two_pass.c",
    "c/enc/dictionary_hash.c",
    "c/enc/encode.c",
    "c/enc/encoder_dict.c",
    "c/enc/entropy_encode.c",
    "c/enc/fast_log.c",
    "c/enc/histogram.c",
    "c/enc/literal_cost.c",
    "c/enc/memory.c",
    "c/enc/metablock.c",
    "c/enc/static_dict.c",
    "c/enc/utf8_util.c",
};
