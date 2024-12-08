const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const tracy = @import("tracy");
const Zone = tracy.Zone;
const Ktx2 = @import("Ktx2");
const EncodedImage = @import("EncodedImage.zig");
const CompressedImage = @import("CompressedImage.zig");
const Image = @import("Image.zig");
const Texture = @This();

encoding: EncodedImage.Encoding,
width: u32,
height: u32,
alpha_is_transparency: bool,
compressed_levels: std.BoundedArray(CompressedImage, Ktx2.max_levels),
supercompression: Ktx2.Header.SupercompressionScheme,

pub const InitError = error{
    StbImageFailure,
    WrongColorSpace,
    InvalidOption,
    StbResizeFailure,
    OutOfMemory,
    EncoderFailed,
    UnfinishedBits,
    StreamTooLong,
};
pub const InitOptions = struct {
    alpha_is_transparency: bool = true,
    encoding: EncodedImage.Options,
    max_threads: ?u16 = null,
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

pub fn initFromReader(
    gpa: std.mem.Allocator,
    reader: anytype,
    options: InitOptions,
) (@TypeOf(reader).Error || InitError)!Texture {
    const encoding: EncodedImage.Encoding = options.encoding;
    var image = try Image.initFromReader(gpa, reader, encoding.colorSpace());
    defer image.deinit();
    return try initFromImage(gpa, &image, options);
}

pub fn initFromImage(
    gpa: std.mem.Allocator,
    image: *Image,
    options: InitOptions,
) InitError!Texture {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    defer image.deinit();

    // Get the encoding tag
    const encoding: EncodedImage.Encoding = options.encoding;

    // Create an array of mip levels.
    var raw_levels: std.BoundedArray(Image, Ktx2.max_levels) = .{};
    defer for (raw_levels.slice()) |*level| level.deinit();

    // Generate the first level of the mip
    const alpha_coverage, const width, const height = b: {
        const first_level_zone = Zone.begin(.{ .name = "process first level", .src = @src() });
        defer first_level_zone.end();

        // Premultiply alpha if it represents transparency.
        if (options.alpha_is_transparency) image.premultiply();

        // Calculate the alpha coverage if requested
        const alpha_coverage = if (options.alpha_test) |alpha_test|
            image.alphaCoverage(alpha_test.threshold, 1.0)
        else
            null;

        // Resize the image if requested
        try image.resizeToFit(.{
            .max_size = options.max_size,
            .max_width = options.max_width,
            .max_height = options.max_height,
            .address_mode_u = options.address_mode_u,
            .address_mode_v = options.address_mode_v,
            .filter_u = options.filterU(),
            .filter_v = options.filterV(),
        });

        // Store the first mip level
        const width = image.width;
        const height = image.height;
        raw_levels.appendAssumeCapacity(image.toOwned());

        // Break with the alpha coverage
        break :b .{ alpha_coverage, width, height };
    };

    // Generate any other requested mipmaps.
    if (options.generate_mipmaps) {
        const mipmap_zone = Zone.begin(.{ .name = "generate mipmaps", .src = @src() });
        defer mipmap_zone.end();

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
        const mipmap_zone = Zone.begin(.{ .name = "alpha test", .src = @src() });
        defer mipmap_zone.end();
        for (raw_levels.constSlice()) |level| {
            level.preserveAlphaCoverage(.{
                .threshold = alpha_test.threshold,
                .coverage = alpha_coverage.?, // Always present if alpha test is set
                .max_steps = alpha_test.max_steps,
            });
        }
    }

    // Encode the pixel data, consuming the raw level data in the process
    var encoded_levels: std.BoundedArray(EncodedImage, Ktx2.max_levels) = .{};
    defer for (encoded_levels.slice()) |*level| level.deinit();
    {
        const encode_zone = Zone.begin(.{ .name = "encode", .src = @src() });
        defer encode_zone.end();
        for (raw_levels.slice()) |*raw_level| {
            encoded_levels.appendAssumeCapacity(try EncodedImage.init(
                gpa,
                raw_level,
                options.max_threads,
                options.encoding,
            ));
        }
        raw_levels.clear();
    }

    // Compress the data if needed
    var compressed_levels: std.BoundedArray(CompressedImage, Ktx2.max_levels) = .{};
    defer for (compressed_levels.slice()) |*level| level.deinit();
    {
        const compress_zone = Zone.begin(.{ .name = "compress", .src = @src() });
        defer compress_zone.end();
        for (encoded_levels.slice()) |*encoded_level| {
            compressed_levels.appendAssumeCapacity(try CompressedImage.init(
                gpa,
                encoded_level,
                options.supercompression,
            ));
        }
        encoded_levels.clear();
    }

    return .{
        .encoding = encoding,
        .width = width,
        .height = height,
        .alpha_is_transparency = options.alpha_is_transparency,
        .compressed_levels = b: {
            const moved = compressed_levels;
            compressed_levels.clear();
            break :b moved;
        },
        .supercompression = switch (options.supercompression) {
            .none => .none,
            .zlib => .zlib,
        },
    };
}

pub fn deinit(self: *@This()) void {
    for (self.compressed_levels.slice()) |*compressed_level| {
        compressed_level.deinit();
    }
    self.* = undefined;
}

pub fn writeKtx2(self: @This(), writer: anytype) @TypeOf(writer).Error!void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    // Serialization assumes little endian
    comptime assert(builtin.cpu.arch.endian() == .little);

    // Write the header
    const samples = self.encoding.samples();
    const index = Ktx2.Header.Index.init(.{
        .levels = @intCast(self.compressed_levels.len),
        .samples = samples,
    });
    {
        const header_zone = Zone.begin(.{ .name = "header", .src = @src() });
        defer header_zone.end();
        try writer.writeStruct(Ktx2.Header{
            .format = switch (self.encoding) {
                .rgba_u8 => .r8g8b8a8_uint,
                .rgba_srgb_u8 => .r8g8b8a8_srgb,
                .rgba_f32 => .r32g32b32a32_sfloat,
                .bc7 => .bc7_unorm_block,
                .bc7_srgb => .bc7_srgb_block,
            },
            .type_size = self.encoding.typeSize(),
            .pixel_width = self.width,
            .pixel_height = self.height,
            .pixel_depth = 0,
            .layer_count = 0,
            .face_count = 1,
            .level_count = .fromInt(@intCast(self.compressed_levels.len)),
            .supercompression_scheme = self.supercompression,
            .index = index,
        });
    }

    // Write the level index
    const level_alignment: u8 = if (self.supercompression != .none) 1 else switch (self.encoding) {
        .rgba_u8, .rgba_srgb_u8 => 4,
        .rgba_f32 => 16,
        .bc7, .bc7_srgb => 16,
    };
    {
        const level_index_zone = Zone.begin(.{ .name = "level index", .src = @src() });
        defer level_index_zone.end();

        // Calculate the byte offsets, taking into account that KTX2 requires mipmaps be stored from
        // largest to smallest for streaming purposes
        var byte_offsets_reverse: std.BoundedArray(usize, Ktx2.max_levels) = .{};
        {
            var byte_offset: usize = index.dfd_byte_offset + index.dfd_byte_length;
            for (0..self.compressed_levels.len) |i| {
                byte_offset = std.mem.alignForward(usize, byte_offset, level_alignment);
                const compressed_level = self.compressed_levels.get(self.compressed_levels.len - i - 1);
                byte_offsets_reverse.appendAssumeCapacity(byte_offset);
                byte_offset += compressed_level.buf.len;
            }
        }

        // Write the level index data, this is done from largest to smallest, only the actual data
        // is stored in reverse order.
        for (0..self.compressed_levels.len) |i| {
            try writer.writeStruct(Ktx2.Level{
                .byte_offset = byte_offsets_reverse.get(self.compressed_levels.len - i - 1),
                .byte_length = self.compressed_levels.get(i).buf.len,
                .uncompressed_byte_length = self.compressed_levels.get(i).uncompressed_len,
            });
        }
    }

    // Write the data descriptor
    {
        const dfd_zone = Zone.begin(.{ .name = "dfd", .src = @src() });
        defer dfd_zone.end();

        try writer.writeInt(u32, index.dfd_byte_length, .little);
        try writer.writeAll(std.mem.asBytes(&Ktx2.BasicDescriptorBlock{
            .descriptor_block_size = Ktx2.BasicDescriptorBlock.descriptorBlockSize(samples),
            .model = switch (self.encoding) {
                .rgba_u8, .rgba_srgb_u8, .rgba_f32 => .rgbsda,
                .bc7, .bc7_srgb => .bc7,
            },
            .primaries = .bt709,
            .transfer = switch (self.encoding.colorSpace()) {
                .linear, .hdr => .linear,
                .srgb => .srgb,
            },
            .flags = .{
                .alpha_premultiplied = self.alpha_is_transparency,
            },
            .texel_block_dimension_0 = .fromInt(self.encoding.blockSize()),
            .texel_block_dimension_1 = .fromInt(self.encoding.blockSize()),
            .texel_block_dimension_2 = .fromInt(1),
            .texel_block_dimension_3 = .fromInt(1),
            .bytes_plane_0 = if (self.supercompression != .none) 0 else switch (self.encoding) {
                .rgba_u8, .rgba_srgb_u8 => 4,
                .rgba_f32 => 16,
                .bc7, .bc7_srgb => 16,
            },
            .bytes_plane_1 = 0,
            .bytes_plane_2 = 0,
            .bytes_plane_3 = 0,
            .bytes_plane_4 = 0,
            .bytes_plane_5 = 0,
            .bytes_plane_6 = 0,
            .bytes_plane_7 = 0,
        })[0 .. @bitSizeOf(Ktx2.BasicDescriptorBlock) / 8]);
        switch (self.encoding) {
            .rgba_u8, .rgba_srgb_u8 => for (0..4) |i| {
                const ChannelType = Ktx2.BasicDescriptorBlock.Sample.ChannelType(.rgbsda);
                const channel_type: ChannelType = if (i == 3) .alpha else @enumFromInt(i);
                writer.writeAll(std.mem.asBytes(&Ktx2.BasicDescriptorBlock.Sample{
                    .bit_offset = .fromInt(8 * @as(u16, @intCast(i))),
                    .bit_length = .fromInt(8),
                    .channel_type = @enumFromInt(@intFromEnum(channel_type)),
                    .linear = switch (self.encoding.colorSpace()) {
                        .linear, .hdr => false,
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
                    .upper = switch (self.encoding.colorSpace()) {
                        .hdr => 1,
                        .srgb, .linear => 255,
                    },
                })) catch unreachable;
            },
            .rgba_f32 => for (0..4) |i| {
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
            .bc7, .bc7_srgb => {
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
    }

    // Write the compressed level data. Note that KTX2 requires mips be stored form smallest to
    // largest for streaming purposes.
    {
        const level_data = Zone.begin(.{ .name = "level data", .src = @src() });
        defer level_data.end();

        var byte_offset: usize = index.dfd_byte_offset + index.dfd_byte_length;
        for (0..self.compressed_levels.len) |i| {
            // Write padding
            const padded = std.mem.alignForward(usize, byte_offset, level_alignment);
            try writer.writeByteNTimes(0, padded - byte_offset);
            byte_offset = padded;

            // Write the level
            const compressed_level = self.compressed_levels.get(self.compressed_levels.len - i - 1);
            try writer.writeAll(compressed_level.buf);
            byte_offset += compressed_level.buf.len;
        }
    }
}
