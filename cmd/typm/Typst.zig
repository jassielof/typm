const std = @import("std");
const builtin = @import("builtin");

const Package = enum {
    cache,
    data,
};

const cache_path_env = "TYPST_PACKAGE_CACHE_PATH";
const data_path_env = "TYPST_PACKAGE_PATH";

/// Get the cache directory of Typst.
///
/// Either by firstly checking the respective environment variable, or the default one based on the OS.
///
/// See https://github.com/typst/packages/blob/c137d10e98e1cb686000c6de2ff1de56efcaaac8/README.md
pub fn getPackageDir(allocator: std.mem.Allocator, environ: std.process.Environ, package: Package) ![]u8 {
    var env = environ.createMap(allocator) catch return error.EnvError;
    defer env.deinit();

    const home = try environ.getAlloc(allocator, "HOME");
    defer allocator.free(home);

    var base: []const u8 = undefined;

    switch (builtin.os.tag) {
        .windows => {
            if (env.get("LOCALAPPDATA")) |v| {
                base = v;
            } else {
                base = try std.fs.path.join(allocator, &.{ home, "AppData", "Local" });
            }
        },
        .macos => {
            base = try std.fs.path.join(allocator, &.{ home, "Library", "Caches" });
        },
        else => { // Linux / other Unix
            if (env.get("XDG_CACHE_HOME")) |v| {
                base = v;
            } else {
                base = try std.fs.path.join(allocator, &.{ home, ".cache" });
            }
        },
    }

    return std.fs.path.join(allocator, &.{ base, "typst" });
}

test getPackageDir {
    const allocator = std.testing.allocator;
    const cache_dir = try getPackageDir(allocator, .empty, .cache);
    defer allocator.free(cache_dir);

    std.debug.print("Cache directory: {s}\n", .{cache_dir});
}
