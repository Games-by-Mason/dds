const std = @import("std");
const Allocator = std.mem.Allocator;
const tracy = @import("tracy");
const Zone = tracy.Zone;
const EncodedImage = @import("EncodedImage.zig");

pub const Error = error{
    OutOfMemory,
    UnfinishedBits,
};

pub const Options = union(enum) {
    pub const Zlib = struct {
        level: std.compress.flate.deflate.Level,
    };

    zlib: Zlib,
    none: void,
};

uncompressed_len: u64,
buf: []const u8,
allocator: Allocator,

pub fn init(gpa: Allocator, uncompressed: *EncodedImage, options: Options) Error!@This() {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    defer uncompressed.deinit();

    switch (options) {
        .none => {
            const allocator = uncompressed.allocator;
            const buf = uncompressed.toOwned().buf;
            return .{
                .uncompressed_len = buf.len,
                .buf = buf,
                .allocator = allocator,
            };
        },
        .zlib => |zlib_options| {
            const zlib_zone = Zone.begin(.{ .name = "zlib", .src = @src() });
            defer zlib_zone.end();

            var compressed = b: {
                const alloc_zone = Zone.begin(.{ .name = "alloc", .src = @src() });
                defer alloc_zone.end();
                break :b try std.ArrayListUnmanaged(u8).initCapacity(gpa, uncompressed.buf.len);
            };
            defer compressed.deinit(gpa);

            const Compressor = std.compress.flate.deflate.Compressor(
                .zlib,
                @TypeOf(compressed).Writer,
            );
            var compressor = try Compressor.init(
                compressed.writer(gpa),
                .{ .level = zlib_options.level },
            );
            _ = try compressor.write(uncompressed.buf);
            try compressor.finish();

            return .{
                .uncompressed_len = uncompressed.buf.len,
                .buf = b: {
                    const to_owned_zone = Zone.begin(.{ .name = "toOwnedSlice", .src = @src() });
                    defer to_owned_zone.end();
                    break :b try compressed.toOwnedSlice(gpa);
                },
                .allocator = gpa,
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
    self.uncompressed_len = 0;
    self.allocator = moved_allocator;
    self.buf = &.{};
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
