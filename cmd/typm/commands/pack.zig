const std = @import("std");
const fangz = @import("fangz");

const support = @import("../support.zig");

pub fn register(root: *fangz.Command) !void {
    const cmd = try root.addSubcommand(.{
        .name = "pack",
        .description = "Build a Typst package/template from a typst.toml file to be published or installed.",
    });

    try cmd.addAlias("build");

    try cmd.addPositional(.{
        .name = "manifest",
        .description = "Path to the typst.toml file or its directory.",
        .required = true,
    });

    try cmd.addFlag([]const u8, .{
        .name = "output-dir",
        .short = 'o',
        .description = "The output directory where the built package will be placed.",
        .default = "out",
    });

    try cmd.addFlag([]const u8, .{
        .name = "namespace",
        .short = 'n',
        .description = "Namespace for the package.",
        .default = "preview",
    });

    cmd.setHooks(.{ .run = run });
}

fn run(ctx: *fangz.ParseContext) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const manifest = ctx.positional(0) orelse return error.MissingRequiredPositional;
    const output_dir = ctx.stringFlag("output-dir") orelse "out";
    const namespace = ctx.stringFlag("namespace") orelse "preview";

    const toml_path = try support.resolveTomlPath(allocator, manifest);
    const toml_dir = std.fs.path.dirname(toml_path) orelse ".";

    const cfg = try support.readPackageFile(allocator, toml_path);
    const pkg = cfg.package orelse support.PackageSection{};

    support.validatePackageConfig(pkg.name, pkg.version);
    const package_name = pkg.name.?;
    const package_version = pkg.version.?;
    const package_entrypoint = pkg.entrypoint orelse "main.typ";

    support.validatePackageName(package_name, toml_dir);
    support.checkCompilerVersion(pkg.compiler);
    try support.buildTemplate(allocator, toml_dir, package_name, cfg.template);

    var excludes = std.ArrayList([]const u8).empty;
    defer excludes.deinit(allocator);
    if (pkg.exclude) |items| try excludes.appendSlice(allocator, items);

    const output_name = std.fs.path.basename(output_dir);
    var already_excluded = false;
    for (excludes.items) |item| {
        if (std.mem.eql(u8, item, output_name)) {
            already_excluded = true;
            break;
        }
    }
    if (!already_excluded) try excludes.append(allocator, output_name);

    const final_output_dir = try std.fs.path.join(allocator, &.{ output_dir, package_name, package_version });

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout_writer.interface.print("Copying files to: {s}\n", .{final_output_dir});
    try stdout_writer.interface.flush();

    const import_base = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ namespace, package_name });
    try support.copyPackageFiles(allocator, toml_dir, final_output_dir, excludes.items, import_base, package_version, package_entrypoint);

    try stdout_writer.interface.print("Package '{s}' v{s} built successfully to {s}\n", .{ package_name, package_version, final_output_dir });
    try stdout_writer.interface.flush();
}
