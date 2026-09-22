const std = @import("std");
const fangz = @import("fangz");

const support = @import("../support.zig");

const VersionInfo = struct {
    version: []const u8,
    description: []const u8,
};

pub fn register(root: *fangz.Command) !void {
    const cmd = try root.addSubcommand(.{
        .name = "list",
        .description = "List installed Typst packages.",
    });

    try cmd.addFlag(bool, .{
        .name = "universe",
        .description = "List only Universe (cache) packages installed from Typst Universe.",
    });

    try cmd.addFlag(bool, .{
        .name = "local",
        .description = "List only packages from the data directory.",
    });

    try cmd.addFlag(?[]const u8, .{
        .name = "namespace",
        .description = "Filter packages by namespace.",
    });

    cmd.setHooks(.{ .run = run });
}

fn run(ctx: *fangz.ParseContext) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const want_local = ctx.boolFlag("local") orelse false;
    const want_universe = ctx.boolFlag("universe") orelse false;
    const namespace = ctx.stringFlag("namespace");
    const list_all = !want_local and !want_universe;

    if (want_local or list_all) {
        const data_dir = try support.typstDataDir(allocator);
        const packages_root = try std.fs.path.join(allocator, &.{ data_dir, "packages" });
        try printHeading("Data Packages");
        _ = try listPackagesInRoot(allocator, packages_root, "data", namespace);
    }

    if (want_universe or list_all) {
        const cache_dir = try support.typstCacheDir(allocator);
        const packages_root = try std.fs.path.join(allocator, &.{ cache_dir, "packages" });
        try printHeading("Cache Packages");
        _ = try listPackagesInRoot(allocator, packages_root, "cache", namespace);
    }
}

fn printHeading(title: []const u8) !void {
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout_writer.interface.print("\n{s}\n", .{title});
    try stdout_writer.interface.flush();
}

fn listPackagesInRoot(allocator: std.mem.Allocator, packages_root_dir: []const u8, root_type: []const u8, filter_namespace: ?[]const u8) !usize {
    if (!support.dirExists(packages_root_dir)) {
        var stdout_buffer: [512]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        try stdout_writer.interface.print("  No packages found in {s} directory ({s} does not exist).\n", .{ root_type, packages_root_dir });
        try stdout_writer.interface.flush();
        return 0;
    }

    var count: usize = 0;
    var root_dir = try std.fs.cwd().openDir(packages_root_dir, .{ .iterate = true });
    defer root_dir.close();

    var ns_iter = root_dir.iterate();
    while (try ns_iter.next()) |ns_entry| {
        if (ns_entry.kind != .directory) continue;
        const namespace = ns_entry.name;
        if (filter_namespace) |expected| {
            if (!std.mem.eql(u8, namespace, expected)) continue;
        }

        const namespace_path = try std.fs.path.join(allocator, &.{ packages_root_dir, namespace });
        defer allocator.free(namespace_path);
        var namespace_dir = try std.fs.cwd().openDir(namespace_path, .{ .iterate = true });
        defer namespace_dir.close();

        var pkg_iter = namespace_dir.iterate();
        while (try pkg_iter.next()) |pkg_entry| {
            if (pkg_entry.kind != .directory) continue;
            const package_name = pkg_entry.name;
            const package_path = try std.fs.path.join(allocator, &.{ namespace_path, package_name });
            defer allocator.free(package_path);

            var package_dir = try std.fs.cwd().openDir(package_path, .{ .iterate = true });
            defer package_dir.close();

            var versions = std.ArrayList(VersionInfo).empty;
            defer versions.deinit(allocator);

            var version_iter = package_dir.iterate();
            while (try version_iter.next()) |version_entry| {
                if (version_entry.kind != .directory) continue;
                const version_path = try std.fs.path.join(allocator, &.{ package_path, version_entry.name });
                defer allocator.free(version_path);

                const description = try getPackageDescription(allocator, version_path);
                try versions.append(allocator, .{
                    .version = try allocator.dupe(u8, version_entry.name),
                    .description = description,
                });
                count += 1;
            }

            if (versions.items.len == 0) continue;
            sortVersionsDescending(versions.items);
            try printPackageSummary(namespace, package_name, versions.items);
        }
    }

    if (count == 0) {
        var stdout_buffer: [512]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        if (filter_namespace) |namespace| {
            try stdout_writer.interface.print("  No {s} packages found with namespace '{s}'.\n", .{ root_type, namespace });
        } else {
            try stdout_writer.interface.print("  No {s} packages found.\n", .{root_type});
        }
        try stdout_writer.interface.flush();
    }

    return count;
}

fn getPackageDescription(allocator: std.mem.Allocator, version_dir: []const u8) ![]const u8 {
    const toml_path = try std.fs.path.join(allocator, &.{ version_dir, "typst.toml" });
    if (!support.fileExists(toml_path)) return allocator.dupe(u8, "");

    const cfg = support.readPackageFile(allocator, toml_path) catch return allocator.dupe(u8, "");
    return allocator.dupe(u8, (cfg.package orelse support.PackageSection{}).description orelse "");
}

fn printPackageSummary(namespace: []const u8, package_name: []const u8, versions: []const VersionInfo) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);

    try stdout_writer.interface.print("  @{s}/{s}\n", .{ namespace, package_name });
    try stdout_writer.interface.print("    Versions: ", .{});
    for (versions, 0..) |version, index| {
        if (index != 0) try stdout_writer.interface.print(", ", .{});
        try stdout_writer.interface.print("{s}", .{version.version});
    }
    try stdout_writer.interface.print("\n", .{});

    const description = bestDescription(versions);
    if (description.len > 0) {
        try stdout_writer.interface.print("    Description: {s}\n", .{description});
    }
    try stdout_writer.interface.flush();
}

fn bestDescription(versions: []const VersionInfo) []const u8 {
    for (versions) |version| {
        if (version.description.len > 0) return version.description;
    }
    return "";
}

fn sortVersionsDescending(items: []VersionInfo) void {
    const Sort = struct {
        fn less(_: void, a: VersionInfo, b: VersionInfo) bool {
            const pa = std.SemanticVersion.parse(a.version) catch {
                const pb = std.SemanticVersion.parse(b.version) catch {
                    return std.mem.order(u8, b.version, a.version) == .lt;
                };
                _ = pb;
                return false;
            };
            const pb = std.SemanticVersion.parse(b.version) catch return true;
            return std.SemanticVersion.order(pa, pb) == .gt;
        }
    };
    std.mem.sort(VersionInfo, items, {}, Sort.less);
}
