const std = @import("std");
const builtin = @import("builtin");
const toml = @import("toml");

const GitSource = @import("GitSource.zig").GitSource;

pub const PackageFile = struct {
    package: ?PackageSection = null,
    template: ?TemplateSection = null,
};

pub const PackageSection = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
    authors: ?[]const []const u8 = null,
    license: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    exclude: ?[]const []const u8 = null,
    entrypoint: ?[]const u8 = null,
    compiler: ?[]const u8 = null,
};

pub const TemplateSection = struct {
    path: ?[]const u8 = null,
    entrypoint: ?[]const u8 = null,
    thumbnail: ?[]const u8 = null,
};

pub fn readPackageFile(allocator: std.mem.Allocator, toml_path: []const u8) !PackageFile {
    const content = try std.fs.cwd().readFileAlloc(allocator, toml_path, 1024 * 1024);
    defer allocator.free(content);

    return toml.parse(PackageFile, allocator, content);
}

pub fn resolveTomlPath(allocator: std.mem.Allocator, input_path: []const u8) ![]u8 {
    if (fileExists(input_path)) {
        return allocator.dupe(u8, input_path);
    }

    if (dirExists(input_path)) {
        const candidate = try std.fs.path.join(allocator, &.{ input_path, "typst.toml" });
        errdefer allocator.free(candidate);

        if (!fileExists(candidate)) {
            failWithDetail("No typst.toml found in directory:", input_path);
        }

        return candidate;
    }

    failWithDetail("Path is neither a file nor a directory:", input_path);
}

pub fn validatePackageConfig(name: ?[]const u8, version: ?[]const u8) void {
    if (name == null or version == null) {
        failWithDetail("Error: 'package.name' and 'package.version' are required.", "");
    }
}

pub fn validatePackageName(package_name: []const u8, toml_dir: []const u8) void {
    const dir_name = std.fs.path.basename(toml_dir);
    if (!std.mem.eql(u8, package_name, dir_name)) {
        var buffer: [4096]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "Package name '{s}' does not match parent directory name '{s}'", .{ package_name, dir_name }) catch "Package name does not match parent directory name";
        failWithDetail(message, "");
    }
}

pub fn getTypstVersion() !std.SemanticVersion {
    const allocator = std.heap.page_allocator;
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "typst", "--version" },
    }) catch {
        return error.TypstNotFound;
    };

    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term.Exited != 0) {
        return error.TypstNotFound;
    }

    const stdout = std.mem.trim(u8, result.stdout, "\n\r\t ");
    var it = std.mem.splitScalar(u8, stdout, ' ');
    _ = it.next() orelse return error.InvalidOutput;
    const version_str = it.next() orelse return error.InvalidOutput;
    return std.SemanticVersion.parse(version_str) catch error.InvalidSemver;
}

pub fn checkCompilerVersion(compiler_req: ?[]const u8) void {
    const req = compiler_req orelse return;
    const current = getTypstVersion() catch {
        failWithDetail("Failed to determine Typst version.", "");
    };

    if (!matchesVersionReq(req, current)) {
        var buffer: [256]u8 = undefined;
        const current_str = std.fmt.bufPrint(&buffer, "{d}.{d}.{d}", .{ current.major, current.minor, current.patch }) catch "<unknown>";
        var message_buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buffer, "Package requires Typst version '{s}', but you have {s}.", .{ req, current_str }) catch "Package requires a different Typst version.";
        failWithDetail(message, "");
    }

    var stdout_buffer: [256]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&stdout_buffer);
    writer.interface.print("Typst version check passed (required: {s}, current: {d}.{d}.{d}).\n", .{ req, current.major, current.minor, current.patch }) catch {};
    writer.interface.flush() catch {};
}

