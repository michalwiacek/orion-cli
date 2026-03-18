const std = @import("std");

pub const Profile = struct {
    base_url: ?[]u8 = null,
    openapi_spec: ?[]u8 = null,

    pub fn deinit(self: *Profile, allocator: std.mem.Allocator) void {
        if (self.base_url) |v| allocator.free(v);
        if (self.openapi_spec) |v| allocator.free(v);
        self.* = .{};
    }
};

pub const ProfileEntry = struct {
    name: []u8,
    profile: Profile,

    pub fn deinit(self: *ProfileEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.profile.deinit(allocator);
        self.* = undefined;
    }
};

pub const Config = struct {
    base_url: ?[]u8 = null,
    openapi_spec: ?[]u8 = null,
    current_profile: ?[]u8 = null,
    profiles: []ProfileEntry = &.{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.base_url) |v| allocator.free(v);
        if (self.openapi_spec) |v| allocator.free(v);
        if (self.current_profile) |v| allocator.free(v);
        for (self.profiles) |*entry| entry.deinit(allocator);
        allocator.free(self.profiles);
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
        if (other.current_profile) |v| {
            if (self.current_profile) |old| allocator.free(old);
            self.current_profile = try allocator.dupe(u8, v);
        }

        for (other.profiles) |entry| {
            try upsertProfileEntry(allocator, self, entry);
        }
    }

    pub fn applyCurrentProfileFallback(self: *Config, allocator: std.mem.Allocator) !void {
        const current = self.current_profile orelse return;
        const profile = findProfileByName(self.profiles, current) orelse return;

        if (self.base_url == null) {
            if (profile.profile.base_url) |v| {
                self.base_url = try allocator.dupe(u8, v);
            }
        }
        if (self.openapi_spec == null) {
            if (profile.profile.openapi_spec) |v| {
                self.openapi_spec = try allocator.dupe(u8, v);
            }
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

    try merged.applyCurrentProfileFallback(allocator);

    return .{
        .config = merged,
        .global_path = global_path,
        .project_path = project_path,
        .global_exists = global_exists,
    };
}

pub fn getGlobalConfigPath(allocator: std.mem.Allocator) ![]u8 {
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

pub fn findProjectConfigPath(allocator: std.mem.Allocator) !?[]u8 {
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

pub fn loadConfigFile(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidConfig,
    };

    var cfg: Config = .{};
    errdefer cfg.deinit(allocator);

    if (root.get("base_url")) |v| {
        if (asString(v)) |s| cfg.base_url = try allocator.dupe(u8, s);
    }
    if (root.get("openapi_spec")) |v| {
        if (asString(v)) |s| cfg.openapi_spec = try allocator.dupe(u8, s);
    }
    if (root.get("current_profile")) |v| {
        if (asString(v)) |s| cfg.current_profile = try allocator.dupe(u8, s);
    }

    if (root.get("profiles")) |profiles_val| {
        const profiles_obj = asObject(profiles_val) orelse null;
        if (profiles_obj) |po| {
            var list: std.ArrayList(ProfileEntry) = .{};
            defer list.deinit(allocator);

            var it = po.iterator();
            while (it.next()) |entry| {
                const name = entry.key_ptr.*;
                const p_obj = asObject(entry.value_ptr.*) orelse continue;
                var profile: Profile = .{};
                if (p_obj.get("base_url")) |v| {
                    if (asString(v)) |s| profile.base_url = try allocator.dupe(u8, s);
                }
                if (p_obj.get("openapi_spec")) |v| {
                    if (asString(v)) |s| profile.openapi_spec = try allocator.dupe(u8, s);
                }
                try list.append(allocator, .{
                    .name = try allocator.dupe(u8, name),
                    .profile = profile,
                });
            }

            cfg.profiles = try list.toOwnedSlice(allocator);
        }
    }

    return cfg;
}

pub fn saveConfigFile(allocator: std.mem.Allocator, path: []const u8, cfg: Config) !void {
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try ensureDirPathAbsolute(allocator, dir_path);

    var profiles_json: std.ArrayList(u8) = .{};
    defer profiles_json.deinit(allocator);
    try profiles_json.appendSlice(allocator, "{");
    for (cfg.profiles, 0..) |entry, idx| {
        if (idx != 0) try profiles_json.appendSlice(allocator, ",");
        try profiles_json.appendSlice(allocator, "\"");
        try appendJsonEscaped(allocator, &profiles_json, entry.name);
        try profiles_json.appendSlice(allocator, "\":{");

        var first_field = true;
        if (entry.profile.base_url) |v| {
            try profiles_json.appendSlice(allocator, "\"base_url\":\"");
            try appendJsonEscaped(allocator, &profiles_json, v);
            try profiles_json.appendSlice(allocator, "\"");
            first_field = false;
        }
        if (entry.profile.openapi_spec) |v| {
            if (!first_field) try profiles_json.appendSlice(allocator, ",");
            try profiles_json.appendSlice(allocator, "\"openapi_spec\":\"");
            try appendJsonEscaped(allocator, &profiles_json, v);
            try profiles_json.appendSlice(allocator, "\"");
        }
        try profiles_json.appendSlice(allocator, "}");
    }
    try profiles_json.appendSlice(allocator, "}");

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\n");

    var wrote = false;
    if (cfg.base_url) |v| {
        try out.appendSlice(allocator, "  \"base_url\": \"");
        try appendJsonEscaped(allocator, &out, v);
        try out.appendSlice(allocator, "\"");
        wrote = true;
    }
    if (cfg.openapi_spec) |v| {
        if (wrote) try out.appendSlice(allocator, ",\n");
        try out.appendSlice(allocator, "  \"openapi_spec\": \"");
        try appendJsonEscaped(allocator, &out, v);
        try out.appendSlice(allocator, "\"");
        wrote = true;
    }
    if (cfg.current_profile) |v| {
        if (wrote) try out.appendSlice(allocator, ",\n");
        try out.appendSlice(allocator, "  \"current_profile\": \"");
        try appendJsonEscaped(allocator, &out, v);
        try out.appendSlice(allocator, "\"");
        wrote = true;
    }
    if (cfg.profiles.len > 0) {
        if (wrote) try out.appendSlice(allocator, ",\n");
        try out.appendSlice(allocator, "  \"profiles\": ");
        try out.appendSlice(allocator, profiles_json.items);
        wrote = true;
    }
    if (wrote) try out.appendSlice(allocator, "\n");
    try out.appendSlice(allocator, "}\n");

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(out.items);
}

fn upsertProfileEntry(allocator: std.mem.Allocator, cfg: *Config, incoming: ProfileEntry) !void {
    for (cfg.profiles) |*existing| {
        if (std.mem.eql(u8, existing.name, incoming.name)) {
            if (incoming.profile.base_url) |v| {
                if (existing.profile.base_url) |old| allocator.free(old);
                existing.profile.base_url = try allocator.dupe(u8, v);
            }
            if (incoming.profile.openapi_spec) |v| {
                if (existing.profile.openapi_spec) |old| allocator.free(old);
                existing.profile.openapi_spec = try allocator.dupe(u8, v);
            }
            return;
        }
    }

    var list: std.ArrayList(ProfileEntry) = .{};
    defer list.deinit(allocator);
    try list.appendSlice(allocator, cfg.profiles);
    try list.append(allocator, .{
        .name = try allocator.dupe(u8, incoming.name),
        .profile = .{
            .base_url = if (incoming.profile.base_url) |v| try allocator.dupe(u8, v) else null,
            .openapi_spec = if (incoming.profile.openapi_spec) |v| try allocator.dupe(u8, v) else null,
        },
    });

    allocator.free(cfg.profiles);
    cfg.profiles = try list.toOwnedSlice(allocator);
}

pub fn findProfileByName(profiles: []ProfileEntry, name: []const u8) ?*ProfileEntry {
    for (profiles) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn asObject(v: std.json.Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn asString(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn ensureDirPathAbsolute(allocator: std.mem.Allocator, path: []const u8) !void {
    if (path.len == 0) return;
    if (path[0] != std.fs.path.sep) return error.InvalidPath;

    const cwd = std.process.getCwdAlloc(allocator) catch null;
    defer if (cwd) |c| allocator.free(c);

    if (cwd) |c| {
        if (std.mem.startsWith(u8, path, c)) {
            var rel = path[c.len..];
            if (rel.len > 0 and rel[0] == std.fs.path.sep) rel = rel[1..];
            if (rel.len == 0) return;
            try std.fs.cwd().makePath(rel);
            return;
        }
    }

    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return err;
            try ensureDirPathAbsolute(allocator, parent);
            std.fs.makeDirAbsolute(path) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
        },
        else => return err,
    };
}

fn appendJsonEscaped(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
}
