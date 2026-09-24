const std = @import("std");

const fangz = @import("fangz");

const bundle = @import("bundle.zig");
const info = @import("info.zig");
const install = @import("install.zig");
const list = @import("list.zig");
const support = @import("support.zig");
const uninstall = @import("uninstall.zig");
const update = @import("update.zig");

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

    const root = app.root();
    root.setHelpOnEmptyArgs(true);

    try bundle.register(root);
    try info.register(root);
    try install.register(root);
    try list.register(root);
    try update.register(root);
    try uninstall.register(root);

    try app.executeProcess(init.minimal.args);
}

test {
    std.testing.refAllDecls(@This());
}