pub fn matchesVersionReq(req: []const u8, version: std.SemanticVersion) bool {
    var tokens = std.mem.tokenizeAny(u8, req, " \t\r\n");
    while (tokens.next()) |token| {
        var operator: []const u8 = ">=";
        var version_str = token;

        inline for (.{ ">=", "<=", "==", "!=", ">", "<", "=" }) |candidate| {
            if (std.mem.startsWith(u8, token, candidate)) {
                operator = candidate;
                version_str = token[candidate.len..];
                break;
            }
        }

        if (version_str.len == 0) {
            version_str = tokens.next() orelse return false;
        }

        const required = std.SemanticVersion.parse(version_str) catch return false;
        const cmp = compareSemver(version, required);

        const ok = if (std.mem.eql(u8, operator, ">"))
            cmp > 0
        else if (std.mem.eql(u8, operator, "<"))
            cmp < 0
        else if (std.mem.eql(u8, operator, ">="))
            cmp >= 0
        else if (std.mem.eql(u8, operator, "<="))
            cmp <= 0
        else if (std.mem.eql(u8, operator, "!="))
            cmp != 0
        else
            cmp == 0;

        if (!ok) return false;
    }

    return true;
}

pub fn buildTemplate(allocator: std.mem.Allocator, toml_dir: []const u8, package_name: []const u8, template: ?TemplateSection) !void {
    const template_section = template orelse return;
    const template_path = template_section.path orelse return;
    const template_entrypoint = template_section.entrypoint orelse return;
    const project_root = std.fs.path.dirname(toml_dir) orelse ".";

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout_writer.interface.print("Compiling template: {s}/{s}\n", .{ template_path, template_entrypoint });
    try stdout_writer.interface.flush();

    const input_path = try std.fs.path.join(allocator, &.{ project_root, package_name, template_path, template_entrypoint });
    defer allocator.free(input_path);

    try runProcessChecked(allocator, &.{ "typst", "compile", "--root", project_root, input_path }, "Template compilation failed.");

    if (template_section.thumbnail) |thumbnail_path| {
        try stdout_writer.interface.print("Generating thumbnail: {s}\n", .{thumbnail_path});
        try stdout_writer.interface.flush();

        const output_path = try std.fs.path.join(allocator, &.{ project_root, package_name, thumbnail_path });
        defer allocator.free(output_path);

        try runProcessChecked(allocator, &.{ "typst", "compile", "--root", project_root, "--pages", "1", input_path, output_path }, "Thumbnail generation failed.");
    }
}

pub fn copyPackageFiles(
    allocator: std.mem.Allocator,
    source_dir: []const u8,
    dest_dir: []const u8,
    exclude_patterns: []const []const u8,
    package_import_base: []const u8,
    package_version: []const u8,
    package_entrypoint: []const u8,
) !void {
    try std.fs.cwd().makePath(dest_dir);

    const full_package_import = try std.fmt.allocPrint(allocator, "@{s}:{s}", .{ package_import_base, package_version });
    defer allocator.free(full_package_import);

    const entrypoint_name = std.fs.path.basename(package_entrypoint);
    try copyPackageFilesRecursive(allocator, source_dir, dest_dir, "", exclude_patterns, entrypoint_name, full_package_import);
}

pub fn parseGitSource(allocator: std.mem.Allocator, input: []const u8) !GitSource {
    if (try tryParseAliasForm(allocator, input)) |source| return source;
    return parseGitUrl(allocator, input);
}

pub fn cloneRepository(allocator: std.mem.Allocator, source: *const GitSource, clone_dir: []const u8) !void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, &.{ "git", "clone", "--depth", "1" });
    if (source.git_ref) |git_ref| {
        try argv.appendSlice(allocator, &.{ "--branch", git_ref });
    }
    try argv.appendSlice(allocator, &.{ source.repo_url_for_clone, clone_dir });

    try runProcessCheckedOwned(allocator, argv.items, "Failed to clone repository.");
}

