//! An image for texture processing.
//!
//! Images are stored as r32g32b32a32. The high precision allows processing LDR and HDR images in
//! the same code path, and increases precision of intermediate operations, although the final
//! results may be quantized.
//!
//! STB is used for image manipulation, and as such memory management goes through C's allocator. We
//! can't trivially use a Zig allocator here since STB's free function isn't given a length.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log;
const c = @import("c.zig");
const tracy = @import("tracy");
const Zone = tracy.Zone;

const Image = @This();

const max_file_len = 4294967296;

width: u32,
height: u32,
data: []f32,
hdr: bool,
allocator: Allocator,

pub const InitError = error{
    /// STB failed to parse the image.
    StbImageFailure,
    /// The image's color space did not match.
    WrongColorSpace,
};

pub const ColorSpace = enum(c_uint) {
    linear,
    srgb,
    hdr,
};

/// Read an image using `stb_image.h`.
pub fn initFromReader(
    gpa: std.mem.Allocator,
    reader: anytype,
    color_space: ColorSpace,
) (@TypeOf(reader).Error || error{ StreamTooLong, OutOfMemory } || InitError)!Image {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    // We could pass the reader into STB for additional pipelining and reduced allocations. For
    // simplicity's sake we don't do this yet, but we keep our options open by taking a reader.
    const input_bytes = b: {
        const read_zone = Zone.begin(.{ .name = "read", .src = @src() });
        defer read_zone.end();
        break :b try reader.readAllAlloc(gpa, max_file_len);
    };
    defer gpa.free(input_bytes);

    // Check if the input is HDR
    const hdr = c.stbi_is_hdr_from_memory(
        input_bytes.ptr,
        @intCast(input_bytes.len),
    ) == 1;

    // Check that our color space matches up with the source image.
    switch (color_space) {
        .linear, .srgb => if (hdr) return error.WrongColorSpace,
        .hdr => if (!hdr) return error.WrongColorSpace,
    }

    // We're gonna do our own premul, and STB doesn't expose whether it was already done or not.
    // Typically it is not unless we're dealing with an iPhone PNG. Always get canonical format.
    c.stbi_set_unpremultiply_on_load(1);
    c.stbi_convert_iphone_png_to_rgb(1);

    // All images are loaded as linear floats regardless of the source and dest formats.
    //
    // Rational:
    // - Increases precision of any manipulations done to the image (e.g. repeated downsampling
    //   for mipmap generation)
    // - Saves us from having separate branches for LDR and HDR processing
    //
    // There's no technical benefit in the case where no processing is done, but this is not the
    // common case.
    c.stbi_ldr_to_hdr_gamma(switch (color_space) {
        .srgb => 2.2,
        .linear, .hdr => 1.0,
    });

    // Load the image
    var width: c_int = 0;
    var height: c_int = 0;
    var input_channels: c_int = 0;
    const data_ptr = b: {
        const read_zone = Zone.begin(.{ .name = "stbi_loadf_from_memory", .src = @src() });
        defer read_zone.end();
        break :b c.stbi_loadf_from_memory(
            input_bytes.ptr,
            @intCast(input_bytes.len),
            &width,
            &height,
            &input_channels,
            4,
        ) orelse return error.StbImageFailure;
    };

    // Create the image
    const data_len = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .data = data_ptr[0..data_len],
        .hdr = hdr,
        .allocator = stb_allocator,
    };
}

pub fn deinit(self: *Image) void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.allocator.free(self.data);
    _ = self.toOwned();
}

pub fn premultiply(self: Image) void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    var px: usize = 0;
    while (px < @as(usize, self.width) * @as(usize, self.height) * 4) : (px += 4) {
        const a = self.data[px + 3];
        self.data[px + 0] = self.data[px + 0] * a;
        self.data[px + 1] = self.data[px + 1] * a;
        self.data[px + 2] = self.data[px + 2] * a;
    }
}

pub const AddressMode = enum(c_uint) {
    clamp = c.STBIR_EDGE_CLAMP,
    reflect = c.STBIR_EDGE_REFLECT,
    wrap = c.STBIR_EDGE_WRAP,
    zero = c.STBIR_EDGE_ZERO,
};

pub const Filter = enum(c_uint) {
    // See https://github.com/Games-by-Mason/Zex/issues/20
    // box = c.STBIR_FILTER_BOX,
    default,
    triangle,
    cubic_b_spline,
    catmull_rom,
    mitchell,
    point_sample,

    fn sharpens(self: @This(), hdr: bool) bool {
        return switch (self) {
            .default => !hdr,
            .triangle, .point_sample, .cubic_b_spline => false,
            .mitchell, .catmull_rom => true,
        };
    }

    fn toStbFilter(self: @This(), hdr: bool) c.stbir_filter {
        return switch (self) {
            .default => if (hdr) c.STBIR_FILTER_TRIANGLE else c.STBIR_FILTER_MITCHELL,
            .triangle => c.STBIR_FILTER_TRIANGLE,
            .cubic_b_spline => c.STBIR_FILTER_CUBICBSPLINE,
            .catmull_rom => c.STBIR_FILTER_CATMULLROM,
            .mitchell => c.STBIR_FILTER_MITCHELL,
            .point_sample => c.STBIR_FILTER_POINT_SAMPLE,
        };
    }
};

