const std = @import("std");
const posix = std.posix;
const IN = std.os.linux.IN;

const cli = @import("cli/root.zig");

fn doesPathExists(path: []const u8) !bool {
    std.debug.print("path : {s}\n", .{path});
    std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
        std.fs.Dir.AccessError.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn getHighestExistingDirIt(filePathIt: std.mem.SplitIterator(u8, .scalar)) !std.mem.SplitIterator(u8, .scalar) {
    var it = filePathIt;
    while (it.peek() != null): (_ = it.next()) {
        if (it.peek().?.len == 0) continue ;
        if (try doesPathExists(it.buffer[0..it.index.? + it.peek().?.len]) == false) break ;
    }

    if (it.peek() == null) {
        std.debug.print("full path already exists !", .{});
        return error.TODO;
    }
    return it;
}

fn initWatch(
    wds: *std.ArrayList(std.mem.SplitIterator(u8, .scalar)),
    filePathIt: std.mem.SplitIterator(u8, .scalar),
    inotifyFd: i32,
) !void {
    var highestIt = try getHighestExistingDirIt(filePathIt);
    const wd = posix.inotify_add_watch(
        inotifyFd, highestIt.buffer[0..highestIt.index.?],
        IN.CREATE | IN.MOVED_TO | IN.DELETE_SELF
    ) catch |err| switch (err) {
        posix.INotifyAddWatchError.FileNotFound =>
            return initWatch(wds, filePathIt, inotifyFd),
        else => return err
    }
    wds[wd].append(highestIt);
}

// fn watch(pathIt: std.mem.SplitIterator(u8, .scalar), inotifyFd: i32) !void {
//     var wd: i32 = 0;
//
//     var currPathIt = pathIt;
//     while (true) {
//         currPathIt = try getHighestExistingDirIt(currPathIt);
//         wd = posix.inotify_add_watch(
//             inotifyFd, currPathIt.buffer[0..currPathIt.index.?],
//             std.os.linux.IN.CREATE | std.os.linux.IN.MOVED_TO
//                 | std.os.linux.IN.DELETE_SELF
//         ) catch |err| switch (err) {
//             posix.INotifyAddWatchError.FileNotFound => continue,
//             else => return err
//         };
//         break ;
//     }
//
//     var buffer: [4096]u8 = undefined;
//     while (true) {
//         const nBytes = try posix.read(inotifyFd, &buffer);
//
//         var processedBytes: usize = 0;
//         while (processedBytes < nBytes): (processedBytes += @sizeOf(std.os.linux.inotify_event)) {
//             const event: *std.os.linux.inotify_event = @alignCast(@ptrCast(&buffer[processedBytes]));
//             processedBytes += event.len;
//
//             if (event.mask & std.os.linux.IN.DELETE_SELF != 0) {
//                 return watch(pathIt, inotifyFd);
//             }
//             if (event.mask & std.os.linux.IN.CREATE != 0 and
//                 std.mem.eql(u8, event.getName().?, currPathIt.peek().?)
//             ) {
//                 _ = currPathIt.next();
//                 if (currPathIt.peek() == null) {
//                     std.debug.print("path found !\n", .{});
//                     if (posix.inotify_add_watch(
//                         inotifyFd, currPathIt.buffer,
//                         std.os.linux.IN.DELETE_SELF
//                     )) |newWd| {
//                         posix.inotify_rm_watch(inotifyFd, wd);
//                         wd = newWd;
//                     } else |err| switch (err) {
//                         posix.INotifyAddWatchError.FileNotFound => {},
//                         else => return err,
//                     }
//                 } else {
//                     if (posix.inotify_add_watch(
//                         inotifyFd, currPathIt.buffer[0..currPathIt.index.?],
//                         std.os.linux.IN.CREATE | std.os.linux.IN.MOVED_TO
//                             | std.os.linux.IN.DELETE_SELF
//                     )) |newWd| {
//                         posix.inotify_rm_watch(inotifyFd, wd);
//                         wd = newWd;
//                     } else |err| switch (err) {
//                         posix.INotifyAddWatchError.FileNotFound => {},
//                         else => return err,
//                     }
//                 }
//             }
//         }
//     }
// }

pub fn main() !u8 {
    // use std.heap.c_allocator to see memory usage in valgrind
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root = try cli.build(allocator);
    defer root.deinit();

    var data: cli.Data = .{
        .filePaths = &[_][]const u8{},
    };
    root.execute(.{
        .data = &data,
    }) catch |err| switch (err) {
        error.InvalidCommand => return 1,
        else => return err,
    };
    if (data.filePaths.len == 0)
        return 0;

    const inotifyFd = try posix.inotify_init1(0);
    defer posix.close(inotifyFd);

    var wds = try allocator.alloc(std.ArrayList(std.mem.SplitIterator(u8, .scalar)), data.filePaths.len + 1);
    for (0..data.filePaths.len) |wd| {
        wds[wd] = try std.ArrayList(std.mem.SplitIterator(u8, .scalar)).initCapacity(allocator, data.filePaths.len);
        defer wds[wd].deinit();
    }
    defer allocator.free(wds);

    for (data.filePaths) |filePath| {
        const filePathIt = std.mem.splitScalar(u8, filePath, '/');
        try initWatch(wds, filePathIt, inotifyFd);
    }

    try watch(inotifyFd, wds);
    return 0;
}
