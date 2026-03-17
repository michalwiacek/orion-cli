const std = @import("std");

pub const Config = struct {
    base_url: ?[]u8 = null,
    openapi_spec: ?[]u8 = null,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.base_url) |v| allocator.free(v);
        if (self.openapi_spec) |v| allocator.free(v);
        self.* = .{};
    }

    pub fn mergeFrom(self: *Config, allocator: std.mem.Allocator, other: Config) !void {
        if (other.base_url) |v| {
            if (self.base_url) |old| allocator.free(old);
            self.base_url = try allocator.dupe(u8, v);
        }
        if (other.openapi_spec) |v| {
            if (self.openapi_spec) |old| allocator.free(old);
            self.openapi_spec = try allocator.dupe(u8, v);
        }
    }
};

pub const LoadedConfig = struct {
    config: Config,
    global_path: []u8,
    project_path: ?[]u8,
    global_exists: bool,

    pub fn deinit(self: *LoadedConfig, allocator: std.mem.Allocator) void {
        self.config.deinit(allocator);
        allocator.free(self.global_path);
        if (self.project_path) |p| allocator.free(p);
        self.* = undefined;
    }
};

const RawConfig = struct {
    base_url: ?[]const u8 = null,
    openapi_spec: ?[]const u8 = null,
};

pub fn loadMerged(allocator: std.mem.Allocator) !LoadedConfig {
    var merged: Config = .{};

    const global_path = try getGlobalConfigPath(allocator);
    const project_path = try findProjectConfigPath(allocator);

    var global_exists = false;
    if (fileExists(global_path)) {
        global_exists = true;
        var parsed_global = try loadConfigFile(allocator, global_path);
        defer parsed_global.deinit(allocator);
        try merged.mergeFrom(allocator, parsed_global);
    }

    if (project_path) |p| {
        var parsed_project = try loadConfigFile(allocator, p);
        defer parsed_project.deinit(allocator);
        try merged.mergeFrom(allocator, parsed_project);
    }

    return .{
        .config = merged,
        .global_path = global_path,
        .project_path = project_path,
        .global_exists = global_exists,
    };
}

fn loadConfigFile(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(RawConfig, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var cfg: Config = .{};
    errdefer cfg.deinit(allocator);

    if (parsed.value.base_url) |v| {
        cfg.base_url = try allocator.dupe(u8, v);
    }
    if (parsed.value.openapi_spec) |v| {
        cfg.openapi_spec = try allocator.dupe(u8, v);
    }

    return cfg;
}

fn getGlobalConfigPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        return std.fs.path.join(allocator, &.{ xdg, "orion", "config.json" });
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    return std.fs.path.join(allocator, &.{ home, ".config", "orion", "config.json" });
}

fn findProjectConfigPath(allocator: std.mem.Allocator) !?[]u8 {
    var cwd = try std.process.getCwdAlloc(allocator);
    errdefer allocator.free(cwd);

    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ cwd, ".orion", "config.json" });
        if (fileExists(candidate)) {
            allocator.free(cwd);
            return candidate;
        }
        allocator.free(candidate);

        const parent = std.fs.path.dirname(cwd) orelse break;
        if (std.mem.eql(u8, parent, cwd)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(cwd);
        cwd = next;
    }

    allocator.free(cwd);
    return null;
}

fn fileExists(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}
