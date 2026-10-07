const std = @import("std");

const builtin = @import("builtin");

const fangz = @import("fangz");

const support = @import("support.zig");
const typst = @import("typst.zig");

pub fn register(root: *fangz.Command) !void {
    const cmd = try root.addSubcommand(.{
        .name = "bundle",
        .brief = "Build a Typst package/template from a typst.toml file to be published or installed.",
        .description =
        \\Reads the package manifest, validates its name and version, checks the declared Typst compiler requirement, compiles any template listed under `[template]`, and copies the package files (respecting `exclude` patterns) into `<output-dir>/<name>/<version>`, rewriting local imports to the `@<namespace>/<name>:<version>` form along the way.
        \\
        \\Without --output-dir the package goes straight into Typst's local package directory as `<namespace>/<name>/<version>`, so it can be imported right away. An existing package is never overwritten unless `--force` is given.
        ,
    });
    try cmd.addAlias("build");
    try cmd.addAlias("pack");

    try cmd.addPositional(.{
        .name = "manifest",
        .brief = "Path to the typst.toml file or its directory. Defaults to the current directory.",
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

    const manifest = manifestInput(ctx.positional(0));
    const output_dir = ctx.stringFlag("output-dir");
    const namespace = ctx.stringFlag("namespace") orelse "local";
    const force = ctx.boolFlag("force") orelse false;

    const toml_path = try support.resolveTomlPath(
        allocator,
        ctx.io,
        manifest,
    );
    const toml_dir = try resolvePackageDir(
        allocator,
        ctx.io,
        std.fs.path.dirname(toml_path) orelse ".",
    );

    const cfg = try support.readPackageFile(
        allocator,
        ctx.io,
        toml_path,
    );
    const pkg = cfg.package orelse support.PackageSection{};

    support.validatePackageConfig(
        ctx.io,
        pkg.name,
        pkg.version,
    );
    const package_name = pkg.name.?;
    const package_version = pkg.version.?;
    const package_entrypoint = pkg.entrypoint orelse "main.typ";

    support.validatePackageName(
        ctx.io,
        package_name,
        toml_dir,
    );
    support.checkCompilerVersion(ctx.io, pkg.compiler);

    const final_output_dir = try destinationDir(
        allocator,
        output_dir,
        namespace,
        package_name,
        package_version,
    );

    // Fail before doing any work if the package is there and we were not told to replace it.
    const already_exists = support.dirExists(ctx.io, final_output_dir);
    if (already_exists and !force) {
        support.failWithDetail(
            ctx.io,
            "Package already exists (use --force to overwrite it):",
            final_output_dir,
        );
    }

    try support.buildTemplate(
        allocator,
        ctx.io,
        toml_dir,
        package_name,
        cfg.template,
    );

    var excludes = try excludePatterns(
        allocator,
        pkg.exclude,
        output_dir,
    );
    defer excludes.deinit(allocator);

    if (already_exists) try removeExisting(
        allocator,
        ctx.io,
        toml_dir,
        final_output_dir,
    );

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(ctx.io, &stdout_buffer);
    try stdout_writer.interface.print("Copying files to: {s}\n", .{final_output_dir});
    try stdout_writer.interface.flush();

    const import_base = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ namespace, package_name },
    );
    try support.copyPackageFiles(
        allocator,
        ctx.io,
        toml_dir,
        final_output_dir,
        excludes.items,
        import_base,
        package_version,
        package_entrypoint,
    );

    try stdout_writer.interface.print("Package '{s}' v{s} built successfully to {s}\n", .{
        package_name,
        package_version,
        final_output_dir,
    });
    try stdout_writer.interface.flush();
}

fn manifestInput(positional: ?[]const u8) []const u8 {
    return positional orelse ".";
}

/// Resolves `.` and other relative forms before package-name validation so the
/// directory name is the actual package folder rather than a lexical `.`.
fn resolvePackageDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
}

