const std = @import("std");
const fangz = @import("fangz");
const fugaz = @import("fugaz");

const support = @import("../support.zig");

pub fn register(root: *fangz.Command) !void {
    const cmd = try root.addSubcommand(.{
        .name = "install",
        .description = "Install a package from a Git URL or alias.",
    });

    try cmd.addPositional(.{
        .name = "git-source",
        .description = "Git URL or alias (e.g., gh/user/repo[/path]).",
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
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout_writer.interface.print("Attempting to install from: {s}\n", .{git_source_input});
    try stdout_writer.interface.flush();

    var source = support.parseGitSource(allocator, git_source_input) catch {
        support.failWithDetail("Invalid Git source URL or alias:", git_source_input);
    };
    defer source.deinit(allocator);

    try std.fs.cwd().makePath(".typm-tmp");
    var temp_dir = try fugaz.builder().prefix("typst-build-git-").tempDirIn(allocator, ".typm-tmp");
    defer temp_dir.deinit();

    try stdout_writer.interface.print("Cloning {s} into {s}...\n", .{ source.repo_url_for_clone, temp_dir.path() });
    try stdout_writer.interface.flush();
    try support.cloneRepository(allocator, &source, temp_dir.path());
    try stdout_writer.interface.print("Clone successful.\n", .{});
    try stdout_writer.interface.flush();

    var package_src = if (source.path_in_repo.len == 0)
        try allocator.dupe(u8, temp_dir.path())
    else
        try std.fs.path.join(allocator, &.{ temp_dir.path(), source.path_in_repo });
    defer allocator.free(package_src);

    var toml_path = try std.fs.path.join(allocator, &.{ package_src, "typst.toml" });
    defer allocator.free(toml_path);

    if (!support.fileExists(toml_path)) {
        try stdout_writer.interface.print("typst.toml not found at {s}. Searching recursively in {s}...\n", .{ toml_path, package_src });
        try stdout_writer.interface.flush();

        var found = std.ArrayList([]u8).empty;
        defer {
            for (found.items) |item| allocator.free(item);
            found.deinit(allocator);
        }

        try support.collectTypstTomlFiles(allocator, package_src, &found);
        if (found.items.len == 0) {
            support.failWithDetail("No typst.toml found under", package_src);
        }

        if (found.items.len == 1) {
            allocator.free(package_src);
            package_src = try allocator.dupe(u8, std.fs.path.dirname(found.items[0]) orelse temp_dir.path());
            toml_path = try allocator.dupe(u8, found.items[0]);
            try stdout_writer.interface.print("Found typst.toml at: {s}\n", .{toml_path});
            try stdout_writer.interface.flush();
        } else {
            try stdout_writer.interface.print("\nMultiple typst.toml files found. Please choose one to install:\n", .{});
            for (found.items, 0..) |path, index| {
                const display = try std.fs.path.relative(allocator, temp_dir.path(), path);
                defer allocator.free(display);
                try stdout_writer.interface.print("  {d}: {s}\n", .{ index + 1, display });
            }
            try stdout_writer.interface.flush();

            const choice = support.promptSelection(found.items.len) catch {
                support.failWithDetail("Invalid choice.", "");
            };
            if (choice == 0 or choice > found.items.len) {
                support.failWithDetail("Invalid choice.", "");
            }

            allocator.free(package_src);
            package_src = try allocator.dupe(u8, std.fs.path.dirname(found.items[choice - 1]) orelse temp_dir.path());
            toml_path = try allocator.dupe(u8, found.items[choice - 1]);
            try stdout_writer.interface.print("Selected: {s}\n", .{toml_path});
            try stdout_writer.interface.flush();
        }
    }

    const cfg = try support.readPackageFile(allocator, toml_path);
    const pkg = cfg.package orelse support.PackageSection{};
    support.validatePackageConfig(pkg.name, pkg.version);

    const name = pkg.name.?;
    const version = pkg.version.?;
    const exclude = pkg.exclude orelse &.{};
    const entrypoint = pkg.entrypoint orelse "main.typ";
    support.checkCompilerVersion(pkg.compiler);

    const data_dir = try support.typstDataDir(allocator);
    const provider = support.providerPrefixForHost(source.provider_host);
    const namespace = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ provider, source.user_or_org });
    const final_install_dir = try std.fs.path.join(allocator, &.{ data_dir, "packages", namespace, name, version });
    try std.fs.cwd().makePath(final_install_dir);

    try stdout_writer.interface.print("Installing to: {s}\n", .{final_install_dir});
    try stdout_writer.interface.flush();

    const import_base = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ namespace, name });
    try support.copyPackageFiles(allocator, package_src, final_install_dir, exclude, import_base, version, entrypoint);

    try stdout_writer.interface.print("\nPackage '{s}' v{s} installed successfully.\n", .{ name, version });
    try stdout_writer.interface.print("You can now import it using: #import \"@{s}/{s}:{s}\": ...\n", .{ namespace, name, version });
    try stdout_writer.interface.flush();
}
