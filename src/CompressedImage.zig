const std = @import("std");
const tracy = @import("tracy");
const Zone = tracy.Zone;

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

owned: bool,
buf: []const u8,

pub fn init(gpa: std.mem.Allocator, bytes: []const u8, options: Options) Error!@This() {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    switch (options) {
        .none => return .{
            .owned = false,
            .buf = bytes,
        },
        .zlib => |zlib_options| {
            const zlib_zone = Zone.begin(.{ .name = "zlib", .src = @src() });
            defer zlib_zone.end();

            var compressed = b: {
                const alloc_zone = Zone.begin(.{ .name = "alloc", .src = @src() });
                defer alloc_zone.end();
                break :b try std.ArrayListUnmanaged(u8).initCapacity(
                    gpa,
                    bytes.len,
                );
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
            _ = try compressor.write(bytes);
            try compressor.finish();

            return .{
                .owned = true,
                .buf = b: {
                    const to_owned_zone = Zone.begin(.{ .name = "toOwnedSlice", .src = @src() });
                    defer to_owned_zone.end();
                    break :b try compressed.toOwnedSlice(gpa);
                },
            };
        },
    }
}

pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    if (self.owned) gpa.free(self.buf);
}
