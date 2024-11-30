const std = @import("std");
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const builtin = @import("builtin");
const assert = std.debug.assert;
const Ktx2 = @import("Ktx2");
const structopt = @import("structopt");
const Command = structopt.Command;
const NamedArg = structopt.NamedArg;
const PositionalArg = structopt.PositionalArg;
const log = std.log;
const c = @import("c.zig");
const Image = @import("Image.zig");

const max_file_len = 4294967296;

const ColorSpace = enum {
    linear,
    srgb,
};

const Alpha = enum {
    straight,
    premultiplied,
};

const ZlibLevel = enum(u4) {
    const StdLevel = std.compress.flate.deflate.Level;

    fastest = @intFromEnum(StdLevel.fast),
    smallest = @intFromEnum(StdLevel.best),

    @"4" = @intFromEnum(StdLevel.level_4),
    @"5" = @intFromEnum(StdLevel.level_5),
    @"6" = @intFromEnum(StdLevel.level_6),
    @"7" = @intFromEnum(StdLevel.level_7),
    @"8" = @intFromEnum(StdLevel.level_8),
    @"9" = @intFromEnum(StdLevel.level_9),

    pub fn toStdLevel(self: @This()) StdLevel {
        return @enumFromInt(@intFromEnum(self));
    }
};

const command: Command = .{
    .name = "zex",
    .description = "Converts images to KTX2.",
    .named_args = &.{
        NamedArg.init(Alpha, .{
            .description = "whether or not the input is already premultiplied",
            .long = "alpha-input",
            .default = .{ .value = .straight },
        }),
        NamedArg.init(Alpha, .{
            .description = "must be set if the alpha channel is transparency",
            .long = "alpha-output",
            .default = .{ .value = .premultiplied },
        }),
        NamedArg.init(?ZlibLevel, .{
            .description = "supercompress the data at the given level with zlib",
            .long = "zlib",
            .default = .{ .value = null },
        }),
        NamedArg.init(bool, .{
            .description = "automatically generate mipmaps",
            .long = "generate-mipmaps",
            .default = .{ .value = false },
        }),
        NamedArg.init(?f32, .{
            .description = "preserves alpha coverage for the given alpha test threshold, slower but significantly improves mipmapping of cutouts and alpha to coverage textures",
            .long = "preserve-alpha-coverage",
            .default = .{ .value = null },
        }),
        NamedArg.init(?Image.ResizeOptions.Filter, .{
            .description = "defaults to the mitchell filter for LDR images, box for HDR images",
            .long = "filter",
            .default = .{ .value = null },
        }),
        NamedArg.init(?Image.ResizeOptions.Filter, .{
            .description = "overrides --filter in the U direction",
            .long = "filter-u",
            .default = .{ .value = null },
        }),
        NamedArg.init(?Image.ResizeOptions.Filter, .{
            .description = "overrides --filter in the V direction",
            .long = "filter-v",
            .default = .{ .value = null },
        }),
        NamedArg.init(?Image.ResizeOptions.AddressMode, .{
            .long = "address-mode",
            .default = .{ .value = null },
        }),
        NamedArg.init(?Image.ResizeOptions.AddressMode, .{
            .description = "overrides --address-mode in the U direction",
            .long = "address-mode-u",
            .default = .{ .value = null },
        }),
        NamedArg.init(?Image.ResizeOptions.AddressMode, .{
            .description = "overrides --address-mode in the V direction",
            .long = "address-mode-v",
            .default = .{ .value = null },
        }),
        NamedArg.init(?u32, .{
            .description = "scale the largest dimension down to max size, preserves aspect ratio",
            .long = "max-size",
            .default = .{ .value = null },
        }),
        NamedArg.init(?u32, .{
            .description = "overrides --max-size for the width, still preserves aspect ratio",
            .long = "max-width",
            .default = .{ .value = null },
        }),
        NamedArg.init(?u32, .{
            .description = "overrides --max-size for the height, still preserves aspect ratio",
            .long = "max-height",
            .default = .{ .value = null },
        }),
    },
    .positional_args = &.{
        PositionalArg.init([]const u8, .{
            .meta = "INPUT",
        }),
        PositionalArg.init([]const u8, .{
            .meta = "OUTPUT",
        }),
    },
    .subcommands = &.{
        rgba_u8_command,
        rgba_f32_command,
        bc7_command,
    },
};

const rgba_u8_command: Command = .{
    .name = "rgba-u8",
    .named_args = &.{
        NamedArg.init(ColorSpace, .{
            .long = "color-space",
            .default = .{ .value = .srgb },
        }),
    },
};

