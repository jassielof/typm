const std = @import("std");

const fangz = @import("fangz");
const fugaz = @import("fugaz");

const support = @import("support.zig");
const typst = @import("typst.zig");

pub fn register(root: *fangz.Command) !void {
    const cmd = try root.addSubcommand(.{
        .name = "info",
        .brief = "Show information from an installed or remote Typst package/template.",
        .description =
        \\Looks up an already-installed package by name first. A bare name is assumed to be a locally bundled package (`bundle`'s default namespace) and resolves to its newest installed version; `namespace/name` and `namespace/name/version` also work, for any namespace. If none is found, treats the argument as a Git source (URL or alias like gh/user/repo) and clones it to inspect its manifest instead. Prints one block per typst.toml found, including the monorepo path when a repository contains more than one package.
        ,
    });

    cmd.setHelpOnEmptyArgs(true);
    cmd.setHooks(.{
        .run = run,
    });

    try cmd.addPositional(.{
        .name = "package",
        .brief = "Installed package (bare name, namespace/name, or namespace/name/version), or a Git URL/alias to inspect remotely.",
        .required = true,
    });
}

fn run(ctx: *fangz.ParseContext) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();

    const allocator = arena_state.allocator();
    const package_name = ctx.positional(0) orelse return error.MissingRequiredPositional;

    if (try tryPrintInstalledPackageInfo(
        allocator,
        ctx.io,
        package_name,
    )) {
        return;
    }

    var source = support.parseGitSource(allocator, package_name) catch {
        support.failWithDetail(
            ctx.io,
            "Invalid Git source URL or alias:",
            package_name,
        );
    };

    defer source.deinit(allocator);

    try std.Io.Dir.cwd().createDirPath(ctx.io, ".typm-tmp");
    var temp_dir = try fugaz.builder().prefix("typm-info-git-").tempDirIn(
        ctx.io,
        allocator,
        ".typm-tmp",
    );
    defer temp_dir.deinit(ctx.io);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(ctx.io, &stdout_buffer);
    try stdout_writer.interface.print("Cloning {s}...\n", .{source.repo_url_for_clone});
    try stdout_writer.interface.flush();

    try support.cloneRepository(
        allocator,
        ctx.io,
        &source,
        temp_dir.path(),
    );

    const search_dir = if (source.path_in_repo.len == 0)
        try allocator.dupe(u8, temp_dir.path())
    else
        try std.fs.path.join(allocator, &.{ temp_dir.path(), source.path_in_repo });
    defer allocator.free(search_dir);

    var toml_paths = std.ArrayList([]u8).empty;
    defer {
        for (toml_paths.items) |path| {
            allocator.free(path);
        }

        toml_paths.deinit(allocator);
    }

    try findManifests(
        allocator,
        ctx.io,
        search_dir,
        &toml_paths,
    );
    if (toml_paths.items.len == 0) {
        support.failWithDetail(
            ctx.io,
            "No typst.toml found in the cloned repository:",
            search_dir,
        );
    }

    try printManifests(
        allocator,
        ctx.io,
        temp_dir.path(),
        toml_paths.items,
    );
}

/// Collects the manifests of a cloned repository: the one directly in `search_dir`, or else every one below it.
fn findManifests(
    allocator: std.mem.Allocator,
    io: std.Io,
    search_dir: []const u8,
    out: *std.ArrayList([]u8),
) !void {
    const direct_toml = try std.fs.path.join(allocator, &.{ search_dir, "typst.toml" });
    defer allocator.free(direct_toml);

    if (support.fileExists(io, direct_toml)) {
        try out.append(allocator, try allocator.dupe(u8, direct_toml));

        return;
    }

    try support.collectTypstTomlFiles(
        allocator,
        io,
        search_dir,
        out,
    );
}

/// Prints each manifest's package info. A repository with several packages gets a heading, a blank line between entries, and each entry's path relative to `repo_root`.
fn printManifests(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    toml_paths: []const []u8,
) !void {
    const is_monorepo = toml_paths.len > 1;

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    if (is_monorepo) {
        try stdout_writer.interface.print("\nMultiple packages found in this monorepo:\n\n", .{});
        try stdout_writer.interface.flush();
    }

    for (toml_paths, 0..) |toml_path, index| {
        const rel_dir = try support.relativeParentDir(
            allocator,
            io,
            repo_root,
            toml_path,
        );
        defer allocator.free(rel_dir);

        try printPackageInfoFromToml(
            allocator,
            io,
            toml_path,
            if (is_monorepo) rel_dir else null,
        );

        if (is_monorepo and index + 1 < toml_paths.len) {
            try stdout_writer.interface.print("\n", .{});
            try stdout_writer.interface.flush();
        }
    }
}

