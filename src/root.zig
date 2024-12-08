const std = @import("std");
const log = std.log;
const tracy = @import("tracy");
const Zone = tracy.Zone;

pub const Ktx2 = @import("Ktx2");
pub const Image = @import("Image.zig");
pub const EncodedImage = @import("EncodedImage.zig");
pub const CompressedImage = @import("CompressedImage.zig");
pub const Texture = @import("Texture.zig");

pub const CreateTextureError = error{
    StbImageFailure,
    WrongColorSpace,
    InvalidOption,
    StbResizeFailure,
    OutOfMemory,
    EncoderFailed,
    UnfinishedBits,
    StreamTooLong,
};
pub const CreateTextureOptions = struct {
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

pub fn createTexture(
    gpa: std.mem.Allocator,
    reader: anytype,
    writer: anytype,
    options: CreateTextureOptions,
) (@TypeOf(reader).Error || @TypeOf(writer).Error || CreateTextureError)!void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    // Get the encoding tag
    const encoding: EncodedImage.Encoding = options.encoding;

    // Create an array of mip levels.
    var raw_levels: std.BoundedArray(Image, Ktx2.max_levels) = .{};
    defer for (raw_levels.slice()) |*level| level.deinit();

    // Generate the first level of the mip
    const alpha_coverage, const width, const height = b: {
        const first_level_zone = Zone.begin(.{ .name = "first level", .src = @src() });
        defer first_level_zone.end();

        // Load the image.
        var image = try Image.read(gpa, reader, encoding.colorSpace());
        errdefer image.deinit();

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
        raw_levels.appendAssumeCapacity(image);

        // Break with the alpha coverage
        break :b .{ alpha_coverage, image.width, image.height };
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

    // Write the texture as KTX2
    {
        const write_zone = Zone.begin(.{ .name = "write", .src = @src() });
        defer write_zone.end();
        var texture: Texture = .{
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
        defer texture.deinit();
        try texture.writeKtx2(writer);
    }
}
