const std = @import("std");

pub const GitSource = struct {
    repo_url_for_clone: []u8,
    git_ref: ?[]u8,
    path_in_repo: []u8,
    provider_host: []u8,
    user_or_org: []u8,

    pub fn deinit(self: *GitSource, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_url_for_clone);
        if (self.git_ref) |git_ref| allocator.free(git_ref);
        allocator.free(self.path_in_repo);
        allocator.free(self.provider_host);
        allocator.free(self.user_or_org);
    }
};