/// Where the bundled package goes: `<output-dir>/<name>/<version>` when a directory was given, otherwise Typst's local package directory as `<namespace>/<name>/<version>`.
fn destinationDir(
    allocator: std.mem.Allocator,
    output_dir: ?[]const u8,
    namespace: []const u8,
    package_name: []const u8,
    package_version: []const u8,
) ![]u8 {
    if (output_dir) |dir| return std.fs.path.join(allocator, &.{
        dir,
        package_name,
        package_version,
    });

    const packages_root = try typst.getPackageDir(
        allocator,
        support.process_environ,
        .data,
    );

    return std.fs.path.join(allocator, &.{
        packages_root,
        namespace,
        package_name,
        package_version,
    });
}

/// The manifest's `exclude` patterns, plus the output directory's name when one was given: it may sit inside the project, and must not be copied into itself.
fn excludePatterns(
    allocator: std.mem.Allocator,
    manifest_excludes: ?[]const []const u8,
    output_dir: ?[]const u8,
) !std.ArrayList([]const u8) {
    var excludes = std.ArrayList([]const u8).empty;
    errdefer excludes.deinit(allocator);

    if (manifest_excludes) |items| {
        try excludes.appendSlice(allocator, items);
    }

    const dir = output_dir orelse return excludes;
    const output_name = std.fs.path.basename(dir);
    if (!containsName(excludes.items, output_name)) {
        try excludes.append(allocator, output_name);
    }

    return excludes;
}

fn containsName(items: []const []const u8, name: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(
            u8,
            item,
            name,
        )) return true;
    }

    return false;
}

/// Clears an existing destination so no stale files survive, unless that would delete the package's own source.
fn removeExisting(
    allocator: std.mem.Allocator,
    io: std.Io,
    toml_dir: []const u8,
    final_output_dir: []const u8,
) !void {
    if (try isSameOrInside(
        allocator,
        io,
        toml_dir,
        final_output_dir,
    )) {
        support.failWithDetail(
            io,
            "Refusing to overwrite the package's own source:",
            final_output_dir,
        );
    }

    try std.Io.Dir.cwd().deleteTree(io, final_output_dir);
}

/// Whether `inner` is `outer` or lives somewhere below it, compared by resolved path so `.` and symlinks cannot hide it.
fn isSameOrInside(
    allocator: std.mem.Allocator,
    io: std.Io,
    inner: []const u8,
    outer: []const u8,
) !bool {
    const inner_real = try std.Io.Dir.cwd().realPathFileAlloc(
        io,
        inner,
        allocator,
    );
    const outer_real = try std.Io.Dir.cwd().realPathFileAlloc(
        io,
        outer,
        allocator,
    );

    return pathIsSameOrInside(inner_real, outer_real);
}

fn pathIsSameOrInside(inner: []const u8, outer: []const u8) bool {
    if (inner.len < outer.len) {
        return false;
    }

    const matches = if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(inner[0..outer.len], outer)
    else
        std.mem.eql(
            u8,
            inner[0..outer.len],
            outer,
        );
    if (!matches) {
        return false;
    }

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

test "bundle defaults an omitted manifest to the current directory" {
    try std.testing.expectEqualStrings(".", manifestInput(null));
    try std.testing.expectEqualStrings("package", manifestInput("package"));
}

test "bundle resolves the package folder before validating its name" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "example-package");
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const relative_form = try std.fs.path.join(allocator, &.{ root, "example-package", "." });
    defer allocator.free(relative_form);

    const package_dir = try resolvePackageDir(allocator, io, relative_form);
    defer allocator.free(package_dir);

    try std.testing.expectEqualStrings("example-package", std.fs.path.basename(package_dir));
}

test "bundle accepts an omitted manifest without showing help" {
    var app = try fangz.App.init(
        std.testing.allocator,
        std.testing.io,
        .{
            .display_name = "typm",
            .author_email = .none,
            .author_name = .none,
        },
    );
    defer app.deinit();

    try register(app.root());

    const ctx = try app.parseFrom(&.{"bundle"});
    try std.testing.expect(!ctx.help_requested);
    try std.testing.expect(ctx.positional(0) == null);
}