/// The namespace `bundle` installs into when `--namespace` is not given.
const default_local_namespace = "local";

/// Resolves `package_name` to an installed package directory under `packages_root`, or null when it isn't installed.
///
/// `package_name` may be `namespace/name`, matching what `typm list` shows. A bare name (no namespace) is assumed to be a locally bundled package and is looked up as `local/name`, since that is the namespace `bundle` installs into by default. The caller owns the returned slice.
fn resolveInstalledPackageDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    packages_root: []const u8,
    package_name: []const u8,
) !?[]u8 {
    const candidate = if (std.mem.indexOfScalar(u8, package_name, '/') != null)
        try allocator.dupe(u8, package_name)
    else
        // A bare name is assumed to be a locally bundled package: `bundle` installs into the "local" namespace by default.
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ default_local_namespace, package_name });
    defer allocator.free(candidate);

    return resolvePackageOrVersionDir(allocator, io, packages_root, candidate);
}

/// `relative` (under `packages_root`) may itself be a package's directory (with typst.toml directly inside), or a namespace/name directory holding version subdirectories, in which case the newest installed version is used.
fn resolvePackageOrVersionDir(allocator: std.mem.Allocator, io: std.Io, packages_root: []const u8, relative: []const u8) !?[]u8 {
    const dir_path = try std.fs.path.join(allocator, &.{ packages_root, relative });
    defer allocator.free(dir_path);

    if (!support.dirExists(io, dir_path)) return null;

    const toml_path = try std.fs.path.join(allocator, &.{ dir_path, "typst.toml" });
    defer allocator.free(toml_path);
    if (support.fileExists(io, toml_path)) return try allocator.dupe(u8, dir_path);

    return newestVersionDir(allocator, io, dir_path);
}

/// The newest semver-named subdirectory of `package_dir`, or null when it has none.
fn newestVersionDir(allocator: std.mem.Allocator, io: std.Io, package_dir: []const u8) !?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, package_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var newest: ?std.SemanticVersion = null;
    var newest_name: ?[]u8 = null;
    errdefer if (newest_name) |name| allocator.free(name);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const version = std.SemanticVersion.parse(entry.name) catch continue;
        if (newest != null and std.SemanticVersion.order(version, newest.?) != .gt) continue;

        if (newest_name) |name| allocator.free(name);
        newest = version;
        newest_name = try allocator.dupe(u8, entry.name);
    }

    const version_name = newest_name orelse return null;
    defer allocator.free(version_name);

    return try std.fs.path.join(allocator, &.{ package_dir, version_name });
}

test "resolveInstalledPackageDir resolves a bare name to its newest local version" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "local/mypkg/0.1.0");
    try tmp.dir.createDirPath(io, "local/mypkg/0.2.0");
    try tmp.dir.createDirPath(io, "gh-typst/appreciated-letter/0.1.0");
    try tmp.dir.writeFile(io, .{ .sub_path = "local/mypkg/0.1.0/typst.toml", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "local/mypkg/0.2.0/typst.toml", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "gh-typst/appreciated-letter/0.1.0/typst.toml", .data = "" });

    const packages_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(packages_root);

    // A bare name resolves under the default "local" namespace, picking the newest version.
    const bare = try resolveInstalledPackageDir(allocator, io, packages_root, "mypkg");
    defer if (bare) |dir| allocator.free(dir);
    try std.testing.expect(bare != null);
    try std.testing.expect(std.mem.indexOf(u8, bare.?, "0.2.0") != null);

    // An explicit namespace/name (no version) is used as-is, not re-prefixed with "local", and still resolves the newest version.
    const namespaced = try resolveInstalledPackageDir(allocator, io, packages_root, "local/mypkg");
    defer if (namespaced) |dir| allocator.free(dir);
    try std.testing.expect(namespaced != null);
    try std.testing.expect(std.mem.indexOf(u8, namespaced.?, "0.2.0") != null);

    // An explicit namespace/name/version is used exactly as given.
    const exact = try resolveInstalledPackageDir(allocator, io, packages_root, "gh-typst/appreciated-letter/0.1.0");
    defer if (exact) |dir| allocator.free(dir);
    try std.testing.expect(exact != null);

    // Neither form resolves to a directory that doesn't exist.
    const missing = try resolveInstalledPackageDir(allocator, io, packages_root, "ghost/0.1.0");
    defer if (missing) |dir| allocator.free(dir);
    try std.testing.expect(missing == null);

    const missing_bare = try resolveInstalledPackageDir(allocator, io, packages_root, "ghost");
    defer if (missing_bare) |dir| allocator.free(dir);
    try std.testing.expect(missing_bare == null);
}