pub const ResizeError = error{ StbResizeFailure, OutOfMemory };

pub const ResizeOptions = struct {
    width: u32,
    height: u32,
    address_mode_u: AddressMode,
    address_mode_v: AddressMode,
    filter_u: Filter,
    filter_v: Filter,
};

pub fn resized(self: Image, options: ResizeOptions) ResizeError!Image {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    assert(options.width > 0 and options.height > 0);

    const output_samples = @as(usize, options.width) * @as(usize, options.height) * 4;
    const data_ptr: [*]f32 = @ptrCast(@alignCast(c.malloc(
        output_samples * @sizeOf(f32),
    ) orelse return error.OutOfMemory));
    const data = data_ptr[0..output_samples];

    var stbr_options: c.STBIR_RESIZE = undefined;
    c.stbir_resize_init(
        &stbr_options,
        self.data.ptr,
        @intCast(self.width),
        @intCast(self.height),
        0,
        data.ptr,
        @intCast(options.width),
        @intCast(options.height),
        0,
        // We always premultiply alpha channels ourselves if they represent transparency
        c.STBIR_RGBA_PM,
        c.STBIR_TYPE_FLOAT,
    );

    stbr_options.horizontal_edge = @intFromEnum(options.address_mode_u);
    stbr_options.vertical_edge = @intFromEnum(options.address_mode_v);
    stbr_options.horizontal_filter = options.filter_u.toStbFilter(self.hdr);
    stbr_options.vertical_filter = options.filter_v.toStbFilter(self.hdr);

    {
        const resize_zone = Zone.begin(.{ .name = "stbir_resize_extended", .src = @src() });
        defer resize_zone.end();
        if (c.stbir_resize_extended(&stbr_options) != 1) {
            c.free(data.ptr);
            return error.StbResizeFailure;
        }
    }

    // Sharpening filters can push values below zero. Clamp them before doing further processing.
    // We could alternatively use `STBIR_FLOAT_LOW_CLAMP`, see issue #18.
    if (options.filter_u.sharpens(self.hdr) or options.filter_v.sharpens(self.hdr)) {
        const clamp_zone = Zone.begin(.{ .name = "clamp", .src = @src() });
        defer clamp_zone.end();
        for (data) |*d| {
            d.* = @max(d.*, 0.0);
        }
    }

    return .{
        .width = options.width,
        .height = options.height,
        .data = data,
        .hdr = self.hdr,
        .allocator = stb_allocator,
    };
}

pub fn resize(self: *Image, options: ResizeOptions) ResizeError!void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    if (self.width != options.width or self.height != options.height) {
        const result = try self.resized(options);
        self.deinit();
        self.* = result;
    }
}

pub const SizeToFitOptions = struct {
    max_size: u32 = std.math.maxInt(u32),
    max_width: u32 = std.math.maxInt(u32),
    max_height: u32 = std.math.maxInt(u32),
};

pub fn sizeToFit(self: Image, options: SizeToFitOptions) struct { u32, u32 } {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    const self_width_f: f64 = @floatFromInt(self.width);
    const self_height_f: f64 = @floatFromInt(self.height);

    const max_width: u32 = @min(options.max_width, options.max_size, self.width);
    const max_height: u32 = @min(options.max_height, options.max_size, self.height);

    const max_width_f: f64 = @floatFromInt(max_width);
    const max_height_f: f64 = @floatFromInt(max_height);

    const x_scale = @min(max_width_f / self_width_f, 1.0);
    const y_scale = @min(max_height_f / self_height_f, 1.0);

    const scale = @min(x_scale, y_scale);
    const width = @min(@as(u32, @intFromFloat(scale * self_width_f)), max_width);
    const height = @min(@as(u32, @intFromFloat(scale * self_height_f)), max_height);

    return .{ width, height };
}

pub const ResizeToFitOptions = struct {
    max_size: u32 = std.math.maxInt(u32),
    max_width: u32 = std.math.maxInt(u32),
    max_height: u32 = std.math.maxInt(u32),
    address_mode_u: AddressMode,
    address_mode_v: AddressMode,
    filter_u: Filter,
    filter_v: Filter,
};

pub fn resizeToFit(self: *Image, options: ResizeToFitOptions) ResizeError!void {
    const width, const height = self.sizeToFit(.{
        .max_size = options.max_size,
        .max_width = options.max_width,
        .max_height = options.max_height,
    });

    try self.resize(.{
        .width = width,
        .height = height,
        .address_mode_u = options.address_mode_u,
        .address_mode_v = options.address_mode_v,
        .filter_u = options.filter_u,
        .filter_v = options.filter_v,
    });
}

