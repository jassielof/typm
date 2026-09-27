const std = @import("std");

const fangz = @import("fangz");

const support = @import("support.zig");
const Typst = @import("Typst.zig");

const VersionInfo = struct {
    version: []const u8,
    description: []const u8,
};

pub fn register(root: *fangz.Command) !void {
    const cmd = try root.addSubcommand(.{
        .name = "list",
        .brief = "List installed Typst packages.",
        .description =
        \\Lists packages from the Typst data directory (installed via `typm install`) and the Typst Universe cache, grouped by namespace, with all installed versions and a description sourced from the newest available typst.toml. Shows both by default.
        ,
    });

    try cmd.addFlag(bool, .{
        .name = "universe",
        .brief = "List only Universe (cache) packages installed from Typst Universe.",
    });

    try cmd.addFlag(bool, .{
        .name = "local",
        .brief = "List only packages from the data directory.",
    });

    try cmd.addFlag(?[]const u8, .{
        .name = "namespace",
        .brief = "Filter packages by namespace.",
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
        const packages_root = try Typst.getPackageDir(
            allocator,
            support.process_environ,
            .data,
        );
        try printHeading(ctx.io, "Data Packages");
        _ = try listPackagesInRoot(
            allocator,
            ctx.io,
            packages_root,
            "data",
            namespace,
        );
    }

    if (want_universe or list_all) {
        const packages_root = try Typst.getPackageDir(
            allocator,
            support.process_environ,
            .cache,
        );
        try printHeading(ctx.io, "Cache Packages");
        _ = try listPackagesInRoot(
            allocator,
            ctx.io,
            packages_root,
            "cache",
            namespace,
        );
    }
}

fn printHeading(io: std.Io, title: []const u8) !void {
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    try stdout_writer.interface.print("\n{s}\n", .{title});
    try stdout_writer.interface.flush();
}

/// Prints every package under `packages_root_dir` (laid out as `<namespace>/<name>/<version>`), returning how many versions were found.
fn listPackagesInRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    packages_root_dir: []const u8,
    root_type: []const u8,
    filter_namespace: ?[]const u8,
) !usize {
    if (!support.dirExists(io, packages_root_dir)) {
        try printMissingRoot(
            io,
            root_type,
            packages_root_dir,
        );

        return 0;
    }

    var count: usize = 0;
    var root_dir = try std.Io.Dir.cwd().openDir(
        io,
        packages_root_dir,
        .{ .iterate = true },
    );
    defer root_dir.close(io);

    var ns_iter = root_dir.iterate();
    while (try ns_iter.next(io)) |ns_entry| {
        if (!isWantedNamespace(ns_entry, filter_namespace)) {
            continue;
        }

        count += try listNamespace(
            allocator,
            io,
            packages_root_dir,
            ns_entry.name,
        );
    }

    if (count == 0) try printNoPackages(
        io,
        root_type,
        filter_namespace,
    );

    return count;
}

/// A namespace directory is listed unless a namespace filter was given and names another one.
fn isWantedNamespace(entry: std.Io.Dir.Entry, filter_namespace: ?[]const u8) bool {
    if (entry.kind != .directory) {
        return false;
    }

    const expected = filter_namespace orelse return true;

    return std.mem.eql(
        u8,
        entry.name,
        expected,
    );
}

fn listNamespace(
    allocator: std.mem.Allocator,
    io: std.Io,
    packages_root_dir: []const u8,
    namespace: []const u8,
) !usize {
    const namespace_path = try std.fs.path.join(allocator, &.{ packages_root_dir, namespace });
    defer allocator.free(namespace_path);

    var namespace_dir = try std.Io.Dir.cwd().openDir(
        io,
        namespace_path,
        .{ .iterate = true },
    );
    defer namespace_dir.close(io);

    var count: usize = 0;
    var pkg_iter = namespace_dir.iterate();
    while (try pkg_iter.next(io)) |pkg_entry| {
        if (pkg_entry.kind != .directory) {
            continue;
        }

        count += try listPackage(
            allocator,
            io,
            namespace_path,
            namespace,
            pkg_entry.name,
        );
    }

    return count;
}