pub fn collectTypstTomlFiles(allocator: std.mem.Allocator, dir_path: []const u8, out: *std.ArrayList([]u8)) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        const child_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        errdefer allocator.free(child_path);

        switch (entry.kind) {
            .file => {
                if (std.mem.eql(u8, entry.name, "typst.toml")) {
                    try out.append(allocator, child_path);
                    continue;
                }
            },
            .directory => {
                if (std.mem.eql(u8, entry.name, ".git")) {
                    allocator.free(child_path);
                    continue;
                }
                try collectTypstTomlFiles(allocator, child_path, out);
                allocator.free(child_path);
                continue;
            },
            else => {},
        }

        allocator.free(child_path);
    }
}

pub fn relativeParentDir(allocator: std.mem.Allocator, root: []const u8, file_path: []const u8) ![]u8 {
    const parent = std.fs.path.dirname(file_path) orelse return allocator.dupe(u8, ".");
    return std.fs.path.relative(allocator, root, parent);
}

pub fn typstDataDir(allocator: std.mem.Allocator) ![]u8 {
    return switch (builtin.os.tag) {
        .windows => blk: {
            const base = getEnvOrHomeFallback(allocator, &.{"APPDATA"}, &.{ "AppData", "Roaming" }) catch |err| break :blk err;
            defer allocator.free(base);
            break :blk std.fs.path.join(allocator, &.{ base, "typst" });
        },
        .macos => blk: {
            const base = try getHomeWithSuffix(allocator, &.{ "Library", "Application Support" });
            defer allocator.free(base);
            break :blk std.fs.path.join(allocator, &.{ base, "typst" });
        },
        else => blk: {
            const base = getEnvOrHomeFallback(allocator, &.{"XDG_DATA_HOME"}, &.{ ".local", "share" }) catch |err| break :blk err;
            defer allocator.free(base);
            break :blk std.fs.path.join(allocator, &.{ base, "typst" });
        },
    };
}

pub fn typstCacheDir(allocator: std.mem.Allocator) ![]u8 {
    return switch (builtin.os.tag) {
        .windows => blk: {
            const base = getEnvOrHomeFallback(allocator, &.{"LOCALAPPDATA"}, &.{ "AppData", "Local" }) catch |err| break :blk err;
            defer allocator.free(base);
            break :blk std.fs.path.join(allocator, &.{ base, "typst" });
        },
        .macos => blk: {
            const base = try getHomeWithSuffix(allocator, &.{ "Library", "Caches" });
            defer allocator.free(base);
            break :blk std.fs.path.join(allocator, &.{ base, "typst" });
        },
        else => blk: {
            const base = getEnvOrHomeFallback(allocator, &.{"XDG_CACHE_HOME"}, &.{".cache"}) catch |err| break :blk err;
            defer allocator.free(base);
            break :blk std.fs.path.join(allocator, &.{ base, "typst" });
        },
    };
}

pub fn fileExists(path: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

pub fn dirExists(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

pub fn failWithDetail(message: []const u8, detail: []const u8) noreturn {
    printError(message, if (detail.len == 0) null else detail) catch {};
    std.process.exit(1);
}

pub fn printError(message: []const u8, detail: ?[]const u8) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    if (detail) |value| {
        try stderr_writer.interface.print("{s} {s}\n", .{ message, value });
    } else {
        try stderr_writer.interface.print("{s}\n", .{message});
    }
    try stderr_writer.interface.flush();
}

pub fn printRawError(message: []const u8) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    try stderr_writer.interface.print("{s}", .{message});
    if (!std.mem.endsWith(u8, message, "\n")) {
        try stderr_writer.interface.print("\n", .{});
    }
    try stderr_writer.interface.flush();
}

pub fn providerPrefixForHost(host: []const u8) []const u8 {
    if (std.mem.eql(u8, host, "github.com")) return "gh";
    if (std.mem.eql(u8, host, "gitlab.com")) return "gl";
    if (std.mem.eql(u8, host, "bitbucket.org")) return "bb";
    return host;
}

