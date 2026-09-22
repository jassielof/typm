const std = @import("std");
const fangz = @import("fangz");

const support = @import("../support.zig");

pub fn register(root: *fangz.Command) !void {
    const cmd = try root.addSubcommand(.{
        .name = "uninstall",
        .description = "Remove a package from the Typst data directory (local installs).",
    });

    try cmd.addPositional(.{
        .name = "package",
        .description = "Installed package as namespace/name (e.g. gh-user/repo).",
        .required = true,
    });

    try cmd.addFlag(?[]const u8, .{
        .name = "version",
        .short = 'v',
        .description = "Remove only this version; omit to remove all installed versions.",
    });

    cmd.setHooks(.{ .run = run });
}

fn run(ctx: *fangz.ParseContext) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const spec = ctx.positional(0) orelse return error.MissingRequiredPositional;
    const version_only = ctx.stringFlag("version");

    const slash_opt = std.mem.indexOfScalar(u8, spec, '/');
    const slash = slash_opt orelse {
        support.failWithDetail("Package must be namespace/name (exactly one slash), got:", spec);
    };
    if (slash == 0 or slash + 1 >= spec.len or std.mem.indexOfScalar(u8, spec[slash + 1 ..], '/') != null) {
        support.failWithDetail("Package must be namespace/name (exactly one slash), got:", spec);
    }

    const namespace = spec[0..slash];
    const name = spec[slash + 1 ..];

    if (std.mem.indexOf(u8, namespace, "..") != null or std.mem.indexOf(u8, name, "..") != null) {
        support.failWithDetail("Invalid package spec:", spec);
    }

    const data_dir = try support.typstDataDir(allocator);
    defer allocator.free(data_dir);

    if (version_only) |ver| {
        const target = try std.fs.path.join(allocator, &.{ data_dir, "packages", namespace, name, ver });
        defer allocator.free(target);
        if (!support.dirExists(target)) {
            support.failWithDetail("No such installed version:", target);
        }
        try std.fs.cwd().deleteTree(target);
        var stdout_buffer: [512]u8 = undefined;
        var w = std.fs.File.stdout().writer(&stdout_buffer);
        try w.interface.print("Removed version {s} of @{s}/{s}.\n", .{ ver, namespace, name });
        try w.interface.flush();
        return;
    }

    const package_dir = try std.fs.path.join(allocator, &.{ data_dir, "packages", namespace, name });
    defer allocator.free(package_dir);
    if (!support.dirExists(package_dir)) {
        support.failWithDetail("Package is not installed:", spec);
    }
    try std.fs.cwd().deleteTree(package_dir);

    var stdout_buffer: [512]u8 = undefined;
    var w = std.fs.File.stdout().writer(&stdout_buffer);
    try w.interface.print("Removed all versions of @{s}/{s}.\n", .{ namespace, name });
    try w.interface.flush();
}
