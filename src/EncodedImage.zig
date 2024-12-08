const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log;
const tracy = @import("tracy");
const Zone = tracy.Zone;

const Image = @import("Image.zig");

pub const Error = error{
    OutOfMemory,
    InvalidOption,
    EncoderFailed,
};

pub const Encoding = enum {
    rgba_u8,
    rgba_srgb_u8,
    rgba_f32,
    bc7,
    bc7_srgb,

    pub fn samples(self: @This()) u8 {
        return switch (self) {
            .rgba_u8, .rgba_srgb_u8, .rgba_f32 => 4,
            .bc7, .bc7_srgb => 1,
        };
    }

    pub fn blockSize(self: @This()) u8 {
        return switch (self) {
            .rgba_u8, .rgba_srgb_u8, .rgba_f32 => 1,
            .bc7, .bc7_srgb => 4,
        };
    }

    pub fn colorSpace(self: @This()) Image.ColorSpace {
        return switch (self) {
            .bc7, .rgba_u8 => .linear,
            .bc7_srgb, .rgba_srgb_u8 => .srgb,
            .rgba_f32 => .hdr,
        };
    }

    pub fn typeSize(self: @This()) u8 {
        return switch (self) {
            .rgba_u8, .rgba_srgb_u8, .bc7, .bc7_srgb => 1,
            .rgba_f32 => 4,
        };
    }
};

pub const Options = union(Encoding) {
    pub const Rgba8 = struct {};
    pub const RgbaF32 = struct {};
    pub const Bc7 = struct {
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
    };

    rgba_u8: Rgba8,
    rgba_srgb_u8: Rgba8,
    rgba_f32: RgbaF32,
    bc7: Bc7,
    bc7_srgb: Bc7,
};

buf: []u8,
allocator: Allocator,

pub fn init(
    gpa: Allocator,
    image: *Image,
    max_threads: ?u16,
    options: Options,
) Error!@This() {
    const search_zone = Zone.begin(.{ .src = @src() });
    defer search_zone.end();
    defer image.deinit();

    const encoding: Encoding = options;
    switch (options) {
        .rgba_u8, .rgba_srgb_u8 => {
            const u8_zone = Zone.begin(.{ .name = "u8", .src = @src() });
            defer u8_zone.end();
            const buf = b: {
                const alloc_zone = Zone.begin(.{ .name = "alloc", .src = @src() });
                defer alloc_zone.end();
                break :b try gpa.alloc(u8, image.data.len);
            };
            const encode_zone = Zone.begin(.{ .name = "encode", .src = @src() });
            defer encode_zone.end();
            for (0..@as(usize, image.width) * @as(usize, image.height) * 4) |i| {
                var ldr = image.data[i];
                if (encoding.colorSpace() == .srgb and i % 4 != 3) {
                    ldr = std.math.pow(f32, ldr, 1.0 / 2.2);
                }
                ldr = std.math.clamp(ldr * 255.0 + 0.5, 0.0, 255.0);
                buf[i] = @intFromFloat(ldr);
            }
            return .{
                .buf = buf,
                .allocator = gpa,
            };
        },
        .rgba_f32 => {
            const allocator = image.allocator;
            const buf = image.toOwned().data;
            return .{
                .buf = std.mem.sliceAsBytes(buf),
                .allocator = allocator,
            };
        },
        .bc7, .bc7_srgb => |eo| {
            const bc7_zone = Zone.begin(.{ .name = "bc7", .src = @src() });
            defer bc7_zone.end();

            // Determine the bc7 params
            var params: Bc7Enc.Params = .{};
            {
                const params_zone = Zone.begin(.{ .name = "params", .src = @src() });
                defer params_zone.end();

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
                params.perceptual = encoding.colorSpace() == .srgb;
                params.mode6_only = eo.mode_6_only;

                if (max_threads) |v| {
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

            // Encode the image
            const bc7_encoder = b: {
                const init_zone = Zone.begin(.{ .name = "init", .src = @src() });
                defer init_zone.end();
                break :b Bc7Enc.init() orelse return error.EncoderFailed;
            };

            {
                const encode_zone = Zone.begin(.{ .name = "encode", .src = @src() });
                defer encode_zone.end();
                if (!bc7_encoder.encode(&params, image.width, image.height, image.data.ptr)) {
                    return error.EncoderFailed;
                }
            }

            return .{
                .buf = bc7_encoder.getBlocks(),
                .allocator = bc7EncAllocator(bc7_encoder),
            };
        },
    }
}

pub fn deinit(self: *@This()) void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.allocator.free(self.buf);
    _ = self.toOwned();
}

pub fn toOwned(self: *@This()) @This() {
    const owned = self.*;
    self.buf = &.{};
    self.allocator = moved_allocator;
    return owned;
}

pub const Bc7Enc = opaque {
    pub const Params = extern struct {
        pub const max_partitions = 64;
        pub const max_uber_level = 4;
        pub const max_level = 18;
        pub const min_lookback_window_size = 8;

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

fn bc7EncFree(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
    _ = buf_align;
    _ = ret_addr;
    _ = buf;
    const bc7_encoder: *Bc7Enc = @ptrCast(ctx);
    bc7_encoder.deinit();
}

fn bc7EncAllocator(bc7_encoder: *Bc7Enc) Allocator {
    return .{
        .ptr = bc7_encoder,
        .vtable = &.{
            .alloc = &unsupportedAlloc,
            .resize = &unsupportedResize,
            .free = &bc7EncFree,
        },
    };
}

fn movedFree(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
    _ = ctx;
    _ = buf_align;
    _ = ret_addr;
    _ = buf;
}

const moved_allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = &unsupportedAlloc,
        .resize = &unsupportedResize,
        .free = &movedFree,
    },
};
