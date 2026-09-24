const std = @import("std");

const fangz = @import("fangz");

const root_cmd = @import("commands/root.zig");
const support = @import("support.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    support.process_environ = init.minimal.environ;

    var app = try fangz.App.init(allocator, io, .{
        .display_name = "Typst Package Manager",
        .tagline = "A CLI for managing and bundling Typst packages",
        .brief = "Install, bundle, and manage Typst packages and templates.",
        .description =
        \\typm resolves packages from Git (GitHub, GitLab, Bitbucket, or a full URL), validates them against their typst.toml manifest, and installs them into Typst's local package data directory so they can be imported by namespace.
        \\
        \\Run `typm help <command>` for details on a specific command.
        ,
    });
    defer app.deinit();

    try root_cmd.register(app.root());
    try app.executeProcess(init.minimal.args);
}

test {
    std.testing.refAllDecls(@This());
}
