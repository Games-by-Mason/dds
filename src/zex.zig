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

pub const Filter = enum(c_uint) {
    box = @intFromEnum(Image.ResizeOptions.Filter.box),
    triangle = @intFromEnum(Image.ResizeOptions.Filter.triangle),
    @"cubic-b-spline" = @intFromEnum(Image.ResizeOptions.Filter.cubic_b_spline),
    @"catmull-rom" = @intFromEnum(Image.ResizeOptions.Filter.catmull_rom),
    mitchell = @intFromEnum(Image.ResizeOptions.Filter.mitchell),
    @"point-sample" = @intFromEnum(Image.ResizeOptions.Filter.point_sample),

    pub fn filter(self: @This()) Image.ResizeOptions.Filter {
        return @enumFromInt(@intFromEnum(self));
    }
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
            .long = "input-alpha",
            .default = .{ .value = .straight },
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
        NamedArg.init(u8, .{
            .description = "the max number of search steps used by --preserve-alpha-coverage",
            .long = "preserve-alpha-coverage-max-steps",
            .default = .{ .value = 10 },
        }),
        NamedArg.init(?Filter, .{
            .description = "defaults to the mitchell filter for LDR images, box for HDR images",
            .long = "filter",
            .default = .{ .value = null },
        }),
        NamedArg.init(?Filter, .{
            .description = "overrides --filter in the U direction",
            .long = "filter-u",
            .default = .{ .value = null },
        }),
        NamedArg.init(?Filter, .{
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
        NamedArg.init(?u16, .{
            .long = "max-threads",
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
            .long = "quantize-mode-6-endpoints",
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

    const cwd = std.fs.cwd();

    // Load the first level
    var input = cwd.openFile(args.positional.INPUT, .{}) catch |err| {
        log.err("{s}: {s}", .{ args.positional.INPUT, @errorName(err) });
        std.process.exit(1);
    };
    defer input.close();

    var output_file = cwd.createFile(args.positional.OUTPUT, .{}) catch |err| {
        log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
        std.process.exit(1);
    };
    defer {
        output_file.sync() catch |err| @panic(@errorName(err));
        output_file.close();
    }

    const input_bytes = input.readToEndAllocOptions(allocator, max_file_len, null, 1, 0) catch |err| {
        log.err("{s}: {s}", .{ args.positional.INPUT, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(input_bytes);

    try TextureWriter(std.fs.File.Writer).write(allocator, args, .{
        .input = .{
            .buffer = input_bytes,
            .alpha = switch (args.named.@"input-alpha") {
                .premultiplied => .premultiplied,
                .straight => .straight,
            },
        },
        .output = output_file.writer(),
        .encoding = switch (encoding) {
            .bc7 => |eo| .{ .bc7 = .{
                .color_space = switch (eo.named.@"color-space") {
                    .srgb => .srgb,
                    .linear => .linear,
                },
                .uber_level = eo.named.uber,
                .reduce_entropy = eo.named.@"reduce-entropy",
                .max_partitions_to_scan = eo.named.@"max-partitions-to-scan",
                .mode_6_only = eo.named.@"mode-6-only",
                .rdo = if (eo.subcommand) |subcommand| switch (subcommand) {
                    .rdo => |rdo| .{
                        .lambda = rdo.named.lambda,
                        .lookback_window = rdo.named.@"lookback-window",
                        .smooth_block_error_scale = rdo.named.@"smooth-block-error-scale",
                        .quantize_mode_6_endpoints = rdo.named.@"quantize-mode-6-endpoints",
                        .weight_modes = rdo.named.@"weight-modes",
                        .weight_low_frequency_partitions = rdo.named.@"weight-low-frequency-partitions",
                        .pbit1_weighting = rdo.named.@"pbit1-weighting",
                        .max_smooth_block_std_dev = rdo.named.@"max-smooth-block-std-dev",
                        .try_two_matches = rdo.named.@"try-two-matches",
                        .ultrasmooth_block_handling = rdo.named.@"ultrasmooth-block-handling",
                    },
                } else null,
            } },
            .@"rgba-u8" => |eo| .{ .rgba_u8 = .{
                .color_space = switch (eo.named.@"color-space") {
                    .linear => .linear,
                    .srgb => .srgb,
                },
            } },
            .@"rgba-f32" => .rgba_f32,
        },
        // XXX: some settings like this should be sorta global not per texture, that's fine could
        // pass these in via build system! then can e.g. use threads when doing indvidiaul assets if
        // we want. is bc7 stuff deterministic?
        .max_threads = args.named.@"max-threads",
        .generate_mipmaps = args.named.@"generate-mipmaps",
        .alpha_test = if (args.named.@"preserve-alpha-coverage") |t| .{
            .threshold = t,
        } else null,
        .max_size = args.named.@"max-size" orelse std.math.maxInt(u32),
        .max_width = args.named.@"max-width" orelse std.math.maxInt(u32),
        .max_height = args.named.@"max-height" orelse std.math.maxInt(u32),
    });
}

// XXX: return error.InvalidParam instead of details, but log them.
// XXX: naming
pub fn TextureWriter(Writer: type) type {
    return struct {
        pub const WriteError = Writer.Error || error{
            StbImageFailure,
            LdrAsHdr,
            InvalidOption,
            StbResizeFailure,
            OutOfMemory,
            Bc7EncFailed,
            // XXX: ?
            UnfinishedBits,
        };
        pub const WriteOptions = struct {
            input: struct {
                // XXX: we can always assume it isn't, really we just want a bool for whether or not the
                // channel represents transparency
                alpha: enum { premultiplied, straight },
                // XXX: or take a reader?
                buffer: []const u8,
            },
            // XXX: this forces error to be anyerror...maybe we wanna make this generic, maybe make a texture
            // writer object or something. that can take the non texture specific options?
            output: Writer,
            encoding: Encoding,
            // XXX: use elsewhere too?
            max_threads: ?u16 = null,
            // XXX: add everything so we can remove args param
            generate_mipmaps: bool = false,
            alpha_test: ?struct {
                threshold: f32 = 0.5,
            } = null,
            max_size: u32 = std.math.maxInt(u32),
            max_width: u32 = std.math.maxInt(u32),
            max_height: u32 = std.math.maxInt(u32),

            pub const Encoding = union(enum) {
                rgba_u8: struct {
                    color_space: enum { srgb, linear },
                },
                rgba_f32: void,
                bc7: struct {
                    color_space: enum { srgb, linear },
                    uber_level: u8 = Bc7Enc.Params.max_uber_level,
                    reduce_entropy: bool = false,
                    max_partitions_to_scan: u16 = Bc7Enc.Params.max_partitions,
                    mode_6_only: bool = false,
                    rdo: ?struct {
                        lambda: f32 = 0.5,
                        lookback_window: ?u17 = null,
                        smooth_block_error_scale: ?f32 = 15.0,
                        quantize_mode_6_endpoints: bool = true,
                        weight_modes: bool = true,
                        weight_low_frequency_partitions: bool = true,
                        pbit1_weighting: bool = true,
                        max_smooth_block_std_dev: f32 = 18.0,
                        try_two_matches: bool = true,
                        ultrasmooth_block_handling: bool = true,
                    },
                },
            };
        };

        pub fn write(
            gpa: std.mem.Allocator,
            // XXX: incrementally pull out args into options
            // XXX: then make sure that everything done in here COULD be done manually as well
            // as a lower level api, esp encoding, and also, writing the ktx file
            // XXX: I think we can make encode functions on the image, and writing the ktx file
            // COULD be part of ktx2 or could be here
            // XXX: return errors instead of exiting from here
            args: Command.Result(command),
            options: WriteOptions,
            // XXX: make specific error type
        ) WriteError!void {
            const original = try Image.init(.{
                .bytes = options.input.buffer,
                .color_space = switch (options.encoding) {
                    inline .bc7, .rgba_u8 => |ec| switch (ec.color_space) {
                        .srgb => .srgb,
                        .linear => .linear,
                    },
                    .rgba_f32 => .hdr,
                },
            });
            defer original.deinit();

            if (options.input.alpha == .straight) {
                original.premultiply();
            }

            const maybe_address_mode_u = args.named.@"address-mode-u" orelse args.named.@"address-mode";
            const maybe_address_mode_v = args.named.@"address-mode-v" orelse args.named.@"address-mode";
            const default_filter: Filter = if (original.hdr) .box else .mitchell;
            const filter_u = args.named.@"filter-u" orelse args.named.filter orelse default_filter;
            const filter_v = args.named.@"filter-v" orelse args.named.filter orelse default_filter;

            // Not supported by current STB, has no effect if set
            if ((filter_u == .box and maybe_address_mode_u != null and maybe_address_mode_u != .clamp) or
                (filter_v == .box and maybe_address_mode_v != null and maybe_address_mode_v != .clamp))
            {
                // XXX: could we specify the clamp mode per filter?
                log.err("Box filtering is only compatible with the clamp address mode.", .{});
                return error.InvalidOption;
            }

            // Sharpening filters can cause extreme artifacts on HDR images. See #15 for more
            // information.
            if (original.hdr and (filter_u.filter().sharpens() or filter_v.filter().sharpens())) {
                // XXX: could we specify the filter type per input encoding?
                log.err("Sharpen filters are not compatible with HDR inputs.", .{});
                return error.InvalidOption;
            }

            // Copy the original image into the mip levels, scaling it if needed but preserving
            // aspect ratio.
            //
            // We could elide this copy if the size doesn't change, but for now we don't because
            // it's a simple way to keep the unmodified image around for possible alpha coverage
            // calculations.
            var raw_levels: std.BoundedArray(Image, Ktx2.max_levels) = .{};
            defer for (raw_levels.constSlice()[1..]) |level| {
                level.deinit();
            };
            {
                const max_width = @min(options.max_width, options.max_size);
                const max_height = @min(options.max_height, options.max_size);
                const x_scale = @min(@as(f64, @floatFromInt(max_width)) / @as(f64, @floatFromInt(original.width)), 1.0);
                const y_scale = @min(@as(f64, @floatFromInt(max_height)) / @as(f64, @floatFromInt(original.height)), 1.0);
                const scale = @min(x_scale, y_scale);
                const width = @min(@as(u32, @intFromFloat(scale * @as(f64, @floatFromInt(original.width)))), max_width);
                const height = @min(@as(u32, @intFromFloat(scale * @as(f64, @floatFromInt(original.height)))), max_height);
                // XXX: just have a default filter, and the ability to override it and the u and v
                // ones. uhhh and make the address mode part of the filter I guess.
                const address_mode_u = maybe_address_mode_u orelse {
                    log.err("Resize requires an address mode.", .{});
                    return error.InvalidOption;
                };
                const address_mode_v = maybe_address_mode_v orelse {
                    log.err("Resize requires an address mode.", .{});
                    return error.InvalidOption;
                };
                raw_levels.appendAssumeCapacity(try original.resize(.{
                    .width = width,
                    .height = height,
                    .address_mode_u = address_mode_u,
                    .address_mode_v = address_mode_v,
                    .filter_u = filter_u.filter(),
                    .filter_v = filter_v.filter(),
                }));
            }

            // Generate mipmaps for the other levels if requested
            if (options.generate_mipmaps) {
                const address_mode_u = maybe_address_mode_u orelse {
                    log.err("Resize requires an address mode.", .{});
                    return error.InvalidOption;
                };
                const address_mode_v = maybe_address_mode_v orelse {
                    log.err("Resize requires an address mode.", .{});
                    return error.InvalidOption;
                };

                const block_size: u8 = switch (options.encoding) {
                    .rgba_u8, .rgba_f32 => 1,
                    .bc7 => 4,
                };

                var generate_mipmaps = raw_levels.get(0).generateMipmaps(.{
                    .address_mode_u = address_mode_u,
                    .address_mode_v = address_mode_v,
                    .filter_u = filter_u.filter(),
                    .filter_v = filter_v.filter(),
                    .block_size = block_size,
                });

                while (try generate_mipmaps.next()) |mipmap| {
                    raw_levels.appendAssumeCapacity(mipmap);
                }
            }

            // Cutout the textures if requested
            if (options.alpha_test) |alpha_test| {
                // Quantize the threshold to the output type
                const threshold = switch (options.encoding) {
                    .rgba_u8, .bc7 => @round(alpha_test.threshold * 255.0) / 255.0,
                    .rgba_f32 => alpha_test.threshold,
                };

                // Determine the target coverage
                const target_coverage = original.alphaCoverage(threshold, 1.0);

                // Process each mip level. Technically we could skip the first level if no resizing was
                // applied, for simplicity we don't do this right now.
                for (raw_levels.constSlice()) |level| {
                    // Binary search for the best scale parameter
                    var best_scale: f32 = 1.0;
                    var best_dist = std.math.inf(f32);
                    var upper_threshold: f32 = 1.0;
                    var lower_threshold: f32 = 0.0;
                    var curr_threshold: f32 = threshold;
                    for (0..args.named.@"preserve-alpha-coverage-max-steps") |_| {
                        const curr_scale = threshold / curr_threshold;
                        const coverage = level.alphaCoverage(threshold, curr_scale);
                        const dist_to_coverage = @abs(coverage - target_coverage);
                        if (dist_to_coverage < best_dist) {
                            best_dist = dist_to_coverage;
                            best_scale = curr_scale;
                        }

                        if (coverage < target_coverage) {
                            upper_threshold = curr_threshold;
                        } else if (coverage > target_coverage) {
                            lower_threshold = curr_threshold;
                        } else {
                            break;
                        }

                        curr_threshold = (lower_threshold + upper_threshold) / 2.0;
                    }

                    // Apply the scaling
                    if (best_scale != 1.0) {
                        for (0..@as(usize, level.width) * @as(usize, level.height)) |i| {
                            const a = &level.data[i * 4 + 3];
                            a.* = @min(a.* * best_scale, 1.0);
                        }
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
                gpa.free(u8_encoding);
            };
            var encoded_levels: std.BoundedArray([]u8, Ktx2.max_levels) = .{};
            switch (options.encoding) {
                .rgba_u8 => |eo| for (raw_levels.constSlice()) |raw_level| {
                    const encoded_level = try gpa.alloc(u8, raw_level.data.len);
                    for (0..@as(usize, raw_level.width) * @as(usize, raw_level.height) * 4) |i| {
                        var ldr = raw_level.data[i];
                        if (eo.color_space == .srgb and i % 4 != 3) {
                            ldr = std.math.pow(f32, ldr, 1.0 / 2.2);
                        }
                        ldr = std.math.clamp(ldr * 255.0 + 0.5, 0.0, 255.0);
                        encoded_level[i] = @intFromFloat(ldr);
                    }
                    u8_encodings.appendAssumeCapacity(encoded_level);
                    encoded_levels.appendAssumeCapacity(encoded_level);
                },
                .rgba_f32 => for (raw_levels.constSlice()) |raw_level| {
                    encoded_levels.appendAssumeCapacity(std.mem.sliceAsBytes(raw_level.data));
                },
                .bc7 => |eo| {
                    // Determine the bc7 params
                    var params: Bc7Enc.Params = .{};
                    {
                        if (eo.uber_level > Bc7Enc.Params.max_uber_level) {
                            log.err("Invalid uber level.", .{});
                            return error.InvalidOption;
                        }
                        params.bc7_uber_level = eo.uber_level;

                        params.reduce_entropy = eo.reduce_entropy;

                        if (eo.max_partitions_to_scan > Bc7Enc.Params.max_partitions) {
                            log.err("Invalid max partitions to scan.", .{});
                            return error.InvalidOption;
                        }
                        params.max_partitions_to_scan = eo.max_partitions_to_scan;
                        // Ignored when using RDO. However, we use it in our bindings. The actual encoder
                        // just clears it so it doesn't matter that we set it regardless.
                        params.perceptual = eo.color_space == .srgb;
                        params.mode6_only = eo.mode_6_only;

                        if (options.max_threads) |v| {
                            // XXX: check at top. why is 0 an error?
                            if (v == 0) {
                                log.err("Invalid max threads.", .{});
                                return error.InvalidOption;
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

                        if (eo.rdo) |rdo| {
                            if ((rdo.lambda < 0.0) or (rdo.lambda > 500.0)) {
                                log.err("Invalid RDO lambda.", .{});
                                return error.InvalidOption;
                            }
                            params.rdo_lambda = rdo.lambda;

                            if (rdo.lookback_window) |lookback_window| {
                                if (lookback_window < Bc7Enc.Params.min_lookback_window_size) {
                                    log.err("Invalid lookback window.", .{});
                                    return error.InvalidOption;
                                }
                                params.lookback_window_size = lookback_window;
                                params.custom_lookback_window_size = true;
                            }

                            if (rdo.smooth_block_error_scale) |v| {
                                if ((v < 1.0) or (v > 500.0)) {
                                    log.err("Invalid smooth block error scale.", .{});
                                    return error.InvalidOption;
                                }
                                params.rdo_smooth_block_error_scale = v;
                                params.custom_rdo_smooth_block_error_scale = true;
                            }

                            params.rdo_bc7_quant_mode6_endpoints = rdo.quantize_mode_6_endpoints;
                            params.rdo_bc7_weight_modes = rdo.weight_modes;
                            params.rdo_bc7_weight_low_frequency_partitions = rdo.weight_low_frequency_partitions;
                            params.rdo_bc7_pbit1_weighting = rdo.pbit1_weighting;

                            if ((rdo.max_smooth_block_std_dev) < 0.000125 or (rdo.max_smooth_block_std_dev > 256.0)) {
                                log.err("Invalid smooth block standard deviation.", .{});
                                return error.InvalidOption;
                            }
                            params.rdo_max_smooth_block_std_dev = rdo.max_smooth_block_std_dev;
                            params.rdo_try_2_matches = rdo.try_two_matches;
                            params.rdo_ultrasmooth_block_handling = rdo.ultrasmooth_block_handling;
                        }
                    }

                    // Encode the levels
                    for (raw_levels.constSlice()) |raw_level| {
                        bc7_encoders.appendAssumeCapacity(Bc7Enc.init() orelse {
                            return error.Bc7EncFailed;
                        });

                        const bc7_encoder = bc7_encoders.get(bc7_encoders.len - 1);

                        if (!bc7_encoder.encode(
                            &params,
                            raw_level.width,
                            raw_level.height,
                            raw_level.data.ptr,
                        )) {
                            return error.Bc7EncFailed;
                        }

                        encoded_levels.appendAssumeCapacity(bc7_encoder.getBlocks());
                    }
                },
            }

            // Compress the data if needed
            var compressed_levels: std.BoundedArray([]u8, Ktx2.max_levels) = .{};
            if (args.named.zlib) |zlib_level| {
                for (encoded_levels.constSlice()) |level| {
                    var compressed = try ArrayListUnmanaged(u8).initCapacity(
                        gpa,
                        encoded_levels.constSlice()[0].len,
                    );
                    defer compressed.deinit(gpa);

                    const Compressor = std.compress.flate.deflate.Compressor(
                        .zlib,
                        @TypeOf(compressed).Writer,
                    );
                    var compressor = try Compressor.init(
                        compressed.writer(gpa),
                        .{ .level = zlib_level.toStdLevel() },
                    );
                    _ = try compressor.write(level);
                    try compressor.finish();
                    compressed_levels.appendAssumeCapacity(try compressed.toOwnedSlice(gpa));
                }
            } else {
                for (encoded_levels.constSlice()) |encoded_level| {
                    compressed_levels.appendAssumeCapacity(encoded_level);
                }
            }
            defer if (args.named.zlib != null) for (compressed_levels.constSlice()) |compressed_level| {
                gpa.free(compressed_level);
            };

            // Write the header
            const samples: u8 = switch (options.encoding) {
                .rgba_u8, .rgba_f32 => 4,
                .bc7 => 1,
            };
            const index = Ktx2.Header.Index.init(.{
                .levels = @intCast(compressed_levels.len),
                .samples = samples,
            });
            try options.output.writeStruct(Ktx2.Header{
                .format = switch (options.encoding) {
                    .rgba_u8 => |eo| switch (eo.color_space) {
                        .linear => .r8g8b8a8_uint,
                        .srgb => .r8g8b8a8_srgb,
                    },
                    .rgba_f32 => .r32g32b32a32_sfloat,
                    .bc7 => |eo| switch (eo.color_space) {
                        .linear => .bc7_unorm_block,
                        .srgb => .bc7_srgb_block,
                    },
                },
                .type_size = switch (options.encoding) {
                    .rgba_u8, .bc7 => 1,
                    .rgba_f32 => 4,
                },
                .pixel_width = raw_levels.get(0).width,
                .pixel_height = raw_levels.get(0).height,
                .pixel_depth = 0,
                .layer_count = 0,
                .face_count = 1,
                .level_count = .fromInt(@intCast(compressed_levels.len)),
                .supercompression_scheme = if (args.named.zlib != null) .zlib else .none,
                .index = index,
            });

            const level_alignment: u8 = if (args.named.zlib != null) 1 else switch (options.encoding) {
                .rgba_u8 => 4,
                .rgba_f32 => 16,
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
                    try options.output.writeStruct(Ktx2.Level{
                        .byte_offset = byte_offsets_reverse.get(compressed_levels.len - i - 1),
                        .byte_length = compressed_levels.get(i).len,
                        .uncompressed_byte_length = encoded_levels.get(i).len,
                    });
                }
            }

            // Write the data descriptor
            try options.output.writeInt(u32, index.dfd_byte_length, .little);
            try options.output.writeAll(std.mem.asBytes(&Ktx2.BasicDescriptorBlock{
                .descriptor_block_size = Ktx2.BasicDescriptorBlock.descriptorBlockSize(samples),
                .model = switch (options.encoding) {
                    .rgba_u8, .rgba_f32 => .rgbsda,
                    .bc7 => .bc7,
                },
                .primaries = .bt709,
                .transfer = switch (options.encoding) {
                    .rgba_f32 => .linear,
                    inline else => |eo| switch (eo.color_space) {
                        .linear => .linear,
                        .srgb => .srgb,
                    },
                },
                .flags = .{
                    // XXX: are we supposed to set this even if it doesn't represent transparency or no?
                    .alpha_premultiplied = true,
                },
                .texel_block_dimension_0 = switch (options.encoding) {
                    .rgba_u8, .rgba_f32 => .fromInt(1),
                    .bc7 => .fromInt(4),
                },
                .texel_block_dimension_1 = switch (options.encoding) {
                    .rgba_u8, .rgba_f32 => .fromInt(1),
                    .bc7 => .fromInt(4),
                },
                .texel_block_dimension_2 = .fromInt(1),
                .texel_block_dimension_3 = .fromInt(1),
                .bytes_plane_0 = if (args.named.zlib != null) 0 else switch (options.encoding) {
                    .rgba_u8 => 4,
                    .rgba_f32 => 16,
                    .bc7 => 16,
                },
                .bytes_plane_1 = 0,
                .bytes_plane_2 = 0,
                .bytes_plane_3 = 0,
                .bytes_plane_4 = 0,
                .bytes_plane_5 = 0,
                .bytes_plane_6 = 0,
                .bytes_plane_7 = 0,
            })[0 .. @bitSizeOf(Ktx2.BasicDescriptorBlock) / 8]);
            switch (options.encoding) {
                .rgba_u8 => |eo| for (0..4) |i| {
                    const ChannelType = Ktx2.BasicDescriptorBlock.Sample.ChannelType(.rgbsda);
                    const channel_type: ChannelType = if (i == 3) .alpha else @enumFromInt(i);
                    options.output.writeAll(std.mem.asBytes(&Ktx2.BasicDescriptorBlock.Sample{
                        .bit_offset = .fromInt(8 * @as(u16, @intCast(i))),
                        .bit_length = .fromInt(8),
                        .channel_type = @enumFromInt(@intFromEnum(channel_type)),
                        .linear = switch (eo.color_space) {
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
                        .upper = switch (eo.color_space) {
                            .linear => 1,
                            .srgb => 255,
                        },
                    })) catch unreachable;
                },
                .rgba_f32 => for (0..4) |i| {
                    const ChannelType = Ktx2.BasicDescriptorBlock.Sample.ChannelType(.rgbsda);
                    const channel_type: ChannelType = if (i == 3) .alpha else @enumFromInt(i);
                    options.output.writeAll(std.mem.asBytes(&Ktx2.BasicDescriptorBlock.Sample{
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
                    options.output.writeAll(std.mem.asBytes(&Ktx2.BasicDescriptorBlock.Sample{
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
                    try options.output.writeByteNTimes(0, padded - byte_offset);
                    byte_offset = padded;

                    // Write the level
                    const compressed_level = compressed_levels.get(compressed_levels.len - i - 1);
                    try options.output.writeAll(compressed_level);
                    byte_offset += compressed_level.len;
                }
            }
        }
    };
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