pub fn promptSelection(max_choice: usize) !usize {
    var stdout_buffer: [128]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout_writer.interface.print("Enter number (1-{d}): ", .{max_choice});
    try stdout_writer.interface.flush();

    var stdin = std.fs.File.stdin();
    var input_buffer: [128]u8 = undefined;
    const bytes_read = try stdin.read(&input_buffer);
    const trimmed = std.mem.trim(u8, input_buffer[0..bytes_read], " \t\r\n");
    return std.fmt.parseInt(usize, trimmed, 10);
}

fn compareSemver(a: std.SemanticVersion, b: std.SemanticVersion) i8 {
    if (a.major < b.major) return -1;
    if (a.major > b.major) return 1;
    if (a.minor < b.minor) return -1;
    if (a.minor > b.minor) return 1;
    if (a.patch < b.patch) return -1;
    if (a.patch > b.patch) return 1;
    return 0;
}

fn copyPackageFilesRecursive(
    allocator: std.mem.Allocator,
    source_dir: []const u8,
    dest_dir: []const u8,
    rel_dir: []const u8,
    exclude_patterns: []const []const u8,
    entrypoint_name: []const u8,
    full_package_import: []const u8,
) !void {
    const current_source = if (rel_dir.len == 0)
        try allocator.dupe(u8, source_dir)
    else
        try std.fs.path.join(allocator, &.{ source_dir, rel_dir });
    defer allocator.free(current_source);

    var dir = try std.fs.cwd().openDir(current_source, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        const rel_path = if (rel_dir.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ rel_dir, entry.name });
        defer allocator.free(rel_path);

        if (try shouldExclude(allocator, rel_path, entry.kind, source_dir, exclude_patterns)) {
            continue;
        }

        const src_path = try std.fs.path.join(allocator, &.{ source_dir, rel_path });
        defer allocator.free(src_path);
        const dst_path = try std.fs.path.join(allocator, &.{ dest_dir, rel_path });
        defer allocator.free(dst_path);

        switch (entry.kind) {
            .directory => {
                try std.fs.cwd().makePath(dst_path);
                try copyPackageFilesRecursive(allocator, source_dir, dest_dir, rel_path, exclude_patterns, entrypoint_name, full_package_import);
            },
            .file => {
                if (std.fs.path.dirname(dst_path)) |parent| {
                    try std.fs.cwd().makePath(parent);
                }

                if (std.mem.eql(u8, entry.name, "typst.toml")) {
                    const content = try std.fs.cwd().readFileAlloc(allocator, src_path, 1024 * 1024);
                    defer allocator.free(content);

                    const filtered = try removeSchemaLines(allocator, content);
                    defer allocator.free(filtered);
                    try writeFile(dst_path, filtered);
                } else if (std.mem.endsWith(u8, entry.name, ".typ")) {
                    const content = try std.fs.cwd().readFileAlloc(allocator, src_path, 1024 * 1024);
                    defer allocator.free(content);

                    const rewritten = try rewriteImports(allocator, content, entrypoint_name, full_package_import);
                    defer allocator.free(rewritten);
                    try writeFile(dst_path, rewritten);
                } else {
                    try std.fs.Dir.copyFile(std.fs.cwd(), src_path, std.fs.cwd(), dst_path, .{});
                }
            },
            else => {},
        }
    }
}

fn removeSchemaLines(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var first = true;
    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, std.mem.trimRight(u8, line, "\r"), " \t");
        if (std.mem.startsWith(u8, trimmed, "#:schema")) {
            continue;
        }

        if (!first) try output.append(allocator, '\n');
        first = false;
        try output.appendSlice(allocator, line);
    }

    return output.toOwnedSlice(allocator);
}

