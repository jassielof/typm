const std = @import("std");

const fangz = @import("fangz");

const build = @import("pack.zig");
const info = @import("info.zig");
const install = @import("install.zig");
const list = @import("list.zig");
const update = @import("update.zig");
const uninstall = @import("uninstall.zig");

pub fn register(root: *fangz.Command) !void {
    root.setHelpOnEmptyArgs(true);

    try build.register(root);
    try info.register(root);
    try install.register(root);
    try list.register(root);
    try update.register(root);
    try uninstall.register(root);
}