/// Prints one package with all its installed versions, newest first, and returns how many versions it has.
fn listPackage(
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace_path: []const u8,
    namespace: []const u8,
    package_name: []const u8,
) !usize {
    const package_path = try std.fs.path.join(allocator, &.{ namespace_path, package_name });
    defer allocator.free(package_path);

    var package_dir = try std.Io.Dir.cwd().openDir(
        io,
        package_path,
        .{ .iterate = true },
    );
    defer package_dir.close(io);

    var versions = std.ArrayList(VersionInfo).empty;
    defer versions.deinit(allocator);

    var version_iter = package_dir.iterate();
    while (try version_iter.next(io)) |version_entry| {
        if (version_entry.kind != .directory) {
            continue;
        }

        try versions.append(allocator, try readVersionInfo(
            allocator,
            io,
            package_path,
            version_entry.name,
        ));
    }

    if (versions.items.len == 0) {
        return 0;
    }

    sortVersionsDescending(versions.items);
    try printPackageSummary(
        io,
        namespace,
        package_name,
        versions.items,
    );

    return versions.items.len;
}

fn readVersionInfo(
    allocator: std.mem.Allocator,
    io: std.Io,
    package_path: []const u8,
    version_name: []const u8,
) !VersionInfo {
    const version_path = try std.fs.path.join(allocator, &.{ package_path, version_name });
    defer allocator.free(version_path);

    return .{
        .version = try allocator.dupe(u8, version_name),
        .description = try getPackageDescription(
            allocator,
            io,
            version_path,
        ),
    };
}

fn printMissingRoot(
    io: std.Io,
    root_type: []const u8,
    packages_root_dir: []const u8,
) !void {
    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    try stdout_writer.interface.print("  No packages found in {s} directory ({s} does not exist).\n", .{ root_type, packages_root_dir });
    try stdout_writer.interface.flush();
}

fn printNoPackages(
    io: std.Io,
    root_type: []const u8,
    filter_namespace: ?[]const u8,
) !void {
    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    if (filter_namespace) |namespace| {
        try stdout_writer.interface.print("  No {s} packages found with namespace '{s}'.\n", .{ root_type, namespace });
    } else {
        try stdout_writer.interface.print("  No {s} packages found.\n", .{root_type});
    }

    try stdout_writer.interface.flush();
}

fn getPackageDescription(
    allocator: std.mem.Allocator,
    io: std.Io,
    version_dir: []const u8,
) ![]const u8 {
    const toml_path = try std.fs.path.join(allocator, &.{ version_dir, "typst.toml" });
    if (!support.fileExists(io, toml_path)) {
        return allocator.dupe(u8, "");
    }

    const cfg = support.readPackageFile(
        allocator,
        io,
        toml_path,
    ) catch return allocator.dupe(u8, "");

    return allocator.dupe(u8, (cfg.package orelse support.PackageSection{}).description orelse "");
}

fn printPackageSummary(
    io: std.Io,
    namespace: []const u8,
    package_name: []const u8,
    versions: []const VersionInfo,
) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);

    try stdout_writer.interface.print("  @{s}/{s}\n", .{ namespace, package_name });
    try stdout_writer.interface.print("    Versions: ", .{});
    for (versions, 0..) |version, index| {
        if (index != 0) {
            try stdout_writer.interface.print(", ", .{});
        }

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
        if (version.description.len > 0) {
            return version.description;
        }
    }

    return "";
}

fn sortVersionsDescending(items: []VersionInfo) void {
    const Sort = struct {
        fn less(
            _: void,
            a: VersionInfo,
            b: VersionInfo,
        ) bool {
            const pa = std.SemanticVersion.parse(a.version) catch {
                const pb = std.SemanticVersion.parse(b.version) catch {
                    return std.mem.order(
                        u8,
                        b.version,
                        a.version,
                    ) == .lt;
                };

                _ = pb;

                return false;
            };

            const pb = std.SemanticVersion.parse(b.version) catch return true;

            return std.SemanticVersion.order(pa, pb) == .gt;
        }
    };

    std.mem.sort(
        VersionInfo,
        items,
        {},
        Sort.less,
    );
}
