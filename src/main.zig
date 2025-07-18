const std = @import("std");
const posix = std.posix;
const IN = std.os.linux.IN;

const stdOutWriter = std.io.getStdOut().writer();
const PathIt = std.mem.SplitIterator(u8, .scalar);

const cli = @import("cli/root.zig");
const inotify = @import("./inotify.zig");
const utils = @import("./utils.zig");

const Wds = struct {
    const WD = std.ArrayList(PathIt);

    lists: []WD,
    freeLists: std.ArrayList(*WD),
    wds: std.AutoArrayHashMap(i32, *WD),

    pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !Wds {
        var lists = try allocator.alloc(WD, capacity);
        var freeLists = try std.ArrayList(*WD).initCapacity(allocator, capacity);
        for (0..capacity) |index| {
            lists[index] = try WD.initCapacity(allocator, capacity);
            freeLists.appendAssumeCapacity(&lists[index]);
        }

        var wds = std.AutoArrayHashMap(i32, *WD).init(allocator);
        try wds.ensureTotalCapacity(capacity);

        return Wds{
            .lists = lists,
            .freeLists = freeLists,
            .wds = wds,
        };
    }

    pub fn deinit(self: *Wds) void {
        for (self.lists) |list| { list.deinit(); }
        self.freeLists.deinit();
        self.wds.deinit();
    }

    pub fn freeWd(self: *Wds, wd: i32) !void {
        if (self.wds.fetchSwapRemove(wd)) |entry| {
            self.freeLists.appendAssumeCapacity(entry.value);
        } else {
            return error.WdNotFound;
        }
    }

    pub fn isEveryFilePathNull(self: *Wds) bool {
        for (self.wds.values()) |filePathItList| {
            for (filePathItList.items) |filePathIt| {
                var mutFilePathIt = filePathIt;
                if (mutFilePathIt.peek() != null)
                    return false;
            }
        }
        return true;
    }

    pub fn getWd(self: *Wds, wd: i32) ?*WD {
        return self.wds.get(wd);
    }

    pub fn appendToOrCreateWd(self: *Wds, wd: i32, pathIt: PathIt) !void {
        const pathItList = try self.wds.getOrPut(wd);
        if (pathItList.found_existing == false) {
            if (self.freeLists.pop()) |newWd| {
                pathItList.value_ptr.* = newWd;
            } else {
                return error.NoWdLeft;
            }
        }
        pathItList.value_ptr.*.appendAssumeCapacity(pathIt);
    }
};

fn getHighestExistingDirIt(filePathIt: PathIt) !PathIt {
    var it = filePathIt;
    _ = it.peek();
    while (it.peek() != null): (_ = it.next()) {
        if (it.peek().?.len == 0) continue ;
        if (try utils.doesPathExists(it.buffer[0..it.index.? + it.peek().?.len]) == false) break ;
    }
    return it;
}

fn updateWatch(
    wds: *Wds,
    filePathIt: PathIt,
    inotifyFd: i32,
    mode: cli.Mode,
) anyerror!void {
    var currPathIt = filePathIt;
    if (currPathIt.peek() == null and mode == .each)
        try stdOutWriter.print("{s}\n", .{currPathIt.buffer});
    const wd = if (currPathIt.peek() == null)
        posix.inotify_add_watch(
            inotifyFd, currPathIt.buffer,
            IN.DELETE_SELF
        )
    else
         posix.inotify_add_watch(
            inotifyFd, currPathIt.buffer[0..currPathIt.index.?],
            IN.CREATE | IN.MOVED_TO | IN.DELETE_SELF
        )
    ;

    if (wd) |safeWd| {
        if (currPathIt.peek() != null and
            try utils.doesPathExists(currPathIt.buffer[0..currPathIt.index.? + currPathIt.peek().?.len])
        ) {
            posix.inotify_rm_watch(inotifyFd, safeWd);
            _ = currPathIt.next();
            currPathIt = try getHighestExistingDirIt(currPathIt);
            return updateWatch(wds, currPathIt, inotifyFd, mode);
        }
        try wds.appendToOrCreateWd(safeWd, currPathIt);
    } else |err| switch (err) {
        posix.INotifyAddWatchError.FileNotFound =>
            return initWatch(wds, currPathIt, inotifyFd, mode),
        else => return err,
    }
}

