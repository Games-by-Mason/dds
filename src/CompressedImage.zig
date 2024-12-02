pub const std = @import("std");

pub const Error = error{
    OutOfMemory,
    // XXX: ?? remove from parent if remove here
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
    switch (options) {
        .none => return .{
            .owned = false,
            .buf = bytes,
        },
        .zlib => |zlib_options| {
            var compressed = try std.ArrayListUnmanaged(u8).initCapacity(
                gpa,
                bytes.len,
            );
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
                .buf = try compressed.toOwnedSlice(gpa),
            };
        },
    }
}

pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
    if (self.owned) gpa.free(self.buf);
}
