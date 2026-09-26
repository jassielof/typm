const std = @import("std");

const toml = @import("toml");

const GitSource = @import("GitSource.zig");

/// Set once from `main` before any command runs, since environment access
/// requires the `Environ` handed to us by `std.process.Init`.
pub var process_environ: std.process.Environ = .empty;

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

pub fn readPackageFile(allocator: std.mem.Allocator, io: std.Io, toml_path: []const u8) !PackageFile {
    // Not freed: `toml.parse` may return string fields that borrow slices
    // directly from this buffer instead of duplicating them. Callers pass an
    // arena allocator that reclaims this when the command finishes.
    const content = try std.Io.Dir.cwd().readFileAlloc(io, toml_path, allocator, .limited(1024 * 1024));

    return toml.parse(PackageFile, allocator, content);
}

pub fn resolveTomlPath(allocator: std.mem.Allocator, io: std.Io, input_path: []const u8) ![]u8 {
    if (fileExists(io, input_path)) {
        return allocator.dupe(u8, input_path);
    }

    if (dirExists(io, input_path)) {
        const candidate = try std.fs.path.join(allocator, &.{ input_path, "typst.toml" });
        errdefer allocator.free(candidate);

        if (!fileExists(io, candidate)) {
            failWithDetail(io, "No typst.toml found in directory:", input_path);
        }

        return candidate;
    }

    failWithDetail(io, "Path is neither a file nor a directory:", input_path);
}

pub fn validatePackageConfig(io: std.Io, name: ?[]const u8, version: ?[]const u8) void {
    if (name == null or version == null) {
        failWithDetail(io, "Error: 'package.name' and 'package.version' are required.", "");
    }
}

pub fn validatePackageName(io: std.Io, package_name: []const u8, toml_dir: []const u8) void {
    const dir_name = std.fs.path.basename(toml_dir);
    if (!std.mem.eql(u8, package_name, dir_name)) {
        var buffer: [4096]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "Package name '{s}' does not match parent directory name '{s}'", .{ package_name, dir_name }) catch "Package name does not match parent directory name";
        failWithDetail(io, message, "");
    }
}

pub fn getTypstVersion(io: std.Io) !std.SemanticVersion {
    const allocator = std.heap.page_allocator;
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "typst", "--version" },
    }) catch |err| switch (err) {
        error.FileNotFound => {
            failWithDetail(io, "typst was not found on PATH.", "Install Typst and make sure it is available on PATH: https://github.com/typst/typst#installation");
        },
        else => return error.TypstNotFound,
    };

    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term != .exited or result.term.exited != 0) {
        return error.TypstNotFound;
    }

    const stdout = std.mem.trim(u8, result.stdout, "\n\r\t ");
    var it = std.mem.splitScalar(u8, stdout, ' ');
    _ = it.next() orelse return error.InvalidOutput;
    const version_str = it.next() orelse return error.InvalidOutput;
    return std.SemanticVersion.parse(version_str) catch error.InvalidSemver;
}

pub fn checkCompilerVersion(io: std.Io, compiler_req: ?[]const u8) void {
    const req = compiler_req orelse return;
    const current = getTypstVersion(io) catch {
        failWithDetail(io, "Failed to determine Typst version.", "");
    };

    if (!matchesVersionReq(req, current)) {
        var buffer: [256]u8 = undefined;
        const current_str = std.fmt.bufPrint(&buffer, "{d}.{d}.{d}", .{ current.major, current.minor, current.patch }) catch "<unknown>";
        var message_buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buffer, "Package requires Typst version '{s}', but you have {s}.", .{ req, current_str }) catch "Package requires a different Typst version.";
        failWithDetail(io, message, "");
    }

    var stdout_buffer: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    writer.interface.print("Typst version check passed (required: {s}, current: {d}.{d}.{d}).\n", .{ req, current.major, current.minor, current.patch }) catch {};
    writer.interface.flush() catch {};
}

const version_operators = [_][]const u8{ ">=", "<=", "==", "!=", ">", "<", "=" };

