// XXX: move onto Ktx2? if we can support enough of it..? have to switch encoding
// to format to do that

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Ktx2 = @import("Ktx2");
const EncodedImage = @import("EncodedImage.zig");

pub const Options = struct {
    encoding: EncodedImage.Encoding,
    width: u32,
    height: u32,
    alpha_is_transparency: bool,
    uncompressed_level_lengths: []const u64,
    compressed_levels: []const []const u8,
    supercompression: Ktx2.Header.SupercompressionScheme,
};

pub fn write(writer: anytype, options: Options) @TypeOf(writer).Error!void {
    // Serialization assumes little endian
    comptime assert(builtin.cpu.arch.endian() == .little);

    // Write the header
    const samples = options.encoding.samples();
    const index = Ktx2.Header.Index.init(.{
        .levels = @intCast(options.compressed_levels.len),
        .samples = samples,
    });
    try writer.writeStruct(Ktx2.Header{
        .format = switch (options.encoding) {
            .rgba_u8 => .r8g8b8a8_uint,
            .rgba_srgb_u8 => .r8g8b8a8_srgb,
            .rgba_f32 => .r32g32b32a32_sfloat,
            .bc7 => .bc7_unorm_block,
            .bc7_srgb => .bc7_srgb_block,
        },
        .type_size = options.encoding.typeSize(),
        .pixel_width = options.width,
        .pixel_height = options.height,
        .pixel_depth = 0,
        .layer_count = 0,
        .face_count = 1,
        .level_count = .fromInt(@intCast(options.compressed_levels.len)),
        .supercompression_scheme = options.supercompression,
        .index = index,
    });

    // Write the level index
    const level_alignment: u8 = if (options.supercompression != .none) 1 else switch (options.encoding) {
        .rgba_u8, .rgba_srgb_u8 => 4,
        .rgba_f32 => 16,
        .bc7, .bc7_srgb => 16,
    };
    {
        // Calculate the byte offsets, taking into account that KTX2 requires mipmaps be stored from
        // largest to smallest for streaming purposes
        var byte_offsets_reverse: std.BoundedArray(usize, Ktx2.max_levels) = .{};
        {
            var byte_offset: usize = index.dfd_byte_offset + index.dfd_byte_length;
            for (0..options.compressed_levels.len) |i| {
                byte_offset = std.mem.alignForward(usize, byte_offset, level_alignment);
                const compressed_level = options.compressed_levels[options.compressed_levels.len - i - 1];
                byte_offsets_reverse.appendAssumeCapacity(byte_offset);
                byte_offset += compressed_level.len;
            }
        }

        // Write the level index data, this is done from largest to smallest, only the actual data
        // is stored in reverse order.
        for (0..options.compressed_levels.len) |i| {
            try writer.writeStruct(Ktx2.Level{
                .byte_offset = byte_offsets_reverse.get(options.compressed_levels.len - i - 1),
                .byte_length = options.compressed_levels[i].len,
                .uncompressed_byte_length = options.uncompressed_level_lengths[i],
            });
        }
    }

    // Write the data descriptor
    {
        try writer.writeInt(u32, index.dfd_byte_length, .little);
        try writer.writeAll(std.mem.asBytes(&Ktx2.BasicDescriptorBlock{
            .descriptor_block_size = Ktx2.BasicDescriptorBlock.descriptorBlockSize(samples),
            .model = switch (options.encoding) {
                .rgba_u8, .rgba_srgb_u8, .rgba_f32 => .rgbsda,
                .bc7, .bc7_srgb => .bc7,
            },
            .primaries = .bt709,
            .transfer = switch (options.encoding.colorSpace()) {
                .linear, .hdr => .linear,
                .srgb => .srgb,
            },
            .flags = .{
                .alpha_premultiplied = options.alpha_is_transparency,
            },
            .texel_block_dimension_0 = .fromInt(options.encoding.blockSize()),
            .texel_block_dimension_1 = .fromInt(options.encoding.blockSize()),
            .texel_block_dimension_2 = .fromInt(1),
            .texel_block_dimension_3 = .fromInt(1),
            .bytes_plane_0 = if (options.supercompression != .none) 0 else switch (options.encoding) {
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
        switch (options.encoding) {
            .rgba_u8, .rgba_srgb_u8 => for (0..4) |i| {
                const ChannelType = Ktx2.BasicDescriptorBlock.Sample.ChannelType(.rgbsda);
                const channel_type: ChannelType = if (i == 3) .alpha else @enumFromInt(i);
                writer.writeAll(std.mem.asBytes(&Ktx2.BasicDescriptorBlock.Sample{
                    .bit_offset = .fromInt(8 * @as(u16, @intCast(i))),
                    .bit_length = .fromInt(8),
                    .channel_type = @enumFromInt(@intFromEnum(channel_type)),
                    .linear = switch (options.encoding.colorSpace()) {
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
                    .upper = switch (options.encoding.colorSpace()) {
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
        var byte_offset: usize = index.dfd_byte_offset + index.dfd_byte_length;
        for (0..options.compressed_levels.len) |i| {
            // Write padding
            const padded = std.mem.alignForward(usize, byte_offset, level_alignment);
            try writer.writeByteNTimes(0, padded - byte_offset);
            byte_offset = padded;

            // Write the level
            const compressed_level = options.compressed_levels[options.compressed_levels.len - i - 1];
            try writer.writeAll(compressed_level);
            byte_offset += compressed_level.len;
        }
    }
}
