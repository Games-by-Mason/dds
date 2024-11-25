const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build the library
    const lib = b.addModule("Ktx2", .{
        .root_source_file = b.path("src/Ktx2.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build the command line tool
    if (b.lazyDependency("bc7enc_rdo", .{})) |bc7enc| {
        if (b.lazyDependency("structopt", .{
            .target = target,
            .optimize = optimize,
        })) |structopt| {
            if (b.lazyDependency("stb", .{})) |stb| {
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
                libbc7enc.installHeadersDirectory(bc7enc.path("."), "bc7enc", .{});

                // Build the executable
                const exe = b.addExecutable(.{
                    .name = "zex",
                    .root_source_file = b.path("src/zex.zig"),
                    .target = target,
                    .optimize = optimize,
                });
                exe.root_module.addImport("Ktx2", lib);
                exe.linkLibrary(libbc7enc);
                exe.addCSourceFile(.{ .file = b.path("src/bindings.cpp") });
                exe.addIncludePath(b.path("src"));
                exe.addIncludePath(stb.path(""));
                exe.root_module.addImport("structopt", structopt.module("structopt"));
                b.installArtifact(exe);

                // Create the run command
                const run_cmd = b.addRunArtifact(exe);
                run_cmd.step.dependOn(b.getInstallStep());
                if (b.args) |args| {
                    run_cmd.addArgs(args);
                }
                const run_step = b.step("run", "Run the app");
                run_step.dependOn(&run_cmd.step);
            }
        }
    }
}