const SplitRequirement = struct {
    operator: []const u8,
    /// The version text after the operator; empty when the version is a separate token.
    version: []const u8,
};

/// Splits a leading comparison operator off `token`; a bare version means "at least".
fn splitOperator(token: []const u8) SplitRequirement {
    for (version_operators) |candidate| {
        if (std.mem.startsWith(u8, token, candidate)) return .{ .operator = candidate, .version = token[candidate.len..] };
    }
    return .{ .operator = ">=", .version = token };
}

/// Whether a comparison result (`-1`, `0`, `1` for less, equal, greater) satisfies `operator`.
fn satisfiesOperator(operator: []const u8, cmp: i8) bool {
    if (std.mem.eql(u8, operator, ">")) return cmp > 0;
    if (std.mem.eql(u8, operator, "<")) return cmp < 0;
    if (std.mem.eql(u8, operator, ">=")) return cmp >= 0;
    if (std.mem.eql(u8, operator, "<=")) return cmp <= 0;
    if (std.mem.eql(u8, operator, "!=")) return cmp != 0;
    return cmp == 0;
}

pub fn matchesVersionReq(req: []const u8, version: std.SemanticVersion) bool {
    var tokens = std.mem.tokenizeAny(u8, req, " \t\r\n");
    while (tokens.next()) |token| {
        const split = splitOperator(token);
        const version_str = if (split.version.len == 0) tokens.next() orelse return false else split.version;

        const required = std.SemanticVersion.parse(version_str) catch return false;
        if (!satisfiesOperator(split.operator, compareSemver(version, required))) return false;
    }

    return true;
}

pub fn buildTemplate(allocator: std.mem.Allocator, io: std.Io, toml_dir: []const u8, package_name: []const u8, template: ?TemplateSection) !void {
    const template_section = template orelse return;
    const template_path = template_section.path orelse return;
    const template_entrypoint = template_section.entrypoint orelse return;
    const project_root = std.fs.path.dirname(toml_dir) orelse ".";

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    try stdout_writer.interface.print("Compiling template: {s}/{s}\n", .{ template_path, template_entrypoint });
    try stdout_writer.interface.flush();

    const input_path = try std.fs.path.join(allocator, &.{ project_root, package_name, template_path, template_entrypoint });
    defer allocator.free(input_path);

    try runProcessChecked(allocator, io, &.{ "typst", "compile", "--root", project_root, input_path }, "Template compilation failed.");

    if (template_section.thumbnail) |thumbnail_path| {
        try stdout_writer.interface.print("Generating thumbnail: {s}\n", .{thumbnail_path});
        try stdout_writer.interface.flush();

        const output_path = try std.fs.path.join(allocator, &.{ project_root, package_name, thumbnail_path });
        defer allocator.free(output_path);

        try runProcessChecked(allocator, io, &.{ "typst", "compile", "--root", project_root, "--pages", "1", input_path, output_path }, "Thumbnail generation failed.");
    }
}

pub fn copyPackageFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: []const u8,
    dest_dir: []const u8,
    exclude_patterns: []const []const u8,
    package_import_base: []const u8,
    package_version: []const u8,
    package_entrypoint: []const u8,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, dest_dir);

    const full_package_import = try std.fmt.allocPrint(allocator, "@{s}:{s}", .{ package_import_base, package_version });
    defer allocator.free(full_package_import);

    const entrypoint_name = std.fs.path.basename(package_entrypoint);
    try copyPackageFilesRecursive(allocator, io, source_dir, dest_dir, "", exclude_patterns, entrypoint_name, full_package_import);
}

pub fn parseGitSource(allocator: std.mem.Allocator, input: []const u8) !GitSource {
    if (try tryParseAliasForm(allocator, input)) |source| return source;
    return parseGitUrl(allocator, input);
}