const rgba_f32_command: Command = .{
    .name = "rgba-f32",
};

const bc7_command: Command = .{
    .name = "bc7",
    .named_args = &.{
        NamedArg.init(ColorSpace, .{
            .long = "color-space",
            .default = .{ .value = .srgb },
        }),
        NamedArg.init(u8, .{
            .description = "quality level, defaults to highest",
            .long = "uber",
            .default = .{ .value = Bc7Enc.Params.max_uber_level },
        }),
        NamedArg.init(bool, .{
            .description = "reduce entropy for better supercompression",
            .long = "reduce-entropy",
            .default = .{ .value = false },
        }),
        NamedArg.init(u8, .{
            .description = "partitions to scan in mode 1, defaults to highest",
            .long = "max-partitions-to-scan",
            .default = .{ .value = Bc7Enc.Params.max_partitions },
        }),
        NamedArg.init(bool, .{
            .long = "mode-6-only",
            .default = .{ .value = false },
        }),
        NamedArg.init(?u32, .{
            .long = "max-threads",
            .default = .{ .value = null },
        }),
        NamedArg.init(bool, .{
            .long = "status-output",
            .default = .{ .value = false },
        }),
    },
    .subcommands = &.{rdo_command},
};

const rdo_command: Command = .{
    .name = "rdo",
    .description = "use RDO for better supercompression",
    .named_args = &.{
        NamedArg.init(f32, .{
            .description = "rdo to apply",
            .long = "lambda",
            .default = .{ .value = 0.5 },
        }),
        NamedArg.init(?u17, .{
            .long = "lookback-window",
            .default = .{ .value = null },
        }),
        NamedArg.init(?f32, .{
            .description = "manually set smooth block error scale factor, higher values result in less distortion",
            .long = "smooth-block-error-scale",
            .default = .{ .value = 15.0 },
        }),
        NamedArg.init(bool, .{
            .long = "quantize-mode6-endpoints",
            .default = .{ .value = true },
        }),
        NamedArg.init(bool, .{
            .long = "weight-modes",
            .default = .{ .value = true },
        }),
        NamedArg.init(bool, .{
            .long = "weight-low-frequency-partitions",
            .default = .{ .value = true },
        }),
        NamedArg.init(bool, .{
            .long = "pbit1-weighting",
            .default = .{ .value = true },
        }),
        NamedArg.init(f32, .{
            .long = "max-smooth-block-std-dev",
            .default = .{ .value = 18.0 },
        }),
        NamedArg.init(bool, .{
            .long = "try-two-matches",
            .default = .{ .value = true },
        }),
        NamedArg.init(bool, .{
            .long = "ultrasmooth-block-handling",
            .default = .{ .value = true },
        }),
    },
};