fn rewriteImports(allocator: std.mem.Allocator, content: []const u8, entrypoint_name: []const u8, full_package_import: []const u8) ![]u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var first = true;
    while (lines.next()) |line| {
        const rewritten = try rewriteImportLine(allocator, line, entrypoint_name, full_package_import);
        defer allocator.free(rewritten);

        if (!first) try output.append(allocator, '\n');
        first = false;
        try output.appendSlice(allocator, rewritten);
    }

    return output.toOwnedSlice(allocator);
}

fn rewriteImportLine(allocator: std.mem.Allocator, line: []const u8, entrypoint_name: []const u8, full_package_import: []const u8) ![]u8 {
    const import_idx = std.mem.indexOf(u8, line, "#import") orelse return allocator.dupe(u8, line);
    var cursor = import_idx + "#import".len;
    while (cursor < line.len and (line[cursor] == ' ' or line[cursor] == '\t')) : (cursor += 1) {}
    if (cursor >= line.len or line[cursor] != '"') return allocator.dupe(u8, line);

    const quote_start = cursor;
    cursor += 1;
    const quote_end = std.mem.indexOfScalarPos(u8, line, cursor, '"') orelse return allocator.dupe(u8, line);
    const target = line[cursor..quote_end];
    if (!shouldRewriteImport(target, entrypoint_name)) return allocator.dupe(u8, line);

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    try output.appendSlice(allocator, line[0 .. quote_start + 1]);
    try output.appendSlice(allocator, full_package_import);
    try output.appendSlice(allocator, line[quote_end..]);
    return output.toOwnedSlice(allocator);
}

fn shouldRewriteImport(target: []const u8, entrypoint_name: []const u8) bool {
    var rest = target;
    var saw_parent = false;
    while (std.mem.startsWith(u8, rest, "../")) {
        saw_parent = true;
        rest = rest[3..];
    }

    return saw_parent and std.mem.eql(u8, rest, entrypoint_name);
}

fn shouldExclude(allocator: std.mem.Allocator, rel_path: []const u8, entry_kind: std.fs.Dir.Entry.Kind, source_dir: []const u8, patterns: []const []const u8) !bool {
    const normalized_rel = try normalizeToPosix(allocator, rel_path);
    defer allocator.free(normalized_rel);

    for (patterns) |pattern| {
        const trimmed_pattern = std.mem.trim(u8, pattern, " \t\r\n");
        if (trimmed_pattern.len == 0) continue;

        const normalized_pattern = try normalizeToPosix(allocator, trimmed_pattern);
        defer allocator.free(normalized_pattern);

        if (globMatch(normalized_pattern, normalized_rel)) return true;

        if (std.mem.endsWith(u8, normalized_pattern, "/")) {
            const dir_pattern = normalized_pattern[0 .. normalized_pattern.len - 1];
            if (std.mem.eql(u8, normalized_rel, dir_pattern) or startsWithDirPrefix(normalized_rel, dir_pattern)) {
                return true;
            }
        }

        if (!containsGlob(normalized_pattern)) {
            const absolute_candidate = std.fs.path.join(std.heap.page_allocator, &.{ source_dir, trimmed_pattern }) catch continue;
            defer std.heap.page_allocator.free(absolute_candidate);

            if (entry_kind == .directory and dirExists(absolute_candidate)) {
                if (std.mem.eql(u8, normalized_rel, normalized_pattern) or startsWithDirPrefix(normalized_rel, normalized_pattern)) {
                    return true;
                }
            }
        }
    }

    return false;
}

fn normalizeToPosix(allocator: std.mem.Allocator, path_value: []const u8) ![]u8 {
    const normalized = try allocator.dupe(u8, path_value);
    if (std.fs.path.sep == '\\') {
        for (normalized) |*byte| {
            if (byte.* == '\\') byte.* = '/';
        }
    }
    return normalized;
}

fn containsGlob(pattern: []const u8) bool {
    return std.mem.indexOfAny(u8, pattern, "*?[") != null;
}