pub fn cloneRepository(allocator: std.mem.Allocator, io: std.Io, source: *const GitSource, clone_dir: []const u8) !void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, &.{ "git", "clone", "--depth", "1" });
    if (source.git_ref) |git_ref| {
        try argv.appendSlice(allocator, &.{ "--branch", git_ref });
    }
    try argv.appendSlice(allocator, &.{ source.repo_url_for_clone, clone_dir });

    try runProcessCheckedOwned(allocator, io, argv.items, "Failed to clone repository.");
}

pub fn collectTypstTomlFiles(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, out: *std.ArrayList([]u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
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
                try collectTypstTomlFiles(allocator, io, child_path, out);
                allocator.free(child_path);
                continue;
            },
            else => {},
        }

        allocator.free(child_path);
    }
}

pub fn relativeParentDir(allocator: std.mem.Allocator, io: std.Io, root: []const u8, file_path: []const u8) ![]u8 {
    const parent = std.fs.path.dirname(file_path) orelse return allocator.dupe(u8, ".");
    return relativePath(allocator, io, root, parent);
}

pub fn relativePath(allocator: std.mem.Allocator, io: std.Io, from: []const u8, to: []const u8) ![]u8 {
    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try std.Io.Dir.cwd().realPath(io, &cwd_buffer);
    return std.fs.path.relative(allocator, cwd_buffer[0..cwd_len], null, from, to);
}

pub fn fileExists(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false }) catch return false;
    file.close(io);
    return true;
}

pub fn dirExists(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

pub fn failWithDetail(io: std.Io, message: []const u8, detail: []const u8) noreturn {
    printError(io, message, if (detail.len == 0) null else detail) catch {};
    std.process.exit(1);
}

pub fn printError(io: std.Io, message: []const u8, detail: ?[]const u8) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    if (detail) |value| {
        try stderr_writer.interface.print("{s} {s}\n", .{ message, value });
    } else {
        try stderr_writer.interface.print("{s}\n", .{message});
    }
    try stderr_writer.interface.flush();
}

pub fn printRawError(io: std.Io, message: []const u8) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
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