pub fn main() !void {
    // Setup
    comptime assert(builtin.cpu.arch.endian() == .little);
    defer std.process.cleanExit();

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var arg_iter = std.process.argsWithAllocator(allocator) catch @panic("OOM");
    defer arg_iter.deinit();
    const args = command.parseOrExit(allocator, &arg_iter);
    defer command.parseFree(args);

    const encoding = args.subcommand orelse {
        log.err("subcommand not specified", .{});
        std.process.exit(1);
    };

    if (args.named.@"alpha-input" == .premultiplied and args.named.@"alpha-output" == .straight) {
        log.err("conversion from premultiplied to straight alpha is not supported", .{});
        std.process.exit(1);
    }

    const maybe_address_mode_u = args.named.@"address-mode-u" orelse args.named.@"address-mode";
    const maybe_address_mode_v = args.named.@"address-mode-v" orelse args.named.@"address-mode";
    const default_filter: Image.ResizeOptions.Filter = switch (encoding) {
        .bc7, .@"rgba-u8" => .mitchell,
        .@"rgba-f32" => .box,
    };
    const filter_u = args.named.@"filter-u" orelse args.named.filter orelse default_filter;
    const filter_v = args.named.@"filter-v" orelse args.named.filter orelse default_filter;
    if (filter_u == .box and maybe_address_mode_u != null and maybe_address_mode_u != .clamp) {
        // Not supported by current STB, has no effect if set
        log.err("{s}: box filtering can only be used with address mode clamp", .{args.positional.INPUT});
        std.process.exit(1);
    }
    if (filter_v == .box and maybe_address_mode_v != null and maybe_address_mode_v != .clamp) {
        // Not supported by current STB, has no effect if set
        log.err("{s}: box filtering can only be used with address mode clamp", .{args.positional.INPUT});
        std.process.exit(1);
    }

    const cwd = std.fs.cwd();

    // Load the first level
    var input = cwd.openFile(args.positional.INPUT, .{}) catch |err| {
        log.err("{s}: {s}", .{ args.positional.INPUT, @errorName(err) });
        std.process.exit(1);
    };
    defer input.close();

    const input_bytes = input.readToEndAllocOptions(allocator, max_file_len, null, 1, 0) catch |err| {
        log.err("{s}: {s}", .{ args.positional.INPUT, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(input_bytes);

    const original = Image.init(.{
        .bytes = input_bytes,
        .color_space = switch (encoding) {
            inline .bc7, .@"rgba-u8" => |ec| switch (ec.named.@"color-space") {
                .srgb => .srgb,
                .linear => .linear,
            },
            .@"rgba-f32" => .hdr,
        },
    }) catch |err| switch (err) {
        error.StbImageFailure => {
            log.err("{s}: failed reading image", .{args.positional.INPUT});
            std.process.exit(1);
        },
        error.LdrAsHdr => {
            log.err("{s}: cannot store LDR input image as HDR format", .{args.positional.INPUT});
            std.process.exit(1);
        },
    };
    defer original.deinit();

    if (args.named.@"alpha-input" == .straight and args.named.@"alpha-output" == .premultiplied) {
        original.premultiply();
    }

    // Sharpening filters can cause extreme artifacts on HDR images. See #15 for more
    // information.
    if (original.hdr) {
        if (filter_u.sharpens()) {
            log.err(
                "{s}: {s} filter applies sharpening, is not compatible with HDR images",
                .{ args.positional.INPUT, @tagName(filter_u) },
            );
            std.process.exit(1);
        }
        if (filter_v.sharpens()) {
            log.err(
                "{s}: {s} filter applies sharpening, is not compatible with HDR images",
                .{ args.positional.INPUT, @tagName(filter_v) },
            );
            std.process.exit(1);
        }
    }

    // Copy the original image into the mip levels, scaling it if needed.
    var raw_levels: std.BoundedArray(Image, Ktx2.max_levels) = .{};
    defer for (raw_levels.constSlice()[1..]) |level| {
        level.deinit();
    };
    {
        // Read the scale parameters
        const maybe_max_width = args.named.@"max-width" orelse args.named.@"max-size";
        const maybe_max_height = args.named.@"max-height" orelse args.named.@"max-size";

        // Check if any scaling was requested
        if (maybe_max_width != null or maybe_max_height != null) {
            // If it was, validate the other input arguments, even if it turns out that the image
            // is already small enough (an artist resizing an input image shouldn't cause a
            // previously working bake step to start failing!)
            const max_width = maybe_max_width orelse original.width;
            const max_height = maybe_max_height orelse original.height;
            const address_mode_u = maybe_address_mode_u orelse {
                log.err("{s}: address-mode not set", .{args.positional.INPUT});
                std.process.exit(1);
            };
            const address_mode_v = maybe_address_mode_v orelse {
                log.err("{s}: address-mode not set", .{args.positional.INPUT});
                std.process.exit(1);
            };

            // Perform the resize if one is necessary
            const x_scale = @min(@as(f64, @floatFromInt(max_width)) / @as(f64, @floatFromInt(original.width)), 1.0);
            const y_scale = @min(@as(f64, @floatFromInt(max_height)) / @as(f64, @floatFromInt(original.height)), 1.0);
            const scale = @min(x_scale, y_scale);
            const width = @min(@as(u32, @intFromFloat(scale * @as(f64, @floatFromInt(original.width)))), max_width);
            const height = @min(@as(u32, @intFromFloat(scale * @as(f64, @floatFromInt(original.height)))), max_height);
            const scaled = original.resize(.{
                .width = width,
                .height = height,
                .address_mode_u = address_mode_u,
                .address_mode_v = address_mode_v,
                .filter_u = filter_u,
                .filter_v = filter_v,
            }) orelse {
                log.err("{s}: resize failed", .{args.positional.INPUT});
                std.process.exit(1);
            };
            raw_levels.appendAssumeCapacity(scaled);
        } else {
            raw_levels.appendAssumeCapacity(original.copy() orelse {
                log.err("{s}: out of memory", .{args.positional.INPUT});
                std.process.exit(1);
            });
        }
    }

    // Generate mipmaps for the other levels if requested
    if (args.named.@"generate-mipmaps") {
        const address_mode_u = maybe_address_mode_u orelse {
            log.err("{s}: address-mode not set", .{args.positional.INPUT});
            std.process.exit(1);
        };
        const address_mode_v = maybe_address_mode_v orelse {
            log.err("{s}: address-mode not set", .{args.positional.INPUT});
            std.process.exit(1);
        };

        const block_size: u8 = switch (encoding) {
            .@"rgba-u8", .@"rgba-f32" => 1,
            .bc7 => 4,
        };

        var generate_mipmaps = raw_levels.get(0).generateMipmaps(.{
            .address_mode_u = address_mode_u,
            .address_mode_v = address_mode_v,
            .filter_u = filter_u,
            .filter_v = filter_v,
            .block_size = block_size,
        });

        while (generate_mipmaps.next()) |mipmap| {
            raw_levels.appendAssumeCapacity(mipmap);
        }
    }

    // Cutout the textures if requested
    if (args.named.@"preserve-alpha-coverage") |threshold_raw| {
        // Check the threshold's range, and quantize it if necessary
        if (threshold_raw < 0.0 or threshold_raw > 1.0) {
            log.err("{s}: cutout threshold must be between 0 and 1 inclusive", .{args.positional.INPUT});
            std.process.exit(1);
        }
        const threshold = switch (encoding) {
            .@"rgba-u8", .bc7 => @round(threshold_raw * 255.0) / 255.0,
            .@"rgba-f32" => threshold_raw,
        };

        // Determine the target coverage
        const target_coverage = original.alphaCoverage(threshold, 1.0);

        // Process each mip level
        for (raw_levels.constSlice(), 0..) |level, level_i| {
            // Binary search for the best scale parameter
            var best_scale: f32 = 1.0;
            if (level_i > 0) {
                var best_dist = std.math.inf(f32);
                var upper_threshold: f32 = 1.0;
                var lower_threshold: f32 = 0.0;
                var curr_threshold: f32 = threshold;
                for (0..10) |_| {
                    const curr_scale = threshold / curr_threshold;
                    const coverage = level.alphaCoverage(threshold, curr_scale);
                    const dist_to_coverage = @abs(coverage - target_coverage);
                    if (dist_to_coverage < best_dist) {
                        best_dist = dist_to_coverage;
                        best_scale = curr_scale;
                    }

                    if (coverage < target_coverage) {
                        upper_threshold = curr_threshold;
                    } else {
                        lower_threshold = curr_threshold;
                    }
                    curr_threshold = (lower_threshold + upper_threshold) / 2.0;
                }
            }

            for (0..@as(usize, level.width) * @as(usize, level.height)) |i| {
                const a = &level.data[i * 4 + 3];
                a.* = @min(a.* * best_scale, 1.0);
            }
        }
    }

    // Encode the pixel data
    var bc7_encoders: std.BoundedArray(*Bc7Enc, Ktx2.max_levels) = .{};
    defer for (bc7_encoders.constSlice()) |bc7_encoder| {
        bc7_encoder.deinit();
    };
    var u8_encodings: std.BoundedArray([]u8, Ktx2.max_levels) = .{};
    defer for (u8_encodings.constSlice()) |u8_encoding| {
        allocator.free(u8_encoding);
    };
    var encoded_levels: std.BoundedArray([]u8, Ktx2.max_levels) = .{};
    switch (encoding) {
        .@"rgba-u8" => |encoding_options| for (raw_levels.constSlice()) |raw_level| {
            const encoded_level = allocator.alloc(u8, raw_level.data.len) catch {
                log.err("{s}: out of memory", .{args.positional.INPUT});
                std.process.exit(1);
            };
            for (0..@as(usize, raw_level.width) * @as(usize, raw_level.height) * 4) |i| {
                var ldr = raw_level.data[i];
                if (encoding_options.named.@"color-space" == .srgb and i % 4 != 3) {
                    ldr = std.math.pow(f32, ldr, 1.0 / 2.2);
                }
                ldr = std.math.clamp(ldr * 255.0 + 0.5, 0.0, 255.0);
                encoded_level[i] = @intFromFloat(ldr);
            }
            u8_encodings.appendAssumeCapacity(encoded_level);
            encoded_levels.appendAssumeCapacity(encoded_level);
        },
        .@"rgba-f32" => for (raw_levels.constSlice()) |raw_level| {
            encoded_levels.appendAssumeCapacity(std.mem.sliceAsBytes(raw_level.data));
        },
        .bc7 => |bc7| {
            // Determine the bc7 params
            var params: Bc7Enc.Params = .{};
            {
                if (bc7.named.uber > Bc7Enc.Params.max_uber_level) {
                    log.err("invalid value for uber", .{});
                    std.process.exit(1);
                }
                params.bc7_uber_level = bc7.named.uber;

                params.reduce_entropy = bc7.named.@"reduce-entropy";

                if (bc7.named.@"max-partitions-to-scan" > Bc7Enc.Params.max_partitions) {
                    log.err("invalid value for max-partitions-to-scan", .{});
                    std.process.exit(1);
                }
                params.max_partitions_to_scan = bc7.named.@"max-partitions-to-scan";
                // Ignored when using RDO. However, we use it in our bindings. The actual encoder
                // just clears it so it doesn't matter that we set it regardless.
                params.perceptual = bc7.named.@"color-space" == .srgb;
                params.mode6_only = bc7.named.@"mode-6-only";

                if (bc7.named.@"max-threads") |v| {
                    if (v == 0) {
                        log.err("invalid value for max-threads", .{});
                        std.process.exit(1);
                    }
                    params.rdo_max_threads = v;
                } else {
                    params.rdo_max_threads = @intCast(std.math.clamp(
                        std.Thread.getCpuCount() catch 1,
                        1,
                        std.math.maxInt(u32),
                    ));
                }
                params.rdo_multithreading = params.rdo_max_threads > 1;
                params.status_output = bc7.named.@"status-output";

                if (bc7.subcommand) |bc7_subcommand| switch (bc7_subcommand) {
                    .rdo => |rdo| {
                        if ((rdo.named.lambda < 0.0) or (rdo.named.lambda > 500.0)) {
                            log.err("invalid value for lambda", .{});
                            std.process.exit(1);
                        }
                        params.rdo_lambda = rdo.named.lambda;

                        if (rdo.named.@"lookback-window") |lookback_window| {
                            if (lookback_window < Bc7Enc.Params.min_lookback_window_size) {
                                log.err("invalid value for lookback-window", .{});
                                std.process.exit(1);
                            }
                            params.lookback_window_size = lookback_window;
                            params.custom_lookback_window_size = true;
                        }

                        if (rdo.named.@"smooth-block-error-scale") |v| {
                            if ((v < 1.0) or (v > 500.0)) {
                                log.err("invalid value for smooth-block-error-scale", .{});
                                std.process.exit(1);
                            }
                            params.rdo_smooth_block_error_scale = v;
                            params.custom_rdo_smooth_block_error_scale = true;
                        }

                        params.rdo_bc7_quant_mode6_endpoints = rdo.named.@"quantize-mode6-endpoints";
                        params.rdo_bc7_weight_modes = rdo.named.@"weight-modes";
                        params.rdo_bc7_weight_low_frequency_partitions = rdo.named.@"weight-low-frequency-partitions";
                        params.rdo_bc7_pbit1_weighting = rdo.named.@"pbit1-weighting";

                        if ((rdo.named.@"max-smooth-block-std-dev") < 0.000125 or (rdo.named.@"max-smooth-block-std-dev" > 256.0)) {
                            log.err("invalid value for max-smooth-block-std-dev", .{});
                            std.process.exit(1);
                        }
                        params.rdo_max_smooth_block_std_dev = rdo.named.@"max-smooth-block-std-dev";
                        params.rdo_try_2_matches = rdo.named.@"try-two-matches";
                        params.rdo_ultrasmooth_block_handling = rdo.named.@"ultrasmooth-block-handling";
                    },
                };
            }

            // Encode the levels
            for (raw_levels.constSlice()) |raw_level| {
                bc7_encoders.appendAssumeCapacity(Bc7Enc.init() orelse {
                    log.err("bc7enc: initialization failed", .{});
                    std.process.exit(1);
                });

                const bc7_encoder = bc7_encoders.get(bc7_encoders.len - 1);

                if (!bc7_encoder.encode(
                    &params,
                    raw_level.width,
                    raw_level.height,
                    raw_level.data.ptr,
                )) {
                    log.err("{s}: encoder failed", .{args.positional.INPUT});
                    std.process.exit(1);
                }

                encoded_levels.appendAssumeCapacity(bc7_encoder.getBlocks());
            }
        },
    }

    // Compress the data if needed
    var compressed_levels: std.BoundedArray([]u8, Ktx2.max_levels) = .{};
    if (args.named.zlib) |zlib_level| {
        for (encoded_levels.constSlice()) |level| {
            var compressed = ArrayListUnmanaged(u8).initCapacity(allocator, encoded_levels.constSlice()[0].len) catch |err| {
                log.err("{s}: deflate failed: {s}", .{ args.positional.OUTPUT, @errorName(err) });
                std.process.exit(1);
            };
            defer compressed.deinit(allocator);

            const Compressor = std.compress.flate.deflate.Compressor(.zlib, @TypeOf(compressed).Writer);
            var compressor = Compressor.init(
                compressed.writer(allocator),
                .{ .level = zlib_level.toStdLevel() },
            ) catch |err| {
                log.err("{s}: deflate failed: {s}", .{ args.positional.OUTPUT, @errorName(err) });
                std.process.exit(1);
            };
            _ = compressor.write(level) catch |err| {
                log.err("{s}: deflate failed: {s}", .{ args.positional.OUTPUT, @errorName(err) });
                std.process.exit(1);
            };
            compressor.finish() catch |err| {
                log.err("{s}: deflate failed: {s}", .{ args.positional.OUTPUT, @errorName(err) });
                std.process.exit(1);
            };
            compressed_levels.appendAssumeCapacity(compressed.toOwnedSlice(allocator) catch |err| {
                log.err("{s}: deflate failed: {s}", .{ args.positional.OUTPUT, @errorName(err) });
                std.process.exit(1);
            });
        }
    } else {
        for (encoded_levels.constSlice()) |encoded_level| {
            compressed_levels.appendAssumeCapacity(encoded_level);
        }
    }
    defer if (args.named.zlib != null) for (compressed_levels.constSlice()) |compressed_level| {
        allocator.free(compressed_level);
    };

    // Create the output file writer
    var output_file = cwd.createFile(args.positional.OUTPUT, .{}) catch |err| {
        log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
        std.process.exit(1);
    };
    defer {
        output_file.sync() catch |err| @panic(@errorName(err));
        output_file.close();
    }
    const writer = output_file.writer();

    // Write the header
    const samples: u8 = switch (encoding) {
        .@"rgba-u8", .@"rgba-f32" => 4,
        .bc7 => 1,
    };
    const index = Ktx2.Header.Index.init(.{
        .levels = @intCast(compressed_levels.len),
        .samples = samples,
    });
    writer.writeStruct(Ktx2.Header{
        .format = switch (encoding) {
            .@"rgba-u8" => |encoding_options| switch (encoding_options.named.@"color-space") {
                .linear => .r8g8b8a8_uint,
                .srgb => .r8g8b8a8_srgb,
            },
            .@"rgba-f32" => .r32g32b32a32_sfloat,
            .bc7 => |encoding_options| switch (encoding_options.named.@"color-space") {
                .linear => .bc7_unorm_block,
                .srgb => .bc7_srgb_block,
            },
        },
        .type_size = switch (encoding) {
            .@"rgba-u8", .bc7 => 1,
            .@"rgba-f32" => 4,
        },
        .pixel_width = raw_levels.get(0).width,
        .pixel_height = raw_levels.get(0).height,
        .pixel_depth = 0,
        .layer_count = 0,
        .face_count = 1,
        .level_count = .fromInt(@intCast(compressed_levels.len)),
        .supercompression_scheme = if (args.named.zlib != null) .zlib else .none,
        .index = index,
    }) catch |err| {
        log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
        std.process.exit(1);
    };

    const level_alignment: u8 = if (args.named.zlib != null) 1 else switch (encoding) {
        .@"rgba-u8" => 4,
        .@"rgba-f32" => 16,
        .bc7 => 16,
    };
    {
        // Calculate the byte offsets, taking into account that KTX2 requires mipmaps be stored from
        // largest to smallest for streaming purposes
        var byte_offsets_reverse: std.BoundedArray(usize, Ktx2.max_levels) = .{};
        {
            var byte_offset: usize = index.dfd_byte_offset + index.dfd_byte_length;
            for (0..compressed_levels.len) |i| {
                byte_offset = std.mem.alignForward(usize, byte_offset, level_alignment);
                const compressed_level = compressed_levels.get(compressed_levels.len - i - 1);
                byte_offsets_reverse.appendAssumeCapacity(byte_offset);
                byte_offset += compressed_level.len;
            }
        }

        // Write the level index data, this is done from largest to smallest, only the actual data
        // is stored in reverse order.
        for (0..compressed_levels.len) |i| {
            writer.writeStruct(Ktx2.Level{
                .byte_offset = byte_offsets_reverse.get(compressed_levels.len - i - 1),
                .byte_length = compressed_levels.get(i).len,
                .uncompressed_byte_length = encoded_levels.get(i).len,
            }) catch |err| {
                log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
                std.process.exit(1);
            };
        }
    }

    // Write the data descriptor
    writer.writeInt(u32, index.dfd_byte_length, .little) catch |err| {
        log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
        std.process.exit(1);
    };
    writer.writeAll(std.mem.asBytes(&Ktx2.BasicDescriptorBlock{
        .descriptor_block_size = Ktx2.BasicDescriptorBlock.descriptorBlockSize(samples),
        .model = switch (encoding) {
            .@"rgba-u8", .@"rgba-f32" => .rgbsda,
            .bc7 => .bc7,
        },
        .primaries = .bt709,
        .transfer = switch (encoding) {
            .@"rgba-f32" => .linear,
            inline else => |encoding_options| switch (encoding_options.named.@"color-space") {
                .linear => .linear,
                .srgb => .srgb,
            },
        },
        .flags = .{
            .alpha_premultiplied = args.named.@"alpha-output" == .premultiplied,
        },
        .texel_block_dimension_0 = switch (encoding) {
            .@"rgba-u8", .@"rgba-f32" => .fromInt(1),
            .bc7 => .fromInt(4),
        },
        .texel_block_dimension_1 = switch (encoding) {
            .@"rgba-u8", .@"rgba-f32" => .fromInt(1),
            .bc7 => .fromInt(4),
        },
        .texel_block_dimension_2 = .fromInt(1),
        .texel_block_dimension_3 = .fromInt(1),
        .bytes_plane_0 = if (args.named.zlib != null) 0 else switch (encoding) {
            .@"rgba-u8" => 4,
            .@"rgba-f32" => 16,
            .bc7 => 16,
        },
        .bytes_plane_1 = 0,
        .bytes_plane_2 = 0,
        .bytes_plane_3 = 0,
        .bytes_plane_4 = 0,
        .bytes_plane_5 = 0,
        .bytes_plane_6 = 0,
        .bytes_plane_7 = 0,
    })[0 .. @bitSizeOf(Ktx2.BasicDescriptorBlock) / 8]) catch |err| {
        log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
        std.process.exit(1);
    };
    switch (encoding) {
        .@"rgba-u8" => |encoding_options| for (0..4) |i| {
            const ChannelType = Ktx2.BasicDescriptorBlock.Sample.ChannelType(.rgbsda);
            const channel_type: ChannelType = if (i == 3) .alpha else @enumFromInt(i);
            writer.writeAll(std.mem.asBytes(&Ktx2.BasicDescriptorBlock.Sample{
                .bit_offset = .fromInt(8 * @as(u16, @intCast(i))),
                .bit_length = .fromInt(8),
                .channel_type = @enumFromInt(@intFromEnum(channel_type)),
                .linear = switch (encoding_options.named.@"color-space") {
                    .linear => false,
                    .srgb => i == 3,
                },
                .exponent = false,
                .signed = false,
                .float = false,
                .sample_position_0 = 0,
                .sample_position_1 = 0,
                .sample_position_2 = 0,
                .sample_position_3 = 0,
                .lower = 0,
                .upper = switch (encoding_options.named.@"color-space") {
                    .linear => 1,
                    .srgb => 255,
                },
            })) catch unreachable;
        },
        .@"rgba-f32" => for (0..4) |i| {
            const ChannelType = Ktx2.BasicDescriptorBlock.Sample.ChannelType(.rgbsda);
            const channel_type: ChannelType = if (i == 3) .alpha else @enumFromInt(i);
            writer.writeAll(std.mem.asBytes(&Ktx2.BasicDescriptorBlock.Sample{
                .bit_offset = .fromInt(32 * @as(u16, @intCast(i))),
                .bit_length = .fromInt(32),
                .channel_type = @enumFromInt(@intFromEnum(channel_type)),
                .linear = false,
                .exponent = false,
                .signed = true,
                .float = true,
                .sample_position_0 = 0,
                .sample_position_1 = 0,
                .sample_position_2 = 0,
                .sample_position_3 = 0,
                .lower = @bitCast(@as(f32, -1.0)),
                .upper = @bitCast(@as(f32, 1.0)),
            })) catch unreachable;
        },
        .bc7 => {
            const ChannelType = Ktx2.BasicDescriptorBlock.Sample.ChannelType(.bc7);
            const channel_type: ChannelType = .data;
            writer.writeAll(std.mem.asBytes(&Ktx2.BasicDescriptorBlock.Sample{
                .bit_offset = .fromInt(0),
                .bit_length = .fromInt(128),
                .channel_type = @enumFromInt(@intFromEnum(channel_type)),
                .linear = false,
                .exponent = false,
                .signed = false,
                .float = false,
                .sample_position_0 = 0,
                .sample_position_1 = 0,
                .sample_position_2 = 0,
                .sample_position_3 = 0,
                .lower = 0,
                .upper = std.math.maxInt(u32),
            })) catch unreachable;
        },
    }

    // Write the compressed data. Note that KTX2 requires mips be stored form smallest to largest
    // for streaming purposes.
    {
        var byte_offset: usize = index.dfd_byte_offset + index.dfd_byte_length;
        for (0..compressed_levels.len) |i| {
            // Write padding
            const padded = std.mem.alignForward(usize, byte_offset, level_alignment);
            writer.writeByteNTimes(0, padded - byte_offset) catch |err| {
                log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
                std.process.exit(1);
            };
            byte_offset = padded;

            // Write the level
            const compressed_level = compressed_levels.get(compressed_levels.len - i - 1);
            writer.writeAll(compressed_level) catch |err| {
                log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
                std.process.exit(1);
            };
            byte_offset += compressed_level.len;
        }
    }
}

const Bc7Enc = opaque {
    const Params = extern struct {
        const max_partitions = 64;
        const max_uber_level = 4;
        const max_level = 18;
        const min_lookback_window_size = 8;

        const Bc345ModeMask = enum(u32) {
            const bc4_use_all_modes: @This() = .bc4_default_search_rad;

            bc4_default_search_rad = 3,
            bc4_use_mode8_flag = 1,
            bc4_use_mode6_flag = 2,

            _,
        };

        pub const Bc1ApproxMode = enum(c_uint) {
            ideal = 0,
            nvidia = 1,
            amd = 2,
            ideal_round_4 = 3,
            _,
        };

        pub const DxgiFormat = enum(c_uint) {
            bc7_unorm = 98,
        };

        bc7_uber_level: c_int = max_uber_level,
        max_partitions_to_scan: c_int = max_partitions,
        perceptual: bool = false,
        bc45_channel0: u32 = 0,
        bc45_channel1: u32 = 1,

        bc1_mode: Bc1ApproxMode = .ideal,
        use_bc1_3color_mode: bool = true,

        use_bc1_3color_mode_for_black: bool = true,

        bc1_quality_level: c_int = max_level,

        dxgi_format: DxgiFormat = .bc7_unorm,

        rdo_lambda: f32 = 0.0,
        rdo_debug_output: bool = false,
        rdo_smooth_block_error_scale: f32 = 15.0,
        custom_rdo_smooth_block_error_scale: bool = false,
        lookback_window_size: u32 = 128,
        custom_lookback_window_size: bool = false,
        rdo_bc7_quant_mode6_endpoints: bool = true,
        rdo_bc7_weight_modes: bool = true,
        rdo_bc7_weight_low_frequency_partitions: bool = true,
        rdo_bc7_pbit1_weighting: bool = true,
        rdo_max_smooth_block_std_dev: f32 = 18.0,
        rdo_allow_relative_movement: bool = false,
        rdo_try_2_matches: bool = true,
        rdo_ultrasmooth_block_handling: bool = true,

        use_hq_bc345: bool = true,
        bc345_search_rad: c_int = 5,
        bc345_mode_mask: Bc345ModeMask = Bc345ModeMask.bc4_use_all_modes,

        mode6_only: bool = false,
        rdo_multithreading: bool = true,

        reduce_entropy: bool = false,

        m_use_bc7e: bool = false,
        status_output: bool = false,

        rdo_max_threads: u32 = 128,
    };

    pub const init = bc7enc_init;
    pub const deinit = bc7enc_deinit;
    pub const encode = bc7enc_encode;
    pub fn getBlocks(self: *@This()) []u8 {
        const bytes = bc7enc_getTotalBlocksSizeInBytes(self);
        return bc7enc_getBlocks(self)[0..bytes];
    }

    extern fn bc7enc_init() callconv(.C) ?*@This();
    extern fn bc7enc_deinit(self: *@This()) callconv(.C) void;
    extern fn bc7enc_encode(
        self: *@This(),
        params: *const Params,
        width: u32,
        height: u32,
        pixels: [*]const f32,
    ) callconv(.C) bool;
    extern fn bc7enc_getBlocks(self: *@This()) callconv(.C) [*]u8;
    extern fn bc7enc_getTotalBlocksSizeInBytes(self: *@This()) callconv(.C) u32;
};
