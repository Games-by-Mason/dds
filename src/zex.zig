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
            .long = "alpha-input",
            .default = .{ .value = .straight },
        }),
        NamedArg.init(Alpha, .{
            .long = "alpha-output",
            .default = .{ .value = .premultiplied },
        }),
        NamedArg.init(?ZlibLevel, .{
            .long = "zlib",
            .default = .{ .value = null },
        }),
        NamedArg.init(bool, .{
            .long = "generate-mipmaps",
            .default = .{ .value = false },
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
        r8g8b8a8_command,
        r32g32b32a32_command,
        bc7_command,
    },
};

const r8g8b8a8_command: Command = .{
    .name = "r8g8b8a8",
    .named_args = &.{
        NamedArg.init(ColorSpace, .{
            .long = "color-space",
            .default = .{ .value = .srgb },
        }),
    },
};

const r32g32b32a32_command: Command = .{
    .name = "r32g32b32a32",
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
    .description = "Use RDO to make the output more compressible.",
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

    var raw_levels: std.BoundedArray(Image, Ktx2.max_levels) = .{};
    defer for (raw_levels.constSlice()[1..]) |level| {
        level.deinit();
    };
    const premultiply = args.named.@"alpha-input" == .straight and
        args.named.@"alpha-output" == .premultiplied;
    raw_levels.appendAssumeCapacity(Image.init(.{
        .bytes = input_bytes,
        .channels = .@"4",
        .premultiply = premultiply,
        .ty = switch (encoding) {
            inline .bc7, .r8g8b8a8 => |ec| switch (ec.named.@"color-space") {
                .srgb => .u8_srgb,
                .linear => .u8,
            },
            .r32g32b32a32 => .f32,
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
    });

    // Generate mipmaps for the other levels if requested
    {
        const block_size: u8 = switch (encoding) {
            .r8g8b8a8, .r32g32b32a32 => 1,
            // We're allowed to go smaller than the block size, but there's no benefit to doing
            // so
            .bc7 => 4,
        };
        var image = raw_levels.get(0);
        while (image.width > block_size or image.height > block_size) {
            image = image.resize(.{
                .width = @max(1, image.width / 2),
                .height = @max(1, image.height / 2),
                .address_mode = .clamp,
                .filter = .box,
            }) orelse {
                log.err("{s}: mipmap generation failed", .{args.positional.INPUT});
                std.process.exit(1);
            };
            raw_levels.appendAssumeCapacity(image);
        }
    }

    // Encode the pixel data
    var bc7_encoders: std.BoundedArray(*Bc7Enc, Ktx2.max_levels) = .{};
    defer for (bc7_encoders.constSlice()) |bc7_encoder| {
        bc7_encoder.deinit();
    };
    var encoded_levels: std.BoundedArray([]u8, Ktx2.max_levels) = .{};
    switch (encoding) {
        .r8g8b8a8, .r32g32b32a32 => for (raw_levels.constSlice()) |raw_level| {
            encoded_levels.appendAssumeCapacity(raw_level.data);
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
                // Ignored when using RDO (fine to set regardless, is cleared upstream)
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

                if (!bc7_encoder.encode(&params, raw_level.width, raw_level.height, raw_level.data.ptr)) {
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
        .r8g8b8a8, .r32g32b32a32 => 4,
        .bc7 => 1,
    };
    const index = Ktx2.Header.Index.init(.{
        .levels = @intCast(compressed_levels.len),
        .samples = samples,
    });
    writer.writeStruct(Ktx2.Header{
        .format = switch (encoding) {
            .r8g8b8a8 => |encoding_options| switch (encoding_options.named.@"color-space") {
                .linear => .r8g8b8a8_uint,
                .srgb => .r8g8b8a8_srgb,
            },
            .r32g32b32a32 => .r32g32b32a32_sfloat,
            .bc7 => |encoding_options| switch (encoding_options.named.@"color-space") {
                .linear => .bc7_unorm_block,
                .srgb => .bc7_srgb_block,
            },
        },
        .type_size = switch (encoding) {
            .r8g8b8a8, .bc7 => 1,
            .r32g32b32a32 => 4,
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
        .r8g8b8a8 => 4,
        .r32g32b32a32 => 16,
        .bc7 => 16,
    };
    {
        // Calculate the byte offsets, taking into account that KTX2 requires mipmaps be stored from
        // largest to smallest for streaming purposes
        var byte_offsets_reverse: std.BoundedArray(u64, Ktx2.max_levels) = .{};
        {
            var byte_offset: u64 = index.dfd_byte_offset + index.dfd_byte_length;
            for (0..compressed_levels.len) |i| {
                byte_offset = std.mem.alignForward(u64, byte_offset, level_alignment);
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
            .r8g8b8a8, .r32g32b32a32 => .rgbsda,
            .bc7 => .bc7,
        },
        .primaries = .bt709,
        .transfer = switch (encoding) {
            .r32g32b32a32 => .linear,
            inline else => |encoding_options| switch (encoding_options.named.@"color-space") {
                .linear => .linear,
                .srgb => .srgb,
            },
        },
        .flags = .{
            .alpha_premultiplied = args.named.@"alpha-output" == .premultiplied,
        },
        .texel_block_dimension_0 = switch (encoding) {
            .r8g8b8a8, .r32g32b32a32 => .fromInt(1),
            .bc7 => .fromInt(4),
        },
        .texel_block_dimension_1 = switch (encoding) {
            .r8g8b8a8, .r32g32b32a32 => .fromInt(1),
            .bc7 => .fromInt(4),
        },
        .texel_block_dimension_2 = .fromInt(1),
        .texel_block_dimension_3 = .fromInt(1),
        .bytes_plane_0 = if (args.named.zlib != null) 0 else switch (encoding) {
            .r8g8b8a8 => 4,
            .r32g32b32a32 => 16,
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
        .r8g8b8a8 => |encoding_options| for (0..4) |i| {
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
        .r32g32b32a32 => for (0..4) |i| {
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
        var byte_offset: u64 = index.dfd_byte_offset + index.dfd_byte_length;
        for (0..compressed_levels.len) |i| {
            // Write padding
            const padded = std.mem.alignForward(u64, byte_offset, level_alignment);
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
        pixels: [*]const u8,
    ) callconv(.C) bool;
    extern fn bc7enc_getBlocks(self: *@This()) callconv(.C) [*]u8;
    extern fn bc7enc_getTotalBlocksSizeInBytes(self: *@This()) callconv(.C) u32;
};

pub const Image = struct {
    width: u32,
    height: u32,
    ty: DataType,
    channels: Channels,
    data: []u8,

    pub const Channels = enum(u3) {
        @"1" = 1,
        @"2" = 2,
        @"3" = 3,
        @"4" = 4,
    };

    pub const DataType = StbirDataType;

    pub const Error = error{
        StbImageFailure,
        LdrAsHdr,
    };

    pub const InitOptions = struct {
        bytes: []const u8,
        ty: DataType,
        channels: Channels,
        premultiply: bool,
    };
    pub fn init(options: InitOptions) Error!@This() {
        switch (options.ty) {
            .u8, .u8_srgb, .u8_srgb_alpha => {
                var width: c_int = 0;
                var height: c_int = 0;
                var input_channels: c_int = 0;
                const data = stbi_load_from_memory(
                    options.bytes.ptr,
                    @intCast(options.bytes.len),
                    &width,
                    &height,
                    &input_channels,
                    @intFromEnum(options.channels),
                ) orelse return error.StbImageFailure;

                const len = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * @intFromEnum(options.channels);
                const image: @This() = .{
                    .width = @intCast(width),
                    .height = @intCast(height),
                    .channels = options.channels,
                    .ty = options.ty,
                    .data = data[0..len],
                };

                if (options.premultiply) {
                    var px: usize = 0;
                    while (px < image.width * image.height * 4) : (px += 4) {
                        const a: f32 = @as(f32, @floatFromInt(image.data[px + 3])) / 255.0;
                        image.data[px + 0] = @intFromFloat(@as(f32, @floatFromInt(image.data[px + 0])) * a);
                        image.data[px + 1] = @intFromFloat(@as(f32, @floatFromInt(image.data[px + 1])) * a);
                        image.data[px + 2] = @intFromFloat(@as(f32, @floatFromInt(image.data[px + 2])) * a);
                    }
                }

                return image;
            },
            .f32 => {
                if (stbi_is_hdr_from_memory(options.bytes.ptr, @intCast(options.bytes.len)) == 0) {
                    return error.LdrAsHdr;
                }

                var width: c_int = 0;
                var height: c_int = 0;
                var input_channels: c_int = 0;
                const data_ptr = stbi_loadf_from_memory(
                    options.bytes.ptr,
                    @intCast(options.bytes.len),
                    &width,
                    &height,
                    &input_channels,
                    @intFromEnum(options.channels),
                ) orelse return error.StbImageFailure;

                const len = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * @intFromEnum(options.channels);
                const data = data_ptr[0..len];
                const image: @This() = .{
                    .width = @intCast(width),
                    .height = @intCast(height),
                    .channels = options.channels,
                    .ty = options.ty,
                    .data = std.mem.sliceAsBytes(data),
                };

                if (options.premultiply) {
                    var px: usize = 0;
                    while (px < image.width * image.height * 4) : (px += 4) {
                        const a = data[px + 3];
                        data[px + 0] = data[px + 0] * a;
                        data[px + 1] = data[px + 1] * a;
                        data[px + 2] = data[px + 2] * a;
                    }
                }

                return image;
            },
            else => std.debug.panic("unsupported data type {}", .{options.ty}),
        }
    }

    pub fn deinit(self: @This()) void {
        stbi_image_free(self.data.ptr);
    }

    pub const ResizeOptions = struct {
        width: u32,
        height: u32,
        address_mode: AddressMode,
        filter: Filter,
    };

    pub fn resize(self: @This(), options: ResizeOptions) ?Image {
        const pixel_bytes = self.ty.bytesPerChannel() * @intFromEnum(self.channels);
        const data = stbir_resize(
            self.data.ptr,
            @intCast(self.width),
            @intCast(self.height),
            @intCast(self.width * pixel_bytes),
            null,
            @intCast(options.width),
            @intCast(options.height),
            @intCast(options.width * pixel_bytes),
            .fromChannels(self.channels),
            self.ty,
            options.address_mode,
            options.filter,
        ) orelse return null;
        return .{
            .width = options.width,
            .height = options.height,
            .channels = self.channels,
            .ty = self.ty,
            .data = data[0..(options.width * options.height * pixel_bytes)],
        };
    }

    // STB Image
    extern fn stbi_load_from_memory(
        buffer: [*]const u8,
        len: c_int,
        x: *c_int,
        y: *c_int,
        channels_in_file: *c_int,
        desired_channels: c_int,
    ) callconv(.C) ?[*]u8;
    extern fn stbi_image_free(image: [*]u8) callconv(.C) void;

    extern fn stbi_loadf_from_memory(
        buffer: [*]const u8,
        len: c_int,
        x: *c_int,
        y: *c_int,
        channels_in_file: *c_int,
        desired_channels: c_int,
    ) callconv(.C) ?[*]f32;

    extern fn stbi_is_hdr_from_memory(buffer: [*]const u8, len: c_int) callconv(.C) c_int;

    // STB Resize 2
    pub const AddressMode = enum(c_uint) {
        clamp = 0,
        reflect = 1,
        wrap = 2,
        zero = 3,
    };

    pub const Filter = enum(c_uint) {
        default = 0,
        box = 1,
        triangle = 2,
        cubic_b_spline = 3,
        catmull_rom = 4,
        mitchell = 5,
        point_sample = 6,
        other = 7,
    };

    const StbirDataType = enum(c_uint) {
        u8 = 0,
        u8_srgb = 1,
        // "alpha channel, when present, should also be SRGB (this is very unusual)"
        u8_srgb_alpha = 2,
        u16 = 3,
        f32 = 4,
        f16 = 5,

        pub fn bytesPerChannel(self: @This()) u8 {
            return switch (self) {
                .u8, .u8_srgb, .u8_srgb_alpha => 1,
                .u16 => 2,
                .f32 => 4,
                .f16 => 2,
            };
        }
    };

    const StbirPixelLayout = enum(c_uint) {
        @"1_channel" = 1,
        @"2_channel" = 2,
        rgb = 3,
        bgr = 0,
        @"4_channel" = 5,
        rgba = 4,
        bgra = 6,
        argb = 7,
        abgr = 8,
        ra = 9,
        ar = 10,
        rgba_pm = 11,
        bgra_pm = 12,
        argb_pm = 13,
        abgr_pm = 14,
        ra_pm = 15,
        ar_pm = 16,

        fn fromChannels(channels: Channels) @This() {
            return switch (channels) {
                .@"1" => .@"1_channel",
                .@"2" => .@"2_channel",
                .@"3" => .rgb,
                .@"4" => .rgba_pm, // We always premultiply alpha channels ourselves
            };
        }
    };

    extern fn stbir_resize(
        input_pixels: *const anyopaque,
        input_w: c_int,
        input_h: c_int,
        input_stride_in_bytes: c_int,
        output_pixels: ?*anyopaque,
        output_w: c_int,
        output_h: c_int,
        output_stride_in_bytes: c_int,
        pixel_layout: StbirPixelLayout,
        data_type: DataType,
        address_mode: AddressMode,
        filter: Filter,
    ) callconv(.C) ?[*]u8;
};
