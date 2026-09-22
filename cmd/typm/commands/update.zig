const std = @import("std");
const fangz = @import("fangz");

pub fn register(root: *fangz.Command) !void {
    const cmd = try root.addSubcommand(.{
        .name = "update",
        .description = "Update installed packages. (typm does not track remotes yet — reinstall with typm install.)",
    });

    cmd.setHooks(.{ .run = run });
}

fn run(_: *fangz.ParseContext) !void {
    var stdout_buffer: [512]u8 = undefined;
    var w = std.fs.File.stdout().writer(&stdout_buffer);
    try w.interface.print(
        \\typm does not yet compare installed packages against Git remotes.
        \\To refresh a package, run `typm install` again with the same source URL or alias.
        \\
    , .{});
    try w.interface.flush();
}
