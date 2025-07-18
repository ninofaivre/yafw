const std = @import("std");
const posix = std.posix;

pub const Event = std.os.linux.inotify_event;

fn EventHandlers(comptime Tdata: type) type {
    return []const struct {u32, (fn (i32, *Event, Tdata) anyerror!void)};
}

pub fn read(
    comptime Tdata: type,
    data: Tdata,
    inotifyFd: i32,
    buffer: []u8,
    comptime handlers: EventHandlers(Tdata),
) !void {

    const nBytes = try posix.read(inotifyFd, buffer);

    var processedBytes: usize = 0;
    while (processedBytes < nBytes): (processedBytes += @sizeOf(std.os.linux.inotify_event)) {
        const event: *std.os.linux.inotify_event = @alignCast(@ptrCast(&buffer[processedBytes]));
        processedBytes += event.len;

        inline for (handlers) |handler| {
            if (event.mask & handler[0] != 0)
                try handler[1](inotifyFd, event, data);
        }
    }
}