fn tryPrintInstalledPackageInfo(
    allocator: std.mem.Allocator,
    io: std.Io,
    package_name: []const u8,
) !bool {
    const packages_root = try typst.getPackageDir(
        allocator,
        support.process_environ,
        .data,
    );
    defer allocator.free(packages_root);

    const package_dir = try resolveInstalledPackageDir(allocator, io, packages_root, package_name) orelse return false;
    defer allocator.free(package_dir);

    const toml_path = try std.fs.path.join(allocator, &.{ package_dir, "typst.toml" });
    defer allocator.free(toml_path);

    if (!support.fileExists(io, toml_path)) {
        support.failWithDetail(
            io,
            "No typst.toml found in the package directory:",
            package_dir,
        );
    }

    try printPackageInfoFromToml(
        allocator,
        io,
        toml_path,
        null,
    );

    return true;
}

fn printPackageInfoFromToml(
    allocator: std.mem.Allocator,
    io: std.Io,
    toml_path: []const u8,
    monorepo_path: ?[]const u8,
) !void {
    const parsed = try support.readPackageFile(
        allocator,
        io,
        toml_path,
    );
    const package = parsed.package orelse support.PackageSection{};

    const name = package.name orelse "<unknown>";
    const version = package.version orelse "<unknown>";
    const description = package.description;

    const authors = try joinAuthors(allocator, package.authors);
    defer allocator.free(authors);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);

    if (monorepo_path) |path| {
        try stdout_writer.interface.print("Monorepo Path: {s}\n", .{if (path.len == 0) "." else path});
    }

    try stdout_writer.interface.print("Package: {s}\n", .{name});
    try stdout_writer.interface.print("Version: {s}\n", .{version});
    if (description) |value| {
        if (value.len > 0) {
            try stdout_writer.interface.print("Description: {s}\n", .{value});
        }
    }

    if (authors.len > 0) {
        try stdout_writer.interface.print("Authors: {s}\n", .{authors});
    }

    try stdout_writer.interface.print("License: {s}\n", .{package.license orelse "<unknown>"});
    if (package.homepage) |value| {
        if (value.len > 0) {
            try stdout_writer.interface.print("Homepage: {s}\n", .{value});
        }
    }

    if (package.repository) |value| {
        if (value.len > 0) {
            try stdout_writer.interface.print("Repository: {s}\n", .{value});
        }
    }

    try stdout_writer.interface.flush();
}

fn joinAuthors(allocator: std.mem.Allocator, authors: ?[]const []const u8) ![]u8 {
    const items = authors orelse return try allocator.dupe(u8, "");
    if (items.len == 0) {
        return try allocator.dupe(u8, "");
    }

    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);

    for (items, 0..) |author, index| {
        if (index != 0) {
            try builder.appendSlice(allocator, ", ");
        }

        try builder.appendSlice(allocator, author);
    }

    return builder.toOwnedSlice(allocator);
}

test "parse github tree url" {
    const testing = std.testing;

    const expected_path = if (std.fs.path.sep == '\\') "packages\\report" else "packages/report";

    var source = try support.parseGitSource(testing.allocator, "https://github.com/example/demo/tree/main/packages/report");
    defer source.deinit(testing.allocator);

    try testing.expectEqualStrings("https://github.com/example/demo.git", source.repo_url_for_clone);
    try testing.expectEqualStrings("main", source.git_ref.?);
    try testing.expectEqualStrings(expected_path, source.path_in_repo);
}