pub fn promptSelection(io: std.Io, max_choice: usize) !usize {
    var stdout_buffer: [128]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    try stdout_writer.interface.print("Enter number (1-{d}): ", .{max_choice});
    try stdout_writer.interface.flush();

    const stdin = std.Io.File.stdin();
    var read_buffer: [128]u8 = undefined;
    var stdin_reader = stdin.reader(io, &read_buffer);
    var input_buffer: [128]u8 = undefined;
    const bytes_read = try stdin_reader.interface.readSliceShort(&input_buffer);
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
    io: std.Io,
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

    var dir = try std.Io.Dir.cwd().openDir(io, current_source, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const rel_path = if (rel_dir.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ rel_dir, entry.name });
        defer allocator.free(rel_path);

        if (try shouldExclude(allocator, io, rel_path, entry.kind, source_dir, exclude_patterns)) {
            continue;
        }

        const src_path = try std.fs.path.join(allocator, &.{ source_dir, rel_path });
        defer allocator.free(src_path);
        const dst_path = try std.fs.path.join(allocator, &.{ dest_dir, rel_path });
        defer allocator.free(dst_path);

        switch (entry.kind) {
            .directory => {
                try std.Io.Dir.cwd().createDirPath(io, dst_path);
                try copyPackageFilesRecursive(allocator, io, source_dir, dest_dir, rel_path, exclude_patterns, entrypoint_name, full_package_import);
            },
            .file => {
                if (std.fs.path.dirname(dst_path)) |parent| {
                    try std.Io.Dir.cwd().createDirPath(io, parent);
                }

                if (std.mem.eql(u8, entry.name, "typst.toml")) {
                    const content = try std.Io.Dir.cwd().readFileAlloc(io, src_path, allocator, .limited(1024 * 1024));
                    defer allocator.free(content);

                    const filtered = try removeSchemaLines(allocator, content);
                    defer allocator.free(filtered);
                    try writeFile(io, dst_path, filtered);
                } else if (std.mem.endsWith(u8, entry.name, ".typ")) {
                    const content = try std.Io.Dir.cwd().readFileAlloc(io, src_path, allocator, .limited(1024 * 1024));
                    defer allocator.free(content);

                    const rewritten = try rewriteImports(allocator, content, entrypoint_name, full_package_import);
                    defer allocator.free(rewritten);
                    try writeFile(io, dst_path, rewritten);
                } else {
                    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), src_path, std.Io.Dir.cwd(), dst_path, io, .{});
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
        const trimmed = std.mem.trimStart(u8, std.mem.trimEnd(u8, line, "\r"), " \t");
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

fn shouldExclude(allocator: std.mem.Allocator, io: std.Io, rel_path: []const u8, entry_kind: std.Io.File.Kind, source_dir: []const u8, patterns: []const []const u8) !bool {
    const normalized_rel = try normalizeToPosix(allocator, rel_path);
    defer allocator.free(normalized_rel);

    for (patterns) |pattern| {
        const trimmed_pattern = std.mem.trim(u8, pattern, " \t\r\n");
        if (trimmed_pattern.len == 0) continue;

        if (try patternExcludes(allocator, io, normalized_rel, entry_kind, source_dir, trimmed_pattern)) return true;
    }

    return false;
}

/// Whether a single, already trimmed pattern excludes `normalized_rel`: as a glob, as a `dir/` pattern, or as the plain name of a directory that exists in `source_dir`.
fn patternExcludes(allocator: std.mem.Allocator, io: std.Io, normalized_rel: []const u8, entry_kind: std.Io.File.Kind, source_dir: []const u8, pattern: []const u8) !bool {
    const normalized_pattern = try normalizeToPosix(allocator, pattern);
    defer allocator.free(normalized_pattern);

    if (globMatch(normalized_pattern, normalized_rel)) return true;
    if (matchesDirectoryPattern(normalized_rel, normalized_pattern)) return true;
    if (containsGlob(normalized_pattern)) return false;

    return isExistingDirectory(io, entry_kind, source_dir, pattern) and isSameOrBelow(normalized_rel, normalized_pattern);
}

/// A pattern with a trailing slash names a directory: it matches the directory itself and everything below it.
fn matchesDirectoryPattern(rel_path: []const u8, pattern: []const u8) bool {
    if (!std.mem.endsWith(u8, pattern, "/")) return false;
    return isSameOrBelow(rel_path, pattern[0 .. pattern.len - 1]);
}

fn isSameOrBelow(rel_path: []const u8, directory: []const u8) bool {
    return std.mem.eql(u8, rel_path, directory) or startsWithDirPrefix(rel_path, directory);
}

/// Whether `entry_kind` is a directory and `pattern`, taken relative to `source_dir`, names a directory that exists.
fn isExistingDirectory(io: std.Io, entry_kind: std.Io.File.Kind, source_dir: []const u8, pattern: []const u8) bool {
    if (entry_kind != .directory) return false;

    const absolute_candidate = std.fs.path.join(std.heap.page_allocator, &.{ source_dir, pattern }) catch return false;
    defer std.heap.page_allocator.free(absolute_candidate);

    return dirExists(io, absolute_candidate);
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

    while (p_index < pattern.len) : (c_index += 1) {
        if (pattern[p_index] == '*') return matchStar(pattern, p_index, candidate, c_index);
        p_index += matchToken(pattern, p_index, candidate, c_index) orelse return false;
    }

    return c_index >= candidate.len;
}

/// A `*` matches within a path segment and `**` also crosses `/`. Tries the rest of the pattern at every position the star could end.
fn matchStar(pattern: []const u8, star_index: usize, candidate: []const u8, c_index_start: usize) bool {
    const crosses_separators = star_index + 1 < pattern.len and pattern[star_index + 1] == '*';

    var rest = star_index + 1;
    while (crosses_separators and rest < pattern.len and pattern[rest] == '*') rest += 1;

    var c_index = c_index_start;
    while (true) {
        if (globMatchInner(pattern, rest, candidate, c_index)) return true;
        if (c_index >= candidate.len) return false;
        if (!crosses_separators and candidate[c_index] == '/') return false;
        c_index += 1;
    }
}

/// Matches the single non-star token at `pattern[p_index]` against `candidate[c_index]`, returning how many pattern bytes it used or null when it does not match. Every such token consumes exactly one candidate byte.
fn matchToken(pattern: []const u8, p_index: usize, candidate: []const u8, c_index: usize) ?usize {
    if (c_index >= candidate.len) return null;
    const byte = candidate[c_index];

    return switch (pattern[p_index]) {
        '?' => if (byte == '/') null else 1,
        '[' => matchClassToken(pattern, p_index, byte),
        else => if (pattern[p_index] == byte) 1 else null,
    };
}

/// Matches a `[...]` class starting at `pattern[p_index]`; a class never matches `/`.
fn matchClassToken(pattern: []const u8, p_index: usize, byte: u8) ?usize {
    const end = findClassEnd(pattern, p_index) orelse return null;
    if (byte == '/' or !matchClass(pattern[p_index .. end + 1], byte)) return null;
    return end + 1 - p_index;
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

fn writeFile(io: std.Io, path: []const u8, content: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, content);
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

fn failOnMissingTool(io: std.Io, err: std.process.RunError, program: []const u8) noreturn {
    if (err == error.FileNotFound) {
        var buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "'{s}' was not found on PATH.", .{program}) catch "Required tool was not found on PATH.";
        failWithDetail(io, message, "Install it and make sure it is available on PATH.");
    }
    failWithDetail(io, "Failed to launch process:", program);
}

fn runProcessChecked(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, failure_message: []const u8) !void {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
    }) catch |err| return failOnMissingTool(io, err, argv[0]);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term != .exited or result.term.exited != 0) {
        printError(io, failure_message, null) catch {};
        if (result.stdout.len > 0) printRawError(io, result.stdout) catch {};
        if (result.stderr.len > 0) printRawError(io, result.stderr) catch {};
        std.process.exit(1);
    }
}

