const std = @import("std");
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
// XXX: make the library build that exposes encoder and image and this stuff, separate from
// the command line tool. Keep ktx on its own though since the runtime only needs that!
const EncodedImage = @import("EncodedImage.zig");
const CompressedImage = @import("CompressedImage.zig");
pub const Texture = @import("Texture.zig");

const ColorSpace = enum {
    linear,
    srgb,
};

const Alpha = enum {
    straight,
    premultiplied,
};

pub const Filter = enum(c_uint) {
    triangle = @intFromEnum(Image.Filter.triangle),
    @"cubic-b-spline" = @intFromEnum(Image.Filter.cubic_b_spline),
    @"catmull-rom" = @intFromEnum(Image.Filter.catmull_rom),
    mitchell = @intFromEnum(Image.Filter.mitchell),
    @"point-sample" = @intFromEnum(Image.Filter.point_sample),

    pub fn filter(self: @This()) Image.Filter {
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
            .description = "defaults to the mitchell filter for LDR images, triangle for HDR images",
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
        NamedArg.init(Image.AddressMode, .{
            .description = "overrides --address-mode in the U direction",
            .long = "address-mode-u",
        }),
        NamedArg.init(Image.AddressMode, .{
            .description = "overrides --address-mode in the V direction",
            .long = "address-mode-v",
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
            .default = .{ .value = EncodedImage.Bc7Enc.Params.max_uber_level },
        }),
        NamedArg.init(bool, .{
            .description = "reduce entropy for better supercompression",
            .long = "reduce-entropy",
            .default = .{ .value = false },
        }),
        NamedArg.init(u8, .{
            .description = "partitions to scan in mode 1, defaults to highest",
            .long = "max-partitions-to-scan",
            .default = .{ .value = EncodedImage.Bc7Enc.Params.max_partitions },
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
    var input_file = cwd.openFile(args.positional.INPUT, .{}) catch |err| {
        log.err("{s}: {s}", .{ args.positional.INPUT, @errorName(err) });
        std.process.exit(1);
    };
    defer input_file.close();

    var output_file = cwd.createFile(args.positional.OUTPUT, .{}) catch |err| {
        log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
        std.process.exit(1);
    };
    defer {
        output_file.sync() catch |err| @panic(@errorName(err));
        output_file.close();
    }

    try createTexture(allocator, input_file.reader(), output_file.writer(), .{
        .alpha_is_transparency = switch (args.named.@"input-alpha") {
            .premultiplied => false,
            .straight => true,
        },
        .encoding = switch (encoding) {
            .bc7 => |eo| b: {
                const bc7: EncodedImage.Options.Bc7 = .{
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
                };
                break :b switch (eo.named.@"color-space") {
                    .srgb => .{ .bc7_srgb = bc7 },
                    .linear => .{ .bc7 = bc7 },
                };
            },
            .@"rgba-u8" => |eo| switch (eo.named.@"color-space") {
                .linear => .rgba_u8,
                .srgb => .rgba_srgb_u8,
            },
            .@"rgba-f32" => .rgba_f32,
        },
        // XXX: ...
        .filter_u = switch (args.named.@"filter-u" orelse args.named.filter orelse @panic("unimplemented")) {
            .triangle => .triangle,
            .@"cubic-b-spline" => .cubic_b_spline,
            .@"catmull-rom" => .catmull_rom,
            .mitchell => .mitchell,
            .@"point-sample" => .point_sample,
        },
        // XXX: ...
        .filter_v = switch (args.named.@"filter-v" orelse args.named.filter orelse @panic("unimplemented")) {
            .triangle => .triangle,
            .@"cubic-b-spline" => .cubic_b_spline,
            .@"catmull-rom" => .catmull_rom,
            .mitchell => .mitchell,
            .@"point-sample" => .point_sample,
        },
        // XXX: it should be possible to set a default for a lot of settings globally, and then override
        // them per texture. e.g. you may want to just say "supercompress all assets" but then you may
        // also want to override the options per asset. you may also want to change this in different build
        // modes, e.g. it may not be worth it to wait for supercompression during hot swaps.
        // similar tradeoffs for threads.
        .max_threads = args.named.@"max-threads",
        .generate_mipmaps = args.named.@"generate-mipmaps",
        .alpha_test = if (args.named.@"preserve-alpha-coverage") |t| .{
            .threshold = t,
            .max_steps = args.named.@"preserve-alpha-coverage-max-steps",
        } else null,
        .max_size = args.named.@"max-size" orelse std.math.maxInt(u32),
        .max_width = args.named.@"max-width" orelse std.math.maxInt(u32),
        .max_height = args.named.@"max-height" orelse std.math.maxInt(u32),
        .address_mode_u = args.named.@"address-mode-u",
        .address_mode_v = args.named.@"address-mode-v",
        .supercompression = if (args.named.zlib) |level| .{
            .zlib = .{ .level = level.toStdLevel() },
        } else .none,
    });
}

// XXX: return error.InvalidParam instead of details, but log them.
// XXX: naming
pub const CreateTextureError = error{
    StbImageFailure,
    WrongColorSpace,
    InvalidOption,
    StbResizeFailure,
    OutOfMemory,
    EncoderFailed,
    // XXX: ?
    UnfinishedBits,
    StreamTooLong,
};
pub const CreateTextureOptions = struct {
    alpha_is_transparency: bool = true,
    // XXX: this forces error to be anyerror...maybe we wanna make this generic, maybe make a texture
    // writer object or something. that can take the non texture specific options?
    encoding: EncodedImage.Options,
    // XXX: use elsewhere too?
    max_threads: ?u16 = null,
    // XXX: add everything so we can remove args param
    generate_mipmaps: bool = false,
    alpha_test: ?struct {
        threshold: f32 = 0.5,
        max_steps: u8 = 10,
    } = null,
    max_size: u32 = std.math.maxInt(u32),
    max_width: u32 = std.math.maxInt(u32),
    max_height: u32 = std.math.maxInt(u32),
    address_mode_u: Image.AddressMode,
    address_mode_v: Image.AddressMode,
    supercompression: CompressedImage.Options = .none,
    filter: Image.Filter = .mitchell,
    filter_u: ?Image.Filter = null,
    filter_v: ?Image.Filter = null,

    pub fn filterU(self: @This()) Image.Filter {
        return self.filter_u orelse self.filter;
    }

    pub fn filterV(self: @This()) Image.Filter {
        return self.filter_v orelse self.filter;
    }
};

// XXX: then make sure that everything done in here COULD be done manually as well
// as a lower level api, esp encoding, and also, writing the ktx file
// XXX: I think we can make encode functions on the image, and writing the ktx file
// COULD be part of ktx2 or could be here
// XXX: could move this to image if we wanted
// XXX: could make a version that operates on an image, and a version that operates on a reader
pub fn createTexture(
    gpa: std.mem.Allocator,
    reader: anytype,
    writer: anytype,
    options: CreateTextureOptions,
) (@TypeOf(reader).Error || @TypeOf(writer).Error || CreateTextureError)!void {
    // Get the encoding tag
    const encoding: EncodedImage.Encoding = options.encoding;

    // Load the image.
    const original = try Image.read(gpa, reader, encoding.colorSpace());
    defer original.deinit();

    // Premultiply alpha if it represents transparency.
    if (options.alpha_is_transparency) original.premultiply();

    // Create an array of mip levels.
    var raw_levels: std.BoundedArray(Image, Ktx2.max_levels) = .{};
    defer for (raw_levels.constSlice()[1..]) |level| {
        level.deinit();
    };

    // Copy the original to mip levels, resizing if needed. This results in an unnecessary copy in
    // some cases, but greatly simplifies the control flow.
    raw_levels.appendAssumeCapacity(try original.resizeToFit(.{
        .max_size = options.max_size,
        .max_width = options.max_width,
        .max_height = options.max_height,
        .address_mode_u = options.address_mode_u,
        .address_mode_v = options.address_mode_v,
        .filter_u = options.filterU(),
        .filter_v = options.filterV(),
    }));

    // Generate any other requested mipmaps.
    if (options.generate_mipmaps) {
        var generate_mipmaps = raw_levels.get(0).generateMipmaps(.{
            .address_mode_u = options.address_mode_u,
            .address_mode_v = options.address_mode_v,
            .filter_u = options.filterU(),
            .filter_v = options.filterV(),
            .block_size = encoding.blockSize(),
        });

        while (try generate_mipmaps.next()) |mipmap| {
            raw_levels.appendAssumeCapacity(mipmap);
        }
    }

    // Preserve alpha coverage for alpha tested textures. Technically we could skip the first level
    // if no resizing was done, but for simplicity's sake we don't.
    if (options.alpha_test) |alpha_test| {
        const coverarage = original.alphaCoverage(alpha_test.threshold, 1.0);
        for (raw_levels.constSlice()) |level| {
            level.preserveAlphaCoverage(.{
                .threshold = alpha_test.threshold,
                .coverage = coverarage,
                .max_steps = alpha_test.max_steps,
            });
        }
    }

    // Encode the pixel data
    var encoded_levels: std.BoundedArray(EncodedImage, Ktx2.max_levels) = .{};
    defer for (encoded_levels.constSlice()) |level| {
        level.deinit(gpa);
    };
    for (raw_levels.constSlice()) |raw_level| {
        encoded_levels.appendAssumeCapacity(try EncodedImage.init(
            gpa,
            raw_level,
            options.max_threads,
            options.encoding,
        ));
    }

    // XXX: could do this on multiple threads, or file issue for this for post 1.0
    // Compress the data if needed
    var compressed_levels: std.BoundedArray(CompressedImage, Ktx2.max_levels) = .{};
    defer for (compressed_levels.constSlice()) |level| {
        level.deinit(gpa);
    };
    for (encoded_levels.constSlice()) |level_encoder| {
        compressed_levels.appendAssumeCapacity(try CompressedImage.init(
            gpa,
            level_encoder.buf,
            options.supercompression,
        ));
    }

    // Write the texture as KTX2
    var uncompressed_level_lengths: std.BoundedArray(u64, Ktx2.max_levels) = .{};
    for (encoded_levels.constSlice()) |level| {
        uncompressed_level_lengths.appendAssumeCapacity(level.buf.len);
    }
    var compressed_level_bufs: std.BoundedArray([]const u8, Ktx2.max_levels) = .{};
    for (compressed_levels.constSlice()) |level| {
        compressed_level_bufs.appendAssumeCapacity(level.buf);
    }
    const texture: Texture = .{
        .encoding = encoding,
        .width = raw_levels.get(0).width,
        .height = raw_levels.get(0).height,
        .alpha_is_transparency = options.alpha_is_transparency,
        .uncompressed_level_lengths = uncompressed_level_lengths.constSlice(),
        .compressed_levels = compressed_level_bufs.constSlice(),
        .supercompression = switch (options.supercompression) {
            .none => .none,
            .zlib => .zlib,
        },
    };
    try texture.writeKtx2(writer);
}
