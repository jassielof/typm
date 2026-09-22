const std = @import("std");
const fangz = @import("fangz");
const fugaz = @import("fugaz");

const support = @import("../support.zig");

pub fn register(root: *fangz.Command) !void {
    const cmd = try root.addSubcommand(.{
        .name = "info",
        .description = "Show information from an installed or remote Typst package/template.",
    });

    cmd.setHelpOnEmptyArgs(true);
    cmd.setHooks(.{
        .run = run,
    });

    try cmd.addPositional(.{
        .name = "package",
        .description = "Name of the package to display information about",
        .required = true,
    });
}

fn run(ctx: *fangz.ParseContext) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const package_name = ctx.positional(0) orelse return error.MissingRequiredPositional;

    if (try tryPrintInstalledPackageInfo(allocator, package_name)) {
        return;
    }

    var source = support.parseGitSource(allocator, package_name) catch {
        support.failWithDetail("Invalid Git source URL or alias:", package_name);
    };
    defer source.deinit(allocator);

    try std.fs.cwd().makePath(".typm-tmp");
    var temp_dir = try fugaz.builder().prefix("typm-info-git-").tempDirIn(allocator, ".typm-tmp");
    defer temp_dir.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout_writer.interface.print("Cloning {s}...\n", .{source.repo_url_for_clone});
    try stdout_writer.interface.flush();

    try support.cloneRepository(allocator, &source, temp_dir.path());

    const search_dir = if (source.path_in_repo.len == 0)
        try allocator.dupe(u8, temp_dir.path())
    else
        try std.fs.path.join(allocator, &.{ temp_dir.path(), source.path_in_repo });
    defer allocator.free(search_dir);

    var toml_paths = std.ArrayList([]u8).empty;
    defer {
        for (toml_paths.items) |path| allocator.free(path);
        toml_paths.deinit(allocator);
    }

    const direct_toml = try std.fs.path.join(allocator, &.{ search_dir, "typst.toml" });
    defer allocator.free(direct_toml);

    if (support.fileExists(direct_toml)) {
        try toml_paths.append(allocator, try allocator.dupe(u8, direct_toml));
    } else {
        try support.collectTypstTomlFiles(allocator, search_dir, &toml_paths);
    }

    if (toml_paths.items.len == 0) {
        support.failWithDetail("No typst.toml found in the cloned repository:", search_dir);
    }

    if (toml_paths.items.len > 1) {
        try stdout_writer.interface.print("\nMultiple packages found in this monorepo:\n\n", .{});
        try stdout_writer.interface.flush();
    }

    for (toml_paths.items, 0..) |toml_path, index| {
        const rel_dir = try support.relativeParentDir(allocator, temp_dir.path(), toml_path);
        defer allocator.free(rel_dir);

        try printPackageInfoFromToml(allocator, toml_path, if (toml_paths.items.len > 1) rel_dir else null);

        if (toml_paths.items.len > 1 and index + 1 < toml_paths.items.len) {
            try stdout_writer.interface.print("\n", .{});
            try stdout_writer.interface.flush();
        }
    }
}

fn tryPrintInstalledPackageInfo(allocator: std.mem.Allocator, package_name: []const u8) !bool {
    const data_dir = try support.typstDataDir(allocator);
    defer allocator.free(data_dir);

    const package_dir = try std.fs.path.join(allocator, &.{ data_dir, "packages", package_name });
    defer allocator.free(package_dir);

    if (!support.dirExists(package_dir)) return false;

    const toml_path = try std.fs.path.join(allocator, &.{ package_dir, "typst.toml" });
    defer allocator.free(toml_path);

    if (!support.fileExists(toml_path)) {
        support.failWithDetail("No typst.toml found in the package directory:", package_dir);
    }

    try printPackageInfoFromToml(allocator, toml_path, null);
    return true;
}

fn printPackageInfoFromToml(allocator: std.mem.Allocator, toml_path: []const u8, monorepo_path: ?[]const u8) !void {
    const parsed = try support.readPackageFile(allocator, toml_path);
    const package = parsed.package orelse support.PackageSection{};

    const name = package.name orelse "<unknown>";
    const version = package.version orelse "<unknown>";
    const description = package.description;
    const authors = try joinAuthors(allocator, package.authors);
    defer allocator.free(authors);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);

    if (monorepo_path) |path| {
        try stdout_writer.interface.print("Monorepo Path: {s}\n", .{if (path.len == 0) "." else path});
    }

    try stdout_writer.interface.print("Package: {s}\n", .{name});
    try stdout_writer.interface.print("Version: {s}\n", .{version});
    if (description) |value| {
        if (value.len > 0) try stdout_writer.interface.print("Description: {s}\n", .{value});
    }
    if (authors.len > 0) try stdout_writer.interface.print("Authors: {s}\n", .{authors});
    try stdout_writer.interface.print("License: {s}\n", .{package.license orelse "<unknown>"});
    if (package.homepage) |value| {
        if (value.len > 0) try stdout_writer.interface.print("Homepage: {s}\n", .{value});
    }
    if (package.repository) |value| {
        if (value.len > 0) try stdout_writer.interface.print("Repository: {s}\n", .{value});
    }
    try stdout_writer.interface.flush();
}

fn joinAuthors(allocator: std.mem.Allocator, authors: ?[]const []const u8) ![]u8 {
    const items = authors orelse return try allocator.dupe(u8, "");
    if (items.len == 0) return try allocator.dupe(u8, "");

    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);

    for (items, 0..) |author, index| {
        if (index != 0) try builder.appendSlice(allocator, ", ");
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