fn runProcessCheckedOwned(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, failure_message: []const u8) !void {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
    }) catch |err| return failOnMissingTool(io, err, argv[0]);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term != .exited or result.term.exited != 0) {
        if (result.stderr.len > 0) {
            printRawError(io, result.stderr) catch {};
        } else {
            printError(io, failure_message, null) catch {};
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

test "glob patterns keep `*` within a path segment and let `**` cross them" {
    const cases = [_]struct { pattern: []const u8, candidate: []const u8, expected: bool }{
        .{ .pattern = "*.typ", .candidate = "a.typ", .expected = true },
        .{ .pattern = "*.typ", .candidate = "dir/a.typ", .expected = false },
        .{ .pattern = "*/x", .candidate = "a/x", .expected = true },
        .{ .pattern = "*/x", .candidate = "a/b/x", .expected = false },
        .{ .pattern = "**/*.typ", .candidate = "dir/sub/a.typ", .expected = true },
        .{ .pattern = "**", .candidate = "a/b", .expected = true },
        .{ .pattern = "dir/**", .candidate = "dir/a/b", .expected = true },
        .{ .pattern = "a**b", .candidate = "a/x/b", .expected = true },
        .{ .pattern = "*", .candidate = "", .expected = true },
        .{ .pattern = "a*", .candidate = "a", .expected = true },
        .{ .pattern = "", .candidate = "", .expected = true },
        .{ .pattern = "", .candidate = "a", .expected = false },
        .{ .pattern = "abc", .candidate = "abd", .expected = false },
        .{ .pattern = "abc", .candidate = "ab", .expected = false },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.expected, globMatch(case.pattern, case.candidate));
    }
}

test "glob `?` and character classes match one non-separator byte" {
    const cases = [_]struct { pattern: []const u8, candidate: []const u8, expected: bool }{
        .{ .pattern = "a?c", .candidate = "abc", .expected = true },
        .{ .pattern = "a?c", .candidate = "a/c", .expected = false },
        .{ .pattern = "a?c", .candidate = "ac", .expected = false },
        .{ .pattern = "[abc]x", .candidate = "bx", .expected = true },
        .{ .pattern = "[abc]x", .candidate = "dx", .expected = false },
        .{ .pattern = "[!abc]x", .candidate = "dx", .expected = true },
        .{ .pattern = "[!abc]x", .candidate = "ax", .expected = false },
        .{ .pattern = "[abc", .candidate = "a", .expected = false },
        .{ .pattern = "[a/]x", .candidate = "/x", .expected = false },
        .{ .pattern = "[abc]", .candidate = "", .expected = false },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.expected, globMatch(case.pattern, case.candidate));
    }
}