fn startsWithDirPrefix(rel_path: []const u8, pattern: []const u8) bool {
    return rel_path.len > pattern.len and std.mem.startsWith(u8, rel_path, pattern) and rel_path[pattern.len] == '/';
}

fn globMatch(pattern: []const u8, candidate: []const u8) bool {
    return globMatchInner(pattern, 0, candidate, 0);
}

fn globMatchInner(pattern: []const u8, p_index_start: usize, candidate: []const u8, c_index_start: usize) bool {
    var p_index = p_index_start;
    var c_index = c_index_start;

    while (true) {
        if (p_index >= pattern.len) return c_index >= candidate.len;

        switch (pattern[p_index]) {
            '*' => {
                if (p_index + 1 < pattern.len and pattern[p_index + 1] == '*') {
                    var next_pattern = p_index + 2;
                    while (next_pattern < pattern.len and pattern[next_pattern] == '*') : (next_pattern += 1) {}

                    var next_candidate = c_index;
                    while (true) {
                        if (globMatchInner(pattern, next_pattern, candidate, next_candidate)) return true;
                        if (next_candidate >= candidate.len) return false;
                        next_candidate += 1;
                    }
                }

                var next_candidate = c_index;
                while (true) {
                    if (globMatchInner(pattern, p_index + 1, candidate, next_candidate)) return true;
                    if (next_candidate >= candidate.len) return false;
                    if (candidate[next_candidate] == '/') return false;
                    next_candidate += 1;
                }
            },
            '?' => {
                if (c_index >= candidate.len or candidate[c_index] == '/') return false;
                p_index += 1;
                c_index += 1;
            },
            '[' => {
                const end = findClassEnd(pattern, p_index) orelse return false;
                if (c_index >= candidate.len or candidate[c_index] == '/') return false;
                if (!matchClass(pattern[p_index .. end + 1], candidate[c_index])) return false;
                p_index = end + 1;
                c_index += 1;
            },
            else => {
                if (c_index >= candidate.len or pattern[p_index] != candidate[c_index]) return false;
                p_index += 1;
                c_index += 1;
            },
        }
    }
}

fn findClassEnd(pattern: []const u8, index: usize) ?usize {
    var cursor = index + 1;
    if (cursor < pattern.len and pattern[cursor] == '!') cursor += 1;
    while (cursor < pattern.len) : (cursor += 1) {
        if (pattern[cursor] == ']') return cursor;
    }
    return null;
}

fn matchClass(class_pattern: []const u8, byte: u8) bool {
    const negated = class_pattern.len >= 3 and class_pattern[1] == '!';
    var matched = false;
    var index: usize = if (negated) 2 else 1;
    while (index + 1 < class_pattern.len) : (index += 1) {
        if (class_pattern[index] == ']') break;
        if (class_pattern[index] == byte) {
            matched = true;
            break;
        }
    }
    return if (negated) !matched else matched;
}

