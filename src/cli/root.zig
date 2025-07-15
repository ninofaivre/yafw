const std = @import("std");
const zli = @import("zli");

const buildOptions = @import("buildOptions");

pub const Data = struct {
    filePaths: [][]const u8,
};

// TODO zli PR to add getVariadicArgs
var nCmdPosArgs: usize = undefined;

pub fn build(allocator: std.mem.Allocator) !*zli.Command {
    const root = try zli.Command.init(allocator, .{
        .name = buildOptions.name,
        .description = "Yet Another File Watcher",
        .version = buildOptions.version,
    }, base);

    try root.addFlags(&[_]zli.Flag{
        zli.Flag{
            .name = "version",
            .shortcut = "v",
            .description = "show version",
            .type = .Bool,
            .default_value = .{ .Bool = false },
        },
    });
    try root.addPositionalArg(.{
        .name = "filePaths",
        .description = "filePaths to watch, only absolute paths accepted",
        .required = false,
        .variadic = true,
    });

    nCmdPosArgs = root.positional_args.items.len;
    return root;
}

fn base(ctx: zli.CommandContext) !void {
    const fVersion = ctx.flag("version", bool);
    const nFlags: u2 = @as(u2, @as(u2, @intFromBool(fVersion)));

    const aFilePaths = ctx.positional_args[nCmdPosArgs - 1 ..];
    const nArgs: u2 = @as(u2, @intFromBool(aFilePaths.len != 0));

    const allocator = ctx.allocator;
    const data = ctx.getContextData(Data);

    if (fVersion and (nFlags > 1 or nArgs != 0)) {
        try ctx.command.stderr.print("Flag 'version' cannot be combined with others flags or arguments.\n", .{});
        return error.InvalidCommand;
    }
    if (aFilePaths.len != 0) {
        data.*.filePaths = try allocator.alloc([]const u8, aFilePaths.len);
    }
    for (aFilePaths, 0..) |filePath, index| {
        if (filePath.len == 0) {
            try ctx.command.stderr.print("File path can't be empty.\n", .{});
            return error.InvalidCommand;
        } else if (filePath[0] != '/') {
            try ctx.command.stderr.print("Only absolute file paths are accepted.\nThe following file path does not start by '/' : \"{s}\"\n", .{
                filePath
            });
            return error.InvalidCommand;
        } else if (filePath.len == 1) {
            try ctx.command.stderr.print("watching / does not make any sense", .{});
            return error.InvalidCommand;
        }
        data.*.filePaths[index] = filePath;
    }
    if (fVersion)
        try ctx.command.stdout.print("{?}\n", .{ctx.root.options.version});
    if (nFlags == 0 and nArgs == 0)
        try ctx.command.printHelp();
}
