const std = @import("std");
const builtin = @import("builtin");

const fangz = @import("fangz");

const support = @import("support.zig");
const Typst = @import("Typst.zig");

pub fn register(root: *fangz.Command) !void {
    const cmd = try root.addSubcommand(.{
        .name = "bundle",
        .brief = "Build a Typst package/template from a typst.toml file to be published or installed.",
        .description =
        \\Reads the package manifest, validates its name and version, checks the declared Typst compiler requirement, compiles any template listed under [template], and copies the package files (respecting `exclude` patterns) into `<output-dir>/<name>/<version>`, rewriting local imports to the `@<namespace>/<name>:<version>` form along the way.
        \\
        \\Without --output-dir the package goes straight into Typst's local package directory as `<namespace>/<name>/<version>`, so it can be imported right away. An existing package is never overwritten unless --force is given.
        ,
    });
    cmd.help_on_empty_args = true;

    try cmd.addAlias("build");
    try cmd.addAlias("pack");

    try cmd.addPositional(.{
        .name = "manifest",
        .brief = "Path to the typst.toml file or its directory.",
        .required = true,
    });

    try cmd.addFlag(?[]const u8, .{
        .name = "output-dir",
        .short = 'o',
        .brief = "Directory to place `<name>/<version>` in. Defaults to Typst's local package directory.",
    });

    try cmd.addFlag([]const u8, .{
        .name = "namespace",
        .short = 'n',
        .brief = "Namespace for the package, as in `@<namespace>/<name>`.",
        .default = "local",
    });

    try cmd.addFlag(bool, .{
        .name = "force",
        .short = 'f',
        .brief = "Overwrite the package if it already exists.",
    });

    cmd.setHooks(.{ .run = run });
}

fn run(ctx: *fangz.ParseContext) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const manifest = ctx.positional(0) orelse return error.MissingRequiredPositional;
    const output_dir = ctx.stringFlag("output-dir");
    const namespace = ctx.stringFlag("namespace") orelse "local";
    const force = ctx.boolFlag("force") orelse false;

    const toml_path = try support.resolveTomlPath(allocator, ctx.io, manifest);
    const toml_dir = std.fs.path.dirname(toml_path) orelse ".";

    const cfg = try support.readPackageFile(allocator, ctx.io, toml_path);
    const pkg = cfg.package orelse support.PackageSection{};

    support.validatePackageConfig(ctx.io, pkg.name, pkg.version);
    const package_name = pkg.name.?;
    const package_version = pkg.version.?;
    const package_entrypoint = pkg.entrypoint orelse "main.typ";

    support.validatePackageName(ctx.io, package_name, toml_dir);
    support.checkCompilerVersion(ctx.io, pkg.compiler);

    const final_output_dir = if (output_dir) |dir|
        try std.fs.path.join(allocator, &.{ dir, package_name, package_version })
    else blk: {
        const packages_root = try Typst.getPackageDir(allocator, support.process_environ, .data);
        break :blk try std.fs.path.join(allocator, &.{ packages_root, namespace, package_name, package_version });
    };

    // Fail before doing any work if the package is there and we were not told to replace it.
    const already_exists = support.dirExists(ctx.io, final_output_dir);
    if (already_exists and !force) {
        support.failWithDetail(ctx.io, "Package already exists (use --force to overwrite it):", final_output_dir);
    }

    try support.buildTemplate(allocator, ctx.io, toml_dir, package_name, cfg.template);

    var excludes = std.ArrayList([]const u8).empty;
    defer excludes.deinit(allocator);
    if (pkg.exclude) |items| try excludes.appendSlice(allocator, items);

    // An explicit output directory may sit inside the project, so keep it from being copied into itself.
    if (output_dir) |dir| {
        const output_name = std.fs.path.basename(dir);
        var already_excluded = false;
        for (excludes.items) |item| {
            if (std.mem.eql(u8, item, output_name)) {
                already_excluded = true;
                break;
            }
        }
        if (!already_excluded) try excludes.append(allocator, output_name);
    }

    if (already_exists) {
        if (try isSameOrInside(allocator, ctx.io, toml_dir, final_output_dir)) {
            support.failWithDetail(ctx.io, "Refusing to overwrite the package's own source:", final_output_dir);
        }
        try std.Io.Dir.cwd().deleteTree(ctx.io, final_output_dir);
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(ctx.io, &stdout_buffer);
    try stdout_writer.interface.print("Copying files to: {s}\n", .{final_output_dir});
    try stdout_writer.interface.flush();

    const import_base = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ namespace, package_name });
    try support.copyPackageFiles(allocator, ctx.io, toml_dir, final_output_dir, excludes.items, import_base, package_version, package_entrypoint);

    try stdout_writer.interface.print("Package '{s}' v{s} built successfully to {s}\n", .{ package_name, package_version, final_output_dir });
    try stdout_writer.interface.flush();
}

/// Whether `inner` is `outer` or lives somewhere below it, compared by resolved path so `.` and symlinks cannot hide it.
fn isSameOrInside(allocator: std.mem.Allocator, io: std.Io, inner: []const u8, outer: []const u8) !bool {
    const inner_real = try std.Io.Dir.cwd().realPathFileAlloc(io, inner, allocator);
    const outer_real = try std.Io.Dir.cwd().realPathFileAlloc(io, outer, allocator);
    return pathIsSameOrInside(inner_real, outer_real);
}

fn pathIsSameOrInside(inner: []const u8, outer: []const u8) bool {
    if (inner.len < outer.len) return false;

    const matches = if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(inner[0..outer.len], outer)
    else
        std.mem.eql(u8, inner[0..outer.len], outer);
    if (!matches) return false;

    return inner.len == outer.len or std.fs.path.isSep(inner[outer.len]) or (outer.len > 0 and std.fs.path.isSep(outer[outer.len - 1]));
}

test "a path is inside another only at a component boundary" {
    const sep = std.fs.path.sep_str;

    try std.testing.expect(pathIsSameOrInside("a" ++ sep ++ "b", "a" ++ sep ++ "b"));
    try std.testing.expect(pathIsSameOrInside("a" ++ sep ++ "b" ++ sep ++ "c", "a" ++ sep ++ "b"));
    try std.testing.expect(!pathIsSameOrInside("a" ++ sep ++ "bc", "a" ++ sep ++ "b"));
    try std.testing.expect(!pathIsSameOrInside("a", "a" ++ sep ++ "b"));
    try std.testing.expect(!pathIsSameOrInside("x" ++ sep ++ "b", "a" ++ sep ++ "b"));
}
