const std = @import("std");

const fangz = @import("fangz");
const fugaz = @import("fugaz");

const support = @import("support.zig");
const Typst = @import("typst.zig");

pub fn register(root: *fangz.Command) !void {
    const cmd = try root.addSubcommand(.{
        .name = "info",
        .brief = "Show information from an installed or remote Typst package/template.",
        .description =
        \\Looks up an already-installed package by name first. If none is found, treats the argument as a Git source (URL or alias like gh/user/repo) and clones it to inspect its manifest instead. Prints one block per typst.toml found, including the monorepo path when a repository contains more than one package.
        ,
    });

    cmd.setHelpOnEmptyArgs(true);
    cmd.setHooks(.{
        .run = run,
    });

    try cmd.addPositional(.{
        .name = "package",
        .brief = "Installed package name, or a Git URL/alias to inspect remotely.",
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

fn tryPrintInstalledPackageInfo(
    allocator: std.mem.Allocator,
    io: std.Io,
    package_name: []const u8,
) !bool {
    const packages_root = try Typst.getPackageDir(
        allocator,
        support.process_environ,
        .data,
    );
    defer allocator.free(packages_root);

    const package_dir = try std.fs.path.join(allocator, &.{ packages_root, package_name });
    defer allocator.free(package_dir);

    if (!support.dirExists(io, package_dir)) {
        return false;
    }

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
