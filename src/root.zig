const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

pub const four_cc = "DDS ".*;

pub const Header = extern struct {
    pub const PixelFormat = extern struct {
        const Flags = packed struct(u32) {
            alphapixels: bool = false,
            alpha: bool = false,
            four_cc: bool = false,
            _padding0: u3 = 0,
            rgb: bool = false,
            _padding1: u2 = 0,
            yuv: bool = false,
            _padding2: u7 = 0,
            luminance: bool = false,
            _padding3: u14 = 0,
        };

        size: u32 = @sizeOf(PixelFormat),
        flags: @This().Flags = .{},
        four_cc: [4]u8 = .{0} ** 4,
        rgb_bit_count: u32 = 0,
        r_bit_mask: u32 = 0,
        g_bit_mask: u32 = 0,
        b_bit_mask: u32 = 0,
        a_bit_mask: u32 = 0,
    };

    pub const Flags = packed struct(u32) {
        caps: bool = true,
        height: bool = true,
        width: bool = true,
        pitch: bool = false,
        _padding0: u7 = 0,
        pixelformat: bool = true,
        _padding1: u4 = 0,
        mipmapcount: bool = false,
        _padding2: u1 = 0,
        linearsize: bool = false,
        _padding3: u3 = 0,
        depth: bool = false,
        _padding4: u9 = 0,
    };

    pub const Caps = packed struct(u32) {
        _padding0: u3 = 0,
        complex: bool = false,
        _padding1: u8 = 0,
        texture: bool = true,
        _padding2: u8 = 0,
        mipmap: bool = false,
        _padding3: u10 = 0,
    };

    pub const Caps2 = packed struct(u32) {
        _padding0: u8 = 0,
        cubemap: bool = false,
        cubemap_positivex: bool = false,
        cubemap_negativex: bool = false,
        cubemap_positivey: bool = false,
        cubemap_negativey: bool = false,
        cubemap_positivez: bool = false,
        cubemap_negativez: bool = false,
        _padding1: u5 = 0,
        volume: bool = false,
        _padding2: u11 = 0,
    };

    size: u32 = @sizeOf(Header),
    flags: Flags = .{},
    height: u32,
    width: u32,
    pitch_or_linear_size: u32 = 0,
    depth: u32 = 0,
    mip_map_count: u32 = 0,
    reserved1: [11]u32 = .{0} ** 11,
    ddspf: PixelFormat,
    caps: Caps = .{},
    caps2: Caps2 = .{},
    _caps3: u32 = 0,
    _caps4: u32 = 0,
    reserved2: u32 = 0,
};

