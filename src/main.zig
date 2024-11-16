const std = @import("std");
const dds = @import("dds");
const structopt = @import("structopt");
const Command = structopt.Command;
const PositionalArg = structopt.PositionalArg;
const log = std.log;

const max_file_len = 4294967296;

const command: Command = .{
    .name = "dds",
    .description = "Converts PNGs to uncompressed DDS files.",
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
    defer std.process.cleanExit();

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var arg_iter = std.process.argsWithAllocator(allocator) catch @panic("OOM");
    defer arg_iter.deinit();
    const args = command.parseOrExit(allocator, &arg_iter);
    defer command.parseFree(args);

    const cwd = std.fs.cwd();

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

    var output = cwd.createFile(args.OUTPUT, .{}) catch |err| {
        log.err("{s}: {s}", .{ args.OUTPUT, @errorName(err) });
        std.process.exit(1);
    };
    defer {
        output.sync() catch |err| @panic(@errorName(err));
        output.close();
    }
    output.writeAll(input_bytes) catch |err| {
        log.err("{s}: {s}", .{ args.OUTPUT, @errorName(err) });
        std.process.exit(1);
    };
}
