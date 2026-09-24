const std = @import("std");
const fangz = @import("fangz");

const support = @import("../support.zig");

pub fn register(root: *fangz.Command) !void {
    const cmd = try root.addSubcommand(.{
        .name = "uninstall",
        .brief = "Remove a package from the Typst data directory (local installs).",
        .description =
        \\Deletes an installed package identified as namespace/name (as shown by `typm list`). Pass --version to remove a single version; otherwise every installed version of the package is removed. Only affects local installs, not the Typst Universe cache.
        ,
    });

    try cmd.addPositional(.{
        .name = "package",
        .brief = "Installed package as namespace/name (e.g. gh-user/repo).",
        .required = true,
    });

    try cmd.addFlag(?[]const u8, .{
        .name = "version",
        .short = 'v',
        .brief = "Remove only this version; omit to remove all installed versions.",
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
        support.failWithDetail(ctx.io, "Package must be namespace/name (exactly one slash), got:", spec);
    };
    if (slash == 0 or slash + 1 >= spec.len or std.mem.indexOfScalar(u8, spec[slash + 1 ..], '/') != null) {
        support.failWithDetail(ctx.io, "Package must be namespace/name (exactly one slash), got:", spec);
    }

    const namespace = spec[0..slash];
    const name = spec[slash + 1 ..];

    if (std.mem.indexOf(u8, namespace, "..") != null or std.mem.indexOf(u8, name, "..") != null) {
        support.failWithDetail(ctx.io, "Invalid package spec:", spec);
    }

    const data_dir = try support.typstDataDir(allocator);
    defer allocator.free(data_dir);

    if (version_only) |ver| {
        const target = try std.fs.path.join(allocator, &.{ data_dir, "packages", namespace, name, ver });
        defer allocator.free(target);
        if (!support.dirExists(ctx.io, target)) {
            support.failWithDetail(ctx.io, "No such installed version:", target);
        }
        try std.Io.Dir.cwd().deleteTree(ctx.io, target);
        var stdout_buffer: [512]u8 = undefined;
        var w = std.Io.File.stdout().writer(ctx.io, &stdout_buffer);
        try w.interface.print("Removed version {s} of @{s}/{s}.\n", .{ ver, namespace, name });
        try w.interface.flush();
        return;
    }

    const package_dir = try std.fs.path.join(allocator, &.{ data_dir, "packages", namespace, name });
    defer allocator.free(package_dir);
    if (!support.dirExists(ctx.io, package_dir)) {
        support.failWithDetail(ctx.io, "Package is not installed:", spec);
    }
    try std.Io.Dir.cwd().deleteTree(ctx.io, package_dir);

    var stdout_buffer: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(ctx.io, &stdout_buffer);
    try w.interface.print("Removed all versions of @{s}/{s}.\n", .{ namespace, name });
    try w.interface.flush();
}
