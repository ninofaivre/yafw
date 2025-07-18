const std = @import("std");

pub fn doesPathExists(path: []const u8) !bool {
    std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
        std.fs.Dir.AccessError.FileNotFound => return false,
        else => return err,
    };
    return true;
}
