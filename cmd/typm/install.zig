const std = @import("std");

const fangz = @import("fangz");
const fugaz = @import("fugaz");

const support = @import("support.zig");
const typst = @import("typst.zig");

pub fn register(root: *fangz.Command) !void {
    const cmd = try root.addSubcommand(.{
        .name = "install",
        .brief = "Install a package from a Git URL or alias.",
        .description =
        \\Clones the given Git repository (or resolves a _gh/gl/bb_ alias) into a temporary directory, locates its typst.toml — prompting if more than one is found in a monorepo — validates the manifest, and copies it into Typst's data directory under `@<provider>-<owner>/<name>:<version>`.
        ,
    });

    try cmd.addPositional(.{
        .name = "git-source",
        .brief = "Git URL or alias (e.g., gh/user/repo[/path]).",
        .required = true,
    });

    cmd.setHooks(.{ .run = run });
}

fn run(ctx: *fangz.ParseContext) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();

    const allocator = arena_state.allocator();

    const git_source_input = ctx.positional(0) orelse return error.MissingRequiredPositional;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(ctx.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("Attempting to install from: {s}\n", .{git_source_input});
    try out.flush();

    var source = support.parseGitSource(allocator, git_source_input) catch {
        support.failWithDetail(
            ctx.io,
            "Invalid Git source URL or alias:",
            git_source_input,
        );
    };

    defer source.deinit(allocator);

    try std.Io.Dir.cwd().createDirPath(ctx.io, ".typm-tmp");
    var temp_dir = try fugaz.builder().prefix("typst-build-git-").tempDirIn(
        ctx.io,
        allocator,
        ".typm-tmp",
    );
    defer temp_dir.deinit(ctx.io);

    try out.print("Cloning {s} into {s}...\n", .{ source.repo_url_for_clone, temp_dir.path() });
    try out.flush();
    try support.cloneRepository(
        allocator,
        ctx.io,
        &source,
        temp_dir.path(),
    );
    try out.print("Clone successful.\n", .{});
    try out.flush();

    const search_dir = if (source.path_in_repo.len == 0)
        try allocator.dupe(u8, temp_dir.path())
    else
        try std.fs.path.join(allocator, &.{ temp_dir.path(), source.path_in_repo });

    const manifest = try locateManifest(
        allocator,
        ctx.io,
        out,
        temp_dir.path(),
        search_dir,
    );

    const cfg = try support.readPackageFile(
        allocator,
        ctx.io,
        manifest.toml_path,
    );
    const pkg = cfg.package orelse support.PackageSection{};

    support.validatePackageConfig(
        ctx.io,
        pkg.name,
        pkg.version,
    );

    const name = pkg.name.?;
    const version = pkg.version.?;

    support.checkCompilerVersion(ctx.io, pkg.compiler);

    const packages_root = try typst.getPackageDir(
        allocator,
        support.process_environ,
        .data,
    );
    const provider = support.providerPrefixForHost(source.provider_host);
    const namespace = try std.fmt.allocPrint(
        allocator,
        "{s}-{s}",
        .{ provider, source.user_or_org },
    );
    const final_install_dir = try std.fs.path.join(allocator, &.{
        packages_root,
        namespace,
        name,
        version,
    });
    try std.Io.Dir.cwd().createDirPath(ctx.io, final_install_dir);

    try out.print("Installing to: {s}\n", .{final_install_dir});
    try out.flush();

    const import_base = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ namespace, name },
    );
    try support.copyPackageFiles(
        allocator,
        ctx.io,
        manifest.package_dir,
        final_install_dir,
        pkg.exclude orelse &.{},
        import_base,
        version,
        pkg.entrypoint orelse "main.typ",
    );

    try out.print("\nPackage '{s}' v{s} installed successfully.\n", .{ name, version });
    try out.print("You can now import it using: #import \"@{s}/{s}:{s}\": ...\n", .{
        namespace,
        name,
        version,
    });
    try out.flush();
}

/// The manifest to install and the directory holding the package it describes.
const Manifest = struct {
    package_dir: []const u8,
    toml_path: []const u8,
};

/// Finds the manifest to install: the `typst.toml` directly in `search_dir` when there is one, otherwise the single one below it, or the one the user picks when there are several. `repo_root` is only used to show the choices relative to the repository. Expects an arena allocator, since nothing here is freed individually.
fn locateManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    repo_root: []const u8,
    search_dir: []const u8,
) !Manifest {
    const direct_toml = try std.fs.path.join(allocator, &.{ search_dir, "typst.toml" });
    if (support.fileExists(io, direct_toml)) {
        return .{ .package_dir = search_dir, .toml_path = direct_toml };
    }

    try out.print("typst.toml not found at {s}. Searching recursively in {s}...\n", .{ direct_toml, search_dir });
    try out.flush();

    var found = std.ArrayList([]u8).empty;
    try support.collectTypstTomlFiles(
        allocator,
        io,
        search_dir,
        &found,
    );
    if (found.items.len == 0) {
        support.failWithDetail(
            io,
            "No typst.toml found under",
            search_dir,
        );
    }

    const toml_path: []const u8 = if (found.items.len == 1) found.items[0] else try promptForManifest(
        allocator,
        io,
        out,
        repo_root,
        found.items,
    );
    if (found.items.len == 1) {
        try out.print("Found typst.toml at: {s}\n", .{toml_path});
    } else {
        try out.print("Selected: {s}\n", .{toml_path});
    }

    try out.flush();

    return .{ .package_dir = std.fs.path.dirname(toml_path) orelse repo_root, .toml_path = toml_path };
}

/// Lists the manifests found in a monorepo and asks which one to install.
fn promptForManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    repo_root: []const u8,
    found: []const []u8,
) ![]u8 {
    try out.print("\nMultiple typst.toml files found. Please choose one to install:\n", .{});
    for (found, 0..) |path, index| {
        const display = try support.relativePath(
            allocator,
            io,
            repo_root,
            path,
        );
        try out.print("  {d}: {s}\n", .{ index + 1, display });
    }

    try out.flush();

    const choice = support.promptSelection(io, found.len) catch {
        support.failWithDetail(
            io,
            "Invalid choice.",
            "",
        );
    };

    if (choice == 0 or choice > found.len) {
        support.failWithDetail(
            io,
            "Invalid choice.",
            "",
        );
    }

    return found[choice - 1];
}
