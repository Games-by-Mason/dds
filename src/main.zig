const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Dds = @import("Dds");
const structopt = @import("structopt");
const Command = structopt.Command;
const NamedArg = structopt.NamedArg;
const PositionalArg = structopt.PositionalArg;
const log = std.log;

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("lodepng.h");
});

const max_file_len = 4294967296;

const Format = enum {
    auto,
    rgb,
    rgba,
};

const command: Command = .{
    .name = "dds",
    .description = "Converts PNG to DDS.",
    .named_args = &.{
        NamedArg.init(Format, .{
            .long = "format",
            .default = .{ .value = .auto },
        }),
    },
    .positional_args = &.{
        PositionalArg.init([]const u8, .{
            .meta = "INPUT",
        }),
        PositionalArg.init([]const u8, .{
            .meta = "OUTPUT",
        }),
    },
};

pub fn main() !void {
    // Setup
    defer std.process.cleanExit();

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var arg_iter = std.process.argsWithAllocator(allocator) catch @panic("OOM");
    defer arg_iter.deinit();
    const args = command.parseOrExit(allocator, &arg_iter);
    defer command.parseFree(args);

    const cwd = std.fs.cwd();

    // Load the PNG
    var input = cwd.openFile(args.INPUT, .{}) catch |err| {
        log.err("{s}: {s}", .{ args.INPUT, @errorName(err) });
        std.process.exit(1);
    };
    defer input.close();

    const input_bytes = input.readToEndAllocOptions(allocator, max_file_len, null, 1, 0) catch |err| {
        log.err("{s}: {s}", .{ args.INPUT, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(input_bytes);

    // Determine the input and output formats
    const input_alpha = b: {
        var width: c_uint = 0;
        var height: c_uint = 0;
        var state: c.LodePNGState = .{};
        assert(c.lodepng_inspect(
            &width,
            &height,
            &state,
            input_bytes.ptr,
            input_bytes.len,
        ) == 0);
        break :b c.lodepng_is_alpha_type(&state.info_png.color) != 0;
    };
    const output_alpha = switch (args.format) {
        .auto => input_alpha,
        .rgb => false,
        .rgba => b: {
            if (!input_alpha) {
                log.err("{s}: requested alpha, but none present", .{args.INPUT});
                std.process.exit(1);
            }
            break :b true;
        },
    };

    // Decode the PNG
    var uncompressed_ptr: [*c]u8 = undefined;
    var width: c_uint = 0;
    var height: c_uint = 0;
    if (c.lodepng_decode_memory(
        &uncompressed_ptr,
        &width,
        &height,
        input_bytes.ptr,
        input_bytes.len,
        if (output_alpha) c.LCT_RGBA else c.LCT_RGB,
        8,
    ) != 0) {
        log.err("{s}: lodepng failed", .{args.INPUT});
        std.process.exit(1);
    }
    defer c.free(uncompressed_ptr);
    const uncompressed = if (output_alpha) uncompressed_ptr[0 .. width * height * 4] else uncompressed_ptr[0 .. width * height * 3];

    var output = cwd.createFile(args.OUTPUT, .{}) catch |err| {
        log.err("{s}: {s}", .{ args.OUTPUT, @errorName(err) });
        std.process.exit(1);
    };
    defer {
        output.sync() catch |err| @panic(@errorName(err));
        output.close();
    }

    // Write the DDS file
    {
        // Write the four character code
        output.writeAll("DDS ") catch |err| {
            log.err("{s}: {s}", .{ args.OUTPUT, @errorName(err) });
            std.process.exit(1);
        };

        // Write the header
        comptime assert(builtin.cpu.arch.endian() == .little);
        const header: Dds.Header = .{
            .height = height,
            .width = width,
            .ddspf = .{
                .flags = .{
                    .alphapixels = output_alpha,
                    .rgb = true,
                },
                .rgb_bit_count = if (output_alpha) 32 else 24,
                .r_bit_mask = 0x00ff0000,
                .g_bit_mask = 0x0000ff00,
                .b_bit_mask = 0x000000ff,
                .a_bit_mask = 0xff000000,
            },
        };
        output.writeAll(std.mem.asBytes(&header)) catch |err| {
            log.err("{s}: {s}", .{ args.OUTPUT, @errorName(err) });
            std.process.exit(1);
        };

        // Write the pixels
        output.writeAll(uncompressed) catch |err| {
            log.err("{s}: {s}", .{ args.OUTPUT, @errorName(err) });
            std.process.exit(1);
        };
    }
}