fn isEventNextPathPart(pathIt: PathIt, eventName: []const u8) bool {
    var mutPathIt = pathIt;
    if (mutPathIt.peek()) |nextPathPart| {
        return std.mem.eql(u8, nextPathPart, eventName);
    }
    return false;
}

fn initWatch(
    wds: *Wds,
    filePathIt: PathIt,
    inotifyFd: i32,
    mode: cli.Mode,
) anyerror!void {
    var highestIt = filePathIt;
    highestIt.reset();
    highestIt = try getHighestExistingDirIt(highestIt);
    return updateWatch(wds, highestIt, inotifyFd, mode);
}


const HandlerData = struct {
    wds: *Wds,
    mode: cli.Mode,
};

fn deleteHandler(
    inotifyFd: i32,
    event: *inotify.Event,
    data: HandlerData
) !void {
    var filePathItList = if (data.wds.getWd(event.wd)) |wd| wd else return;

    var index = filePathItList.items.len;
    try data.wds.freeWd(event.wd);
    while (index != 0) {
        index -= 1;
        const pathIt = filePathItList.swapRemove(index);
        try initWatch(data.wds, pathIt, inotifyFd, data.mode);
    }
}

fn createHandler(
    inotifyFd: i32,
    event: *inotify.Event,
    data: HandlerData
) !void {
    var filePathItList = if (data.wds.getWd(event.wd)) |wd| wd else return;
    const eventName = event.getName().?;

    var needToRmWatch = true;
    for (filePathItList.items) |pathIt| {
        if (!isEventNextPathPart(pathIt, eventName)) {
            needToRmWatch = false;
            break ;
        }
    }
    if (needToRmWatch) {
        posix.inotify_rm_watch(inotifyFd, event.wd);
        try data.wds.freeWd(event.wd);
    }

    var index = filePathItList.items.len;
    var checkExists = true;
    while (index != 0) {
        index -= 1;
        var pathIt = filePathItList.items[index];
        if (!isEventNextPathPart(pathIt, eventName)) {
            if (pathIt.peek() != null)
                checkExists = false;
            continue ;
        }
        _ = filePathItList.swapRemove(index);
        _ = pathIt.next();
        try updateWatch(data.wds, pathIt, inotifyFd, data.mode);
    }
    if (checkExists and data.mode == .all and data.wds.isEveryFilePathNull())
        try stdOutWriter.print("\n", .{});
}

fn watch(wds: *Wds, inotifyFd: i32, mode: cli.Mode) !void {
    var buffer: [4096]u8 = undefined;

    const handlerData = HandlerData{
        .wds = wds,
        .mode = mode,
    };
    while (true) {
        try inotify.read(
            HandlerData, handlerData,
            inotifyFd, buffer[0..], &.{
                .{ IN.DELETE_SELF, deleteHandler },
                .{ IN.CREATE, createHandler },
                .{ IN.MOVED_TO, createHandler },
            }
        );
    }
}

pub fn main() !u8 {
    // use std.heap.c_allocator to see memory usage in valgrind
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root = try cli.build(allocator);
    defer root.deinit();

    var data: cli.Data = .{
        .filePaths = &[_][]const u8{},
        .mode = .each,
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

    var wds = try Wds.initCapacity(allocator, data.filePaths.len);
    defer wds.deinit();

    for (data.filePaths) |filePath| {
        const filePathIt = std.mem.splitScalar(u8, filePath, '/');
        try initWatch(&wds, filePathIt, inotifyFd, data.mode);
    }

    try watch(&wds, inotifyFd, data.mode);
    return 0;
}
