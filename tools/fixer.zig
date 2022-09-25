//! Fix package metadata by GitHub REST API

const std = @import("std");
const mem = std.mem;
const log = std.log;
const fs = std.fs;
const json = std.json;
const http = @import("http.zig");
const PackageDescription = @import("shared.zig").PackageDescription;

const GITHUB_ROOT = "https://api.github.com";
const MAX_JSON_SIZE = 4096;

// This struct define which fields to fill in
const Repository = struct {
    homepage: ?[]const u8,
    updated_at: ?[]const u8,
    license: ?struct {
        key: []const u8,
    },
};

fn fetchRepositoryMetadata(allocator: mem.Allocator, hc: http.Client, repo_name: []const u8) !Repository {
    const url = try std.fmt.allocPrintZ(allocator, "{s}/repos/{s}", .{ GITHUB_ROOT, repo_name });
    defer allocator.free(url);

    return try hc.json(Repository, url);
}

fn githubRepoName(packageGit: []const u8) ?[]const u8 {
    const prefix = "github.com/";
    if (mem.indexOf(u8, packageGit, prefix)) |idx| {
        return packageGit[idx + prefix.len ..];
    }
    return null;
}

fn fillGitHubPackage(allocator: mem.Allocator, hc: http.Client, file: fs.File) !void {
    var buf = std.ArrayList(u8).init(allocator);
    try file.reader().readAllArrayList(&buf, MAX_JSON_SIZE);
    defer buf.deinit();

    var stream = json.TokenStream.init(buf.items);
    var packageDesc = try json.parse(PackageDescription, &stream, .{ .allocator = allocator, .ignore_unknown_fields = true });

    if (null == packageDesc.updated_at) {
        if (githubRepoName(packageDesc.git)) |repoName| {
            const repo = try fetchRepositoryMetadata(allocator, hc, repoName);
            packageDesc.updated_at = repo.updated_at;
            if (repo.license) |license| {
                packageDesc.license = license.key;
            }
            if (repo.homepage) |homepage| {
                packageDesc.homepage = homepage;
            }

            try file.seekTo(0);
            try file.setEndPos(0);
            try packageDesc.writeTo(file.writer());
        }
    }
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const hc = try http.Client.init(allocator);
    defer hc.deinit();

    const dir = try fs.cwd().openIterableDir("packages", .{});
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        const file = try entry.dir.openFile(entry.basename, .{ .mode = .read_write });
        defer file.close();

        try fillGitHubPackage(allocator, hc, file);
    }
}
