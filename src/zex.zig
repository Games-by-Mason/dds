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

    // Load the PNG
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

    const image = Image.init(.{
        .bytes = input_bytes,
        .desired_channels = 4,
        .multiply_by_alpha = args.named.@"alpha-input" == .straight and
            args.named.@"alpha-output" == .premultiplied,
        .dynamic_range = switch (encoding) {
            .bc7, .r8g8b8a8 => .low,
            .r32g32b32a32 => .high,
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
    defer image.deinit();

    // Encode the pixel data
    const bc7_encoder = Bc7Enc.init() orelse @panic("failed to init encoder");
    defer bc7_encoder.deinit();
    const encoded = switch (encoding) {
        .r8g8b8a8, .r32g32b32a32 => image.data,
        .bc7 => |bc7| b: {
            var params: Bc7Enc.Params = .{};

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
            // Ignored when using RDO, should be fine to set anyway
            params.perceptual = bc7.named.@"color-space" == .srgb;
            params.mode6_only = bc7.named.@"mode-6-only";

            if (bc7.named.@"max-threads") |v| {
                if (v == 0) {
                    log.err("invalid value for max-threads", .{});
                    std.process.exit(1);
                }
                params.rdo_max_threads = v;
            } else {
                params.rdo_max_threads = @intCast(std.math.clamp(std.Thread.getCpuCount() catch 1, 1, std.math.maxInt(u32)));
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

            if (!bc7_encoder.encode(&params, image.width, image.height, image.data.ptr)) {
                log.err("{s}: encoder failed", .{args.positional.INPUT});
                std.process.exit(1);
            }

            // Break with the encoded data
            break :b bc7_encoder.getBlocks();
        },
    };

    // Compress the data if needed
    const compressed = if (args.named.zlib) |level| b: {
        var compressed = ArrayListUnmanaged(u8).initCapacity(allocator, encoded.len) catch |err| {
            log.err("{s}: deflate failed: {s}", .{ args.positional.OUTPUT, @errorName(err) });
            std.process.exit(1);
        };
        defer compressed.deinit(allocator);

        const Compressor = std.compress.flate.deflate.Compressor(.zlib, @TypeOf(compressed).Writer);
        var compressor = Compressor.init(
            compressed.writer(allocator),
            .{ .level = level.toStdLevel() },
        ) catch |err| {
            log.err("{s}: deflate failed: {s}", .{ args.positional.OUTPUT, @errorName(err) });
            std.process.exit(1);
        };
        _ = compressor.write(encoded) catch |err| {
            log.err("{s}: deflate failed: {s}", .{ args.positional.OUTPUT, @errorName(err) });
            std.process.exit(1);
        };
        compressor.finish() catch |err| {
            log.err("{s}: deflate failed: {s}", .{ args.positional.OUTPUT, @errorName(err) });
            std.process.exit(1);
        };
        break :b compressed.toOwnedSlice(allocator) catch |err| {
            log.err("{s}: deflate failed: {s}", .{ args.positional.OUTPUT, @errorName(err) });
            std.process.exit(1);
        };
    } else encoded;
    defer if (args.named.zlib != null) allocator.free(compressed);

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
        .levels = 1,
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
        .pixel_width = image.width,
        .pixel_height = image.height,
        .pixel_depth = 0,
        .layer_count = 0,
        .face_count = 1,
        .level_count = .fromInt(1),
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
    const first_level_padding_offset = index.dfd_byte_offset + index.dfd_byte_length;
    const first_level_offset = std.mem.alignForward(u64, first_level_padding_offset, level_alignment);
    const first_level_padding = first_level_offset - first_level_padding_offset;
    writer.writeStruct(Ktx2.Level{
        .byte_offset = first_level_offset,
        .byte_length = compressed.len,
        .uncompressed_byte_length = encoded.len,
    }) catch |err| {
        log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
        std.process.exit(1);
    };

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

    // Write the compressed data
    writer.writeByteNTimes(0, first_level_padding) catch |err| {
        log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
        std.process.exit(1);
    };
    writer.writeAll(compressed) catch |err| {
        log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
        std.process.exit(1);
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
        pixels: [*]const u8,
    ) callconv(.C) bool;
    extern fn bc7enc_getBlocks(self: *@This()) callconv(.C) [*]u8;
    extern fn bc7enc_getTotalBlocksSizeInBytes(self: *@This()) callconv(.C) u32;
};

pub const Image = struct {
    width: u32,
    height: u32,
    data: []u8,

    pub const Error = error{
        StbImageFailure,
        LdrAsHdr,
    };

    pub const InitOptions = struct {
        pub const DynamicRange = enum {
            high,
            low,
        };

        bytes: []const u8,
        desired_channels: u8,
        dynamic_range: DynamicRange,
        multiply_by_alpha: bool,
    };
    pub fn init(options: InitOptions) Error!@This() {
        switch (options.dynamic_range) {
            .low => {
                var width: c_int = 0;
                var height: c_int = 0;
                var input_channels: c_int = 0;
                const data = stbi_load_from_memory(
                    options.bytes.ptr,
                    @intCast(options.bytes.len),
                    &width,
                    &height,
                    &input_channels,
                    options.desired_channels,
                ) orelse return error.StbImageFailure;

                const len = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * @as(usize, @intCast(options.desired_channels));
                const image: @This() = .{
                    .width = @intCast(width),
                    .height = @intCast(height),
                    .data = data[0..len],
                };

                if (options.multiply_by_alpha) {
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
            .high => {
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
                    options.desired_channels,
                ) orelse return error.StbImageFailure;

                const len = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * @as(usize, @intCast(options.desired_channels));
                const data = data_ptr[0..len];
                const image: @This() = .{
                    .width = @intCast(width),
                    .height = @intCast(height),
                    .data = std.mem.sliceAsBytes(data),
                };

                if (options.multiply_by_alpha) {
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
        }
    }

    pub fn deinit(self: @This()) void {
        stbi_image_free(self.data.ptr);
    }

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
};
