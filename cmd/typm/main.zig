const std = @import("std");
const semver = std.SemanticVersion;

const fangz = @import("fangz");

const root_cmd = @import("commands/root.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var app = try fangz.App.init(allocator, io, .{
        .display_name = "Typst Package Manager",
        .tagline = "A CLI for managing and bundling Typst packages",
    });
    defer app.deinit();

    try root_cmd.register(app.root());
    try app.executeProcess();
}

fn getTypstVersion() !semver {
    const allocator = std.heap.page_allocator;

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "typst", "--version" },
    }) catch {
        // To avoid handling errors everywhere if Typst isn't found, it would be better to check on every initial call if Typst is on path as most operations
        return error.TypstNotFound;
    };

    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term.Exited != 0) {
        std.process.exit(1);
    }

    const stdout = std.mem.trim(u8, result.stdout, "\n\r\t");

    var it = std.mem.splitScalar(u8, stdout, ' ');
    _ = it.next() orelse return error.InvalidOutput;
    const version_str = it.next() orelse return error.InvalidOutput;

    return semver.parse(version_str) catch error.InvalidSemver;
}

test {
    std.testing.refAllDecls(@This());
}