fn writeFile(path: []const u8, content: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

fn tryParseAliasForm(allocator: std.mem.Allocator, input: []const u8) !?GitSource {
    var parts = std.mem.splitScalar(u8, input, '/');
    const alias = parts.next() orelse return null;
    const user = parts.next() orelse return null;
    const repo = parts.next() orelse return null;

    const host = blk: {
        if (std.ascii.eqlIgnoreCase(alias, "gh") or std.ascii.eqlIgnoreCase(alias, "github")) break :blk "github.com";
        if (std.ascii.eqlIgnoreCase(alias, "gl") or std.ascii.eqlIgnoreCase(alias, "gitlab")) break :blk "gitlab.com";
        if (std.ascii.eqlIgnoreCase(alias, "bb") or std.ascii.eqlIgnoreCase(alias, "bitbucket")) break :blk "bitbucket.org";
        return null;
    };

    var remainder = std.ArrayList([]const u8).empty;
    defer remainder.deinit(allocator);
    while (parts.next()) |segment| {
        try remainder.append(allocator, segment);
    }

    return GitSource{
        .repo_url_for_clone = try std.fmt.allocPrint(allocator, "https://{s}/{s}/{s}.git", .{ host, user, repo }),
        .git_ref = null,
        .path_in_repo = try joinPathSegments(allocator, remainder.items),
        .provider_host = try allocator.dupe(u8, host),
        .user_or_org = try allocator.dupe(u8, user),
    };
}

fn parseGitUrl(allocator: std.mem.Allocator, input: []const u8) !GitSource {
    const scheme_index = std.mem.indexOf(u8, input, "://") orelse return error.InvalidGitSource;
    const after_scheme = input[scheme_index + 3 ..];
    const host_end = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return error.InvalidGitSource;

    var host = after_scheme[0..host_end];
    if (std.mem.startsWith(u8, host, "www.")) host = host[4..];

    var path = after_scheme[host_end + 1 ..];
    if (std.mem.indexOfAny(u8, path, "?#")) |idx| path = path[0..idx];

    var segments = std.ArrayList([]const u8).empty;
    defer segments.deinit(allocator);

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        try segments.append(allocator, segment);
    }

    if (segments.items.len < 2) return error.InvalidGitSource;

    if (std.mem.eql(u8, host, "github.com")) return parseGithubUrl(allocator, host, segments.items);
    if (std.mem.eql(u8, host, "gitlab.com")) return parseGitlabUrl(allocator, host, segments.items);
    if (std.mem.eql(u8, host, "bitbucket.org")) return parseBitbucketUrl(allocator, host, segments.items);
    return error.UnsupportedGitProvider;
}

fn parseGithubUrl(allocator: std.mem.Allocator, host: []const u8, segments: []const []const u8) !GitSource {
    const user = segments[0];
    const repo = trimGitSuffix(segments[1]);
    var git_ref: ?[]u8 = null;
    var path_parts: []const []const u8 = &.{};

    if (segments.len > 3 and (std.mem.eql(u8, segments[2], "tree") or std.mem.eql(u8, segments[2], "blob"))) {
        git_ref = try allocator.dupe(u8, segments[3]);
        path_parts = segments[4..];
    } else if (segments.len > 2) {
        path_parts = segments[2..];
    }

    return GitSource{
        .repo_url_for_clone = try std.fmt.allocPrint(allocator, "https://{s}/{s}/{s}.git", .{ host, user, repo }),
        .git_ref = git_ref,
        .path_in_repo = try joinPathSegments(allocator, path_parts),
        .provider_host = try allocator.dupe(u8, host),
        .user_or_org = try allocator.dupe(u8, user),
    };
}

fn parseGitlabUrl(allocator: std.mem.Allocator, host: []const u8, segments: []const []const u8) !GitSource {
    const user = segments[0];
    const repo = trimGitSuffix(segments[1]);
    var git_ref: ?[]u8 = null;
    var path_parts: []const []const u8 = &.{};

    if (segments.len > 4 and std.mem.eql(u8, segments[2], "-") and (std.mem.eql(u8, segments[3], "tree") or std.mem.eql(u8, segments[3], "blob"))) {
        git_ref = try allocator.dupe(u8, segments[4]);
        path_parts = segments[5..];
    } else if (segments.len > 2) {
        path_parts = segments[2..];
    }

    return GitSource{
        .repo_url_for_clone = try std.fmt.allocPrint(allocator, "https://{s}/{s}/{s}.git", .{ host, user, repo }),
        .git_ref = git_ref,
        .path_in_repo = try joinPathSegments(allocator, path_parts),
        .provider_host = try allocator.dupe(u8, host),
        .user_or_org = try allocator.dupe(u8, user),
    };
}

