const std = @import("std");
const builtin = @import("builtin");

/// Which of Typst's two package directories to resolve.
pub const Package = enum {
    /// Packages downloaded from Typst Universe (`@preview/...`).
    cache,
    /// Locally installed packages (`@local/...` and other custom namespaces).
    data,

    fn overrideVariable(self: Package) []const u8 {
        return switch (self) {
            .cache => "TYPST_PACKAGE_CACHE_PATH",
            .data => "TYPST_PACKAGE_PATH",
        };
    }
};

pub const Error = error{HomeDirectoryNotFound} || std.mem.Allocator.Error || std.process.Environ.CreateMapError;

/// Returns the directory Typst keeps `package` packages in, i.e. the root that holds `<namespace>/<name>/<version>`.
///
/// The `TYPST_PACKAGE_CACHE_PATH` / `TYPST_PACKAGE_PATH` environment variable wins when set; otherwise it is `<base>/typst/packages` where `<base>` is the platform's cache or data directory.
///
/// See https://github.com/typst/packages/blob/c137d10e98e1cb686000c6de2ff1de56efcaaac8/README.md
pub fn getPackageDir(allocator: std.mem.Allocator, environ: std.process.Environ, package: Package) Error![]u8 {
    var env = try environ.createMap(allocator);
    defer env.deinit();

    return packageDirFor(allocator, builtin.os.tag, &env, package);
}

fn packageDirFor(allocator: std.mem.Allocator, os: std.Target.Os.Tag, env: *const std.process.Environ.Map, package: Package) Error![]u8 {
    if (nonEmpty(env.get(package.overrideVariable()))) |path| return allocator.dupe(u8, path);

    const base = try baseDir(allocator, os, env, package);
    defer allocator.free(base);

    return std.fs.path.join(allocator, &.{ base, "typst", "packages" });
}

/// Where the platform keeps one of Typst's package directories: an environment variable that can relocate it (if the platform has one) and the path under the home directory it defaults to.
const Location = struct {
    variable: ?[]const u8,
    home_suffix: []const []const u8,
};

fn location(os: std.Target.Os.Tag, package: Package) Location {
    return switch (os) {
        .windows => switch (package) {
            .data => .{ .variable = "APPDATA", .home_suffix = &.{ "AppData", "Roaming" } },
            .cache => .{ .variable = "LOCALAPPDATA", .home_suffix = &.{ "AppData", "Local" } },
        },
        .macos => switch (package) {
            .data => .{ .variable = null, .home_suffix = &.{ "Library", "Application Support" } },
            .cache => .{ .variable = null, .home_suffix = &.{ "Library", "Caches" } },
        },
        else => switch (package) {
            .data => .{ .variable = "XDG_DATA_HOME", .home_suffix = &.{ ".local", "share" } },
            .cache => .{ .variable = "XDG_CACHE_HOME", .home_suffix = &.{".cache"} },
        },
    };
}

/// The platform directory Typst places its own `typst/` folder in.
fn baseDir(allocator: std.mem.Allocator, os: std.Target.Os.Tag, env: *const std.process.Environ.Map, package: Package) Error![]u8 {
    const place = location(os, package);

    if (place.variable) |variable| {
        if (nonEmpty(env.get(variable))) |path| return allocator.dupe(u8, path);
    }
    return underHome(allocator, os, env, place.home_suffix);
}

fn underHome(allocator: std.mem.Allocator, os: std.Target.Os.Tag, env: *const std.process.Environ.Map, suffix: []const []const u8) Error![]u8 {
    const home = homeDir(os, env) orelse return error.HomeDirectoryNotFound;

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    try parts.append(allocator, home);
    try parts.appendSlice(allocator, suffix);

    return std.fs.path.join(allocator, parts.items);
}

fn homeDir(os: std.Target.Os.Tag, env: *const std.process.Environ.Map) ?[]const u8 {
    if (os == .windows) {
        if (nonEmpty(env.get("USERPROFILE"))) |path| return path;
    }
    return nonEmpty(env.get("HOME"));
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (text.len == 0) null else text;
}

fn expectPackageDir(os: std.Target.Os.Tag, package: Package, variables: []const [2][]const u8, expected_parts: []const []const u8) !void {
    const allocator = std.testing.allocator;

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    for (variables) |pair| try env.put(pair[0], pair[1]);

    const actual = try packageDirFor(allocator, os, &env, package);
    defer allocator.free(actual);

    const expected = try std.fs.path.join(allocator, expected_parts);
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, actual);
}

test "data and cache resolve to different directories on every platform" {
    try expectPackageDir(.windows, .data, &.{.{ "APPDATA", "R" }}, &.{ "R", "typst", "packages" });
    try expectPackageDir(.windows, .cache, &.{.{ "LOCALAPPDATA", "L" }}, &.{ "L", "typst", "packages" });
    try expectPackageDir(.windows, .data, &.{.{ "USERPROFILE", "H" }}, &.{ "H", "AppData", "Roaming", "typst", "packages" });
    try expectPackageDir(.windows, .cache, &.{.{ "USERPROFILE", "H" }}, &.{ "H", "AppData", "Local", "typst", "packages" });

    try expectPackageDir(.macos, .data, &.{.{ "HOME", "H" }}, &.{ "H", "Library", "Application Support", "typst", "packages" });
    try expectPackageDir(.macos, .cache, &.{.{ "HOME", "H" }}, &.{ "H", "Library", "Caches", "typst", "packages" });

    try expectPackageDir(.linux, .data, &.{.{ "XDG_DATA_HOME", "D" }}, &.{ "D", "typst", "packages" });
    try expectPackageDir(.linux, .cache, &.{.{ "XDG_CACHE_HOME", "C" }}, &.{ "C", "typst", "packages" });
    try expectPackageDir(.linux, .data, &.{.{ "HOME", "H" }}, &.{ "H", ".local", "share", "typst", "packages" });
    try expectPackageDir(.linux, .cache, &.{.{ "HOME", "H" }}, &.{ "H", ".cache", "typst", "packages" });
}

test "Typst's package path variables override the platform default" {
    try expectPackageDir(.linux, .data, &.{ .{ "TYPST_PACKAGE_PATH", "custom/data" }, .{ "XDG_DATA_HOME", "D" } }, &.{"custom/data"});
    try expectPackageDir(.linux, .cache, &.{ .{ "TYPST_PACKAGE_CACHE_PATH", "custom/cache" }, .{ "HOME", "H" } }, &.{"custom/cache"});

    // Each variable only affects its own package directory.
    try expectPackageDir(.linux, .cache, &.{ .{ "TYPST_PACKAGE_PATH", "custom/data" }, .{ "XDG_CACHE_HOME", "C" } }, &.{ "C", "typst", "packages" });
}

test "empty variables are treated as unset" {
    try expectPackageDir(.linux, .data, &.{ .{ "TYPST_PACKAGE_PATH", "" }, .{ "XDG_DATA_HOME", "" }, .{ "HOME", "H" } }, &.{ "H", ".local", "share", "typst", "packages" });
}

test "a missing home directory is reported" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expectError(error.HomeDirectoryNotFound, packageDirFor(std.testing.allocator, .linux, &env, .data));
    try std.testing.expectError(error.HomeDirectoryNotFound, packageDirFor(std.testing.allocator, .windows, &env, .cache));
}