test "shouldExclude honors globs, directory patterns, and existing directory names" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "out");
    const source = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source);

    const cases = [_]struct { rel: []const u8, kind: std.Io.File.Kind, patterns: []const []const u8, expected: bool }{
        // Glob patterns.
        .{ .rel = "a.tmp", .kind = .file, .patterns = &.{"*.tmp"}, .expected = true },
        .{ .rel = "sub/a.tmp", .kind = .file, .patterns = &.{"*.tmp"}, .expected = false },
        .{ .rel = "sub/a.tmp", .kind = .file, .patterns = &.{"**/*.tmp"}, .expected = true },
        // A trailing slash names a directory and everything below it.
        .{ .rel = "build", .kind = .directory, .patterns = &.{"build/"}, .expected = true },
        .{ .rel = "build/x.txt", .kind = .file, .patterns = &.{"build/"}, .expected = true },
        .{ .rel = "builder", .kind = .directory, .patterns = &.{"build/"}, .expected = false },
        // A plain name matches itself outright; things below it are only excluded when it is a real directory.
        .{ .rel = "out", .kind = .directory, .patterns = &.{"out"}, .expected = true },
        .{ .rel = "out/sub", .kind = .directory, .patterns = &.{"out"}, .expected = true },
        .{ .rel = "ghost/sub", .kind = .directory, .patterns = &.{"ghost"}, .expected = false },
        .{ .rel = "out/sub", .kind = .file, .patterns = &.{"out"}, .expected = false },
        // Blank patterns are ignored and any matching pattern is enough.
        .{ .rel = "a.tmp", .kind = .file, .patterns = &.{ "  ", "", "*.tmp" }, .expected = true },
        .{ .rel = "a.txt", .kind = .file, .patterns = &.{ "  ", "" }, .expected = false },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.expected, try shouldExclude(allocator, io, case.rel, case.kind, source, case.patterns));
    }
}

test "version requirements support every comparison operator" {
    const version = std.SemanticVersion.parse("0.13.0") catch unreachable;
    const cases = [_]struct { req: []const u8, expected: bool }{
        .{ .req = ">0.12.0", .expected = true },
        .{ .req = ">0.13.0", .expected = false },
        .{ .req = "<0.14.0", .expected = true },
        .{ .req = "<0.13.0", .expected = false },
        .{ .req = ">=0.13.0", .expected = true },
        .{ .req = ">=0.13.1", .expected = false },
        .{ .req = "<=0.13.0", .expected = true },
        .{ .req = "<=0.12.9", .expected = false },
        .{ .req = "==0.13.0", .expected = true },
        .{ .req = "=0.13.0", .expected = true },
        .{ .req = "=0.13.1", .expected = false },
        .{ .req = "!=0.13.0", .expected = false },
        .{ .req = "!=0.12.0", .expected = true },
        // A bare version means "at least".
        .{ .req = "0.13.0", .expected = true },
        .{ .req = "0.14.0", .expected = false },
        // The operator may be separated from its version.
        .{ .req = ">= 0.12.0", .expected = true },
        .{ .req = ">= 0.14.0", .expected = false },
        // Every part of a requirement has to hold.
        .{ .req = ">=0.12.0 <0.13.0", .expected = false },
        .{ .req = ">=0.12.0 !=0.13.0", .expected = false },
        // Malformed requirements never match.
        .{ .req = ">=", .expected = false },
        .{ .req = ">=not-a-version", .expected = false },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.expected, matchesVersionReq(case.req, version));
    }
}
