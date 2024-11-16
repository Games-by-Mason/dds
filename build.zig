const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build the library
    const lib = b.addModule("Dds", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build lodepng
    const bc7enc_zig = b.dependency("bc7enc_rdo", .{
        .target = target,
        .optimize = optimize,
    });
    const bc7enc = bc7enc_zig.builder.dependency("bc7enc_rdo", .{
        .target = target,
        .optimize = optimize,
    });
    const lodepng = b.addStaticLibrary(.{
        .name = "lodepng",
        .target = target,
        // Lodepng fails UBSAN
        .optimize = .ReleaseFast,
    });
    const rename_lodepng = b.addWriteFiles();
    const lodepng_c = rename_lodepng.addCopyFile(bc7enc.path("lodepng.cpp"), "lodepng.c");
    lodepng.addCSourceFile(.{ .file = lodepng_c });
    lodepng.addIncludePath(bc7enc.path(""));
    lodepng.installHeader(bc7enc.path("lodepng.h"), "lodepng.h");
    lodepng.linkLibC();

    // Build the command line tool
    const exe = b.addExecutable(.{
        .name = "dds",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("Dds", lib);
    exe.linkLibrary(lodepng);

    const structopt = b.dependency("structopt", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("structopt", structopt.module("structopt"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
