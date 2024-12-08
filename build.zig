const std = @import("std");

pub fn build(b: *std.Build) void {
    // Build options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tracy_enabled = b.option(
        bool,
        "tracy",
        "Build with Tracy support.",
    ) orelse false;

    // Fetch dependencies
    const bc7enc = b.dependency("bc7enc_rdo", .{});
    const stb = b.dependency("stb", .{});
    const structopt = b.dependency("structopt", .{
        .target = target,
        .optimize = optimize,
    });

    // Build Ktx2
    const ktx2 = b.addModule("Ktx2", .{
        .root_source_file = b.path("src/Ktx2.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build bc7enc
    const libbc7enc = b.addStaticLibrary(.{
        .name = "bc7enc",
        .target = target,
        // Doesn't currently pass safety checks
        .optimize = switch (optimize) {
            .ReleaseSmall => .ReleaseSmall,
            else => .ReleaseFast,
        },
    });
    libbc7enc.addIncludePath(bc7enc.path(""));
    libbc7enc.addCSourceFiles(.{
        .root = bc7enc.path(""),
        .files = &.{
            "bc7enc.cpp",
            "bc7decomp.cpp",
            "bc7decomp_ref.cpp",
            "lodepng.cpp",
            "rgbcx.cpp",
            "utils.cpp",
            "ert.cpp",
            "rdo_bc_encoder.cpp",
        },
    });
    libbc7enc.linkLibCpp();
    libbc7enc.addIncludePath(bc7enc.path("."));
    libbc7enc.installHeadersDirectory(bc7enc.path("."), "bc7enc", .{});

    // Build the C bindings
    const bindings = b.addStaticLibrary(.{
        .name = "bindings",
        .target = target,
        // Doesn't currently pass safety checks
        .optimize = switch (optimize) {
            .ReleaseSmall => .ReleaseSmall,
            else => .ReleaseFast,
        },
    });
    bindings.addIncludePath(stb.path(""));
    bindings.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{
            "bindings.cpp",
        },
    });
    bindings.installHeadersDirectory(stb.path("."), "", .{});
    bindings.linkLibrary(libbc7enc);

    // Build Tracy
    const tracy = b.dependency("tracy", .{
        .target = target,
        .optimize = optimize,
    });

    // Build Zex
    const zex = b.addModule("zex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zex.addImport("Ktx2", ktx2);
    zex.linkLibrary(bindings);
    zex.addImport("tracy", tracy.module("tracy"));

    // Build the command line tool
    const zex_exe = b.addExecutable(.{
        .name = "zex",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    zex_exe.root_module.addImport("zex", zex);
    zex_exe.root_module.addImport("structopt", structopt.module("structopt"));

    zex_exe.root_module.addImport("tracy", tracy.module("tracy"));
    if (tracy_enabled) {
        zex_exe.root_module.addImport("tracy_impl", tracy.module("tracy_impl_enabled"));
    } else {
        zex_exe.root_module.addImport("tracy_impl", tracy.module("tracy_impl_disabled"));
    }

    b.installArtifact(zex_exe);

    // Create the run command
    const run_cmd = b.addRunArtifact(zex_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