pub const Dxt10 = extern struct {
    pub const four_cc = "DX10".*;

    pub const DxgiFormat = enum(u32) {
        unknown = 0,
        r32g32b32a32_typeless = 1,
        r32g32b32a32_float = 2,
        r32g32b32a32_uint = 3,
        r32g32b32a32_sint = 4,
        r32g32b32_typeless = 5,
        r32g32b32_float = 6,
        r32g32b32_uint = 7,
        r32g32b32_sint = 8,
        r16g16b16a16_typeless = 9,
        r16g16b16a16_float = 10,
        r16g16b16a16_unorm = 11,
        r16g16b16a16_uint = 12,
        r16g16b16a16_snorm = 13,
        r16g16b16a16_sint = 14,
        r32g32_typeless = 15,
        r32g32_float = 16,
        r32g32_uint = 17,
        r32g32_sint = 18,
        r32g8x24_typeless = 19,
        d32_float_s8x24_uint = 20,
        r32_float_x8x24_typeless = 21,
        x32_typeless_g8x24_uint = 22,
        r10g10b10a2_typeless = 23,
        r10g10b10a2_unorm = 24,
        r10g10b10a2_uint = 25,
        r11g11b10_float = 26,
        r8g8b8a8_typeless = 27,
        r8g8b8a8_unorm = 28,
        r8g8b8a8_unorm_srgb = 29,
        r8g8b8a8_uint = 30,
        r8g8b8a8_snorm = 31,
        r8g8b8a8_sint = 32,
        r16g16_typeless = 33,
        r16g16_float = 34,
        r16g16_unorm = 35,
        r16g16_uint = 36,
        r16g16_snorm = 37,
        r16g16_sint = 38,
        r32_typeless = 39,
        d32_float = 40,
        r32_float = 41,
        r32_uint = 42,
        r32_sint = 43,
        r24g8_typeless = 44,
        d24_unorm_s8_uint = 45,
        r24_unorm_x8_typeless = 46,
        x24_typeless_g8_uint = 47,
        r8g8_typeless = 48,
        r8g8_unorm = 49,
        r8g8_uint = 50,
        r8g8_snorm = 51,
        r8g8_sint = 52,
        r16_typeless = 53,
        r16_float = 54,
        d16_unorm = 55,
        r16_unorm = 56,
        r16_uint = 57,
        r16_snorm = 58,
        r16_sint = 59,
        r8_typeless = 60,
        r8_unorm = 61,
        r8_uint = 62,
        r8_snorm = 63,
        r8_sint = 64,
        a8_unorm = 65,
        r1_unorm = 66,
        r9g9b9e5_sharedexp = 67,
        r8g8_b8g8_unorm = 68,
        g8r8_g8b8_unorm = 69,
        bc1_typeless = 70,
        bc1_unorm = 71,
        bc1_unorm_srgb = 72,
        bc2_typeless = 73,
        bc2_unorm = 74,
        bc2_unorm_srgb = 75,
        bc3_typeless = 76,
        bc3_unorm = 77,
        bc3_unorm_srgb = 78,
        bc4_typeless = 79,
        bc4_unorm = 80,
        bc4_snorm = 81,
        bc5_typeless = 82,
        bc5_unorm = 83,
        bc5_snorm = 84,
        b5g6r5_unorm = 85,
        b5g5r5a1_unorm = 86,
        b8g8r8a8_unorm = 87,
        b8g8r8x8_unorm = 88,
        r10g10b10_xr_bias_a2_unorm = 89,
        b8g8r8a8_typeless = 90,
        b8g8r8a8_unorm_srgb = 91,
        b8g8r8x8_typeless = 92,
        b8g8r8x8_unorm_srgb = 93,
        bc6h_typeless = 94,
        bc6h_uf16 = 95,
        bc6h_sf16 = 96,
        bc7_typeless = 97,
        bc7_unorm = 98,
        bc7_unorm_srgb = 99,
        ayuv = 100,
        y410 = 101,
        y416 = 102,
        nv12 = 103,
        p010 = 104,
        p016 = 105,
        @"420_opaque" = 106,
        yuy2 = 107,
        y210 = 108,
        y216 = 109,
        nv11 = 110,
        ai44 = 111,
        ia44 = 112,
        p8 = 113,
        a8p8 = 114,
        b4g4r4a4_unorm = 115,
        p208 = 130,
        v208 = 131,
        v408 = 132,
        /// Not supported by encoder
        sampler_feedback_min_mip_opaque = 133,
        /// Not supported by encoder
        sampler_feedback_mip_region_used_opaque = 134,
        force_uint = 0xffffffff,
        _,
    };

    pub const ResourceDimension = enum(u32) {
        unknown = 0,
        buffer = 1,
        texture_1d = 2,
        texture_2d = 3,
        texture_3d = 4,
        _,
    };

    pub const MiscFlags = packed struct(u32) {
        _padding0: u2 = 0,
        texture_cube: bool = false,
        _padding: u29 = 0,
    };

    pub const MiscFlags2 = packed struct(u32) {
        straight: bool = false,
        premultiplied: bool = false,
        @"opaque": bool = false,
        custom: bool = false,
        _padding0: u28 = 0,
    };

    dxgi_format: DxgiFormat,
    resource_dimension: ResourceDimension,
    misc_flag: MiscFlags = .{},
    array_size: u32 = 0,
    misc_flags_2: MiscFlags2 = .{},
};

header: *const Header,
dxt10: ?*const Dxt10,
data: []const u8,

pub const Error = error{InvalidDds};

pub fn init(bytes: []align(@alignOf(u32)) const u8) Error!@This() {
    comptime assert(builtin.cpu.arch.endian() == .little);
    if (!std.mem.eql(u8, bytes[0..four_cc.len], four_cc)) {
        return Error.InvalidDds;
    }

    const header: *const Header = @ptrCast(bytes[four_cc.len..][0..@sizeOf(Header)].ptr);
    if (header.size != @sizeOf(Header)) return Error.InvalidDds;
    if (header.ddspf.size != @sizeOf(Header.PixelFormat)) return error.InvalidDds;

    const has_dx10 = header.ddspf.flags.four_cc and std.mem.eql(u8, &header.ddspf.four_cc, "DX10");
    const dxt10: ?*const Dxt10 = if (has_dx10) b: {
        if (four_cc.len + @sizeOf(Header) + @sizeOf(Dxt10) > bytes.len) return Error.InvalidDds;
        break :b @ptrCast(bytes[four_cc.len + @sizeOf(Header) ..][0..@sizeOf(Dxt10)]);
    } else null;

    const offset = four_cc.len + @sizeOf(Header) + if (dxt10 == null) @as(usize, 0) else @sizeOf(Dxt10);
    const data = bytes[offset..];

    return .{
        .header = header,
        .dxt10 = dxt10,
        .data = data,
    };
}
