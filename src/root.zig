const std = @import("std");
const log = std.log;

pub const Ktx2 = @import("Ktx2");
pub const Image = @import("Image.zig");
pub const EncodedImage = @import("EncodedImage.zig");
pub const CompressedImage = @import("CompressedImage.zig");
pub const ktx2_writer = @import("ktx2_writer.zig");

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
// XXX: move onto texture? problem is, it doesn't own this stuff. we could make it own this stuff,
// but then you're forced to use all our stuff. you can't slot in your own encoder or somtehing. no
// good. OTOH there's not really a good reason to keep a texture around right? so we could just have
// like writeFromFields, writeFromImage, etc.
// XXX: maybe we can have a lower level representation of texture that's just the fields, and a higher
// level version that owns its data? The lower level one is like TextureWriter.Options or something,
// the higher level one is a texture?
// XXX: hmm the thing we're making is not a texture, it's a ktx2 writer I think, that maybe is
// the better way to think about it.
// XXX: we could actually move this onto ktx2 even if it's not complete. not the processing just the
// writer part.
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
    try ktx2_writer.write(writer, .{
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
    });
}