pub fn resizedToFit(self: Image, options: ResizeToFitOptions) ResizeError!Image {
    const width, const height = self.sizeToFit(.{
        .max_size = options.max_size,
        .max_width = options.max_width,
        .max_height = options.max_height,
    });

    return self.resized(.{
        .width = width,
        .height = height,
        .address_mode_u = options.address_mode_u,
        .address_mode_v = options.address_mode_v,
        .filter_u = options.filter_u,
        .filter_v = options.filter_v,
    });
}

pub const GenerateMipMapsOptions = struct {
    block_size: u8,
    address_mode_u: AddressMode,
    address_mode_v: AddressMode,
    filter_u: Filter,
    filter_v: Filter,
};

pub fn generateMipmaps(self: Image, options: GenerateMipMapsOptions) GenerateMipmaps {
    return .{
        .options = options,
        .image = self,
    };
}

pub const GenerateMipmaps = struct {
    options: GenerateMipMapsOptions,
    image: Image,

    pub fn next(self: *@This()) ResizeError!?Image {
        // Stop once we're below the block size, there's no benefit to further mipmaps
        if (self.image.width <= self.options.block_size and
            self.image.height <= self.options.block_size)
        {
            return null;
        }

        // Halve the image size
        self.image = try self.image.resized(.{
            .width = @max(1, self.image.width / 2),
            .height = @max(1, self.image.height / 2),
            .address_mode_u = self.options.address_mode_u,
            .address_mode_v = self.options.address_mode_v,
            .filter_u = self.options.filter_u,
            .filter_v = self.options.filter_v,
        });
        return self.image;
    }
};

pub fn alphaCoverage(self: Image, threshold: f32, scale: f32) f32 {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    // Quantize the threshold to the output type
    const quantized_threshold = if (self.hdr) threshold else @round(threshold * 255.0) / 255.0;

    // Calculate the coverage
    var coverage: f32 = 0;
    for (0..@as(usize, self.width) * @as(usize, self.height)) |i| {
        const alpha = self.data[i * 4 + 3];
        if (alpha * scale > quantized_threshold) coverage += 1.0;
    }
    coverage /= @floatFromInt(@as(usize, self.width) * @as(usize, self.height));
    return coverage;
}

pub const PreserveAlphaCoverageOptions = struct {
    coverage: f32,
    max_steps: u8,
    threshold: f32,
};

pub fn preserveAlphaCoverage(self: Image, options: PreserveAlphaCoverageOptions) void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    // Binary search for the best scale parameter
    var best_scale: f32 = 1.0;
    var best_dist = std.math.inf(f32);
    var upper_threshold: f32 = 1.0;
    var lower_threshold: f32 = 0.0;
    var curr_threshold: f32 = options.threshold;
    {
        const search_zone = Zone.begin(.{ .name = "search", .src = @src() });
        defer search_zone.end();
        for (0..options.max_steps) |_| {
            const curr_scale = options.threshold / curr_threshold;
            const coverage = self.alphaCoverage(options.threshold, curr_scale);
            const dist_to_coverage = @abs(coverage - options.coverage);
            if (dist_to_coverage < best_dist) {
                best_dist = dist_to_coverage;
                best_scale = curr_scale;
            }

            if (coverage < options.coverage) {
                upper_threshold = curr_threshold;
            } else if (coverage > options.coverage) {
                lower_threshold = curr_threshold;
            } else {
                break;
            }

            curr_threshold = (lower_threshold + upper_threshold) / 2.0;
        }
    }

    // Apply the scaling
    if (best_scale != 1.0) {
        const search_zone = Zone.begin(.{ .name = "scale", .src = @src() });
        defer search_zone.end();
        for (0..@as(usize, self.width) * @as(usize, self.height)) |i| {
            const a = &self.data[i * 4 + 3];
            a.* = @min(a.* * best_scale, 1.0);
        }
    }
}

pub fn toOwned(self: *Image) Image {
    const owned: Image = self.*;
    self.width = 0;
    self.height = 0;
    self.data = &.{};
    self.allocator = moved_allocator;
    return owned;
}

fn unsupportedAlloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = len;
    _ = ptr_align;
    _ = ret_addr;
    @panic("unsupported");
}

fn unsupportedResize(
    ctx: *anyopaque,
    buf: []u8,
    buf_align: u8,
    new_len: usize,
    ret_addr: usize,
) bool {
    _ = ctx;
    _ = buf;
    _ = buf_align;
    _ = new_len;
    _ = ret_addr;
    @panic("unsupported");
}

fn stbFree(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
    _ = ctx;
    _ = buf_align;
    _ = ret_addr;
    c.stbi_image_free(buf.ptr);
}

fn movedFree(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
    _ = ctx;
    _ = buf_align;
    _ = ret_addr;
    _ = buf;
}

const stb_allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = &unsupportedAlloc,
        .resize = &unsupportedResize,
        .free = &stbFree,
    },
};

const moved_allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = &unsupportedAlloc,
        .resize = &unsupportedResize,
        .free = &movedFree,
    },
};