fn parseBitbucketUrl(allocator: std.mem.Allocator, host: []const u8, segments: []const []const u8) !GitSource {
    const user = segments[0];
    const repo = trimGitSuffix(segments[1]);
    const path_parts = if (segments.len > 2) segments[2..] else &.{};

    return GitSource{
        .repo_url_for_clone = try std.fmt.allocPrint(allocator, "https://{s}/{s}/{s}.git", .{ host, user, repo }),
        .git_ref = null,
        .path_in_repo = try joinPathSegments(allocator, path_parts),
        .provider_host = try allocator.dupe(u8, host),
        .user_or_org = try allocator.dupe(u8, user),
    };
}

fn joinPathSegments(allocator: std.mem.Allocator, segments: []const []const u8) ![]u8 {
    if (segments.len == 0) return allocator.dupe(u8, "");

    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);
    for (segments, 0..) |segment, index| {
        if (index != 0) try builder.append(allocator, std.fs.path.sep);
        try builder.appendSlice(allocator, segment);
    }
    return builder.toOwnedSlice(allocator);
}

fn trimGitSuffix(segment: []const u8) []const u8 {
    if (std.mem.endsWith(u8, segment, ".git")) return segment[0 .. segment.len - 4];
    return segment;
}

fn getEnvOrHomeFallback(allocator: std.mem.Allocator, env_names: []const []const u8, home_suffix: []const []const u8) ![]u8 {
    for (env_names) |name| {
        if (std.process.getEnvVarOwned(allocator, name)) |value| {
            return value;
        } else |err| switch (err) {
            error.EnvironmentVariableNotFound => continue,
            else => return err,
        }
    }
    return getHomeWithSuffix(allocator, home_suffix);
}

fn getHomeWithSuffix(allocator: std.mem.Allocator, suffix: []const []const u8) ![]u8 {
    const home = try getHomeDir(allocator);
    defer allocator.free(home);

    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);
    try parts.append(allocator, home);
    try parts.appendSlice(allocator, suffix);
    return std.fs.path.join(allocator, parts.items);
}

fn getHomeDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |value| {
            return value;
        } else |err| switch (err) {
            error.EnvironmentVariableNotFound => {},
            else => return err,
        }

        if (std.process.getEnvVarOwned(allocator, "HOME")) |value| {
            return value;
        } else |err| switch (err) {
            error.EnvironmentVariableNotFound => return error.HomeDirectoryNotFound,
            else => return err,
        }
    }

    return std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => error.HomeDirectoryNotFound,
        else => err,
    };
}

fn runProcessChecked(allocator: std.mem.Allocator, argv: []const []const u8, failure_message: []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term.Exited != 0) {
        printError(failure_message, null) catch {};
        if (result.stdout.len > 0) printRawError(result.stdout) catch {};
        if (result.stderr.len > 0) printRawError(result.stderr) catch {};
        std.process.exit(1);
    }
}

fn runProcessCheckedOwned(allocator: std.mem.Allocator, argv: []const []const u8, failure_message: []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term.Exited != 0) {
        if (result.stderr.len > 0) {
            printRawError(result.stderr) catch {};
        } else {
            printError(failure_message, null) catch {};
        }
        std.process.exit(1);
    }
}

test "parse alias git source" {
    const testing = std.testing;
    const expected_path = if (std.fs.path.sep == '\\') "templates\\report" else "templates/report";

    var source = try parseGitSource(testing.allocator, "gh/example/demo/templates/report");
    defer source.deinit(testing.allocator);

    try testing.expectEqualStrings("https://github.com/example/demo.git", source.repo_url_for_clone);
    try testing.expect(source.git_ref == null);
    try testing.expectEqualStrings(expected_path, source.path_in_repo);
}

test "matches version requirements" {
    const version = std.SemanticVersion.parse("0.13.0") catch unreachable;
    try std.testing.expect(matchesVersionReq(">=0.12.0 <0.14.0", version));
    try std.testing.expect(!matchesVersionReq(">=0.14.0", version));
}
