const std = @import("std");
const waddle = @import("waddle");
const builtin = @import("builtin");
const runtime = waddle.runtime;
const types = waddle.types;

pub fn main() !void {
    if (builtin.mode == .Debug) {
        var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
        defer _ = debug_alloc.deinit();
        try run(debug_alloc.allocator());
    } else {
        var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
        defer _ = gpa.deinit();
        try run(gpa.allocator());
    }
}

fn run(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const args = try std.process.argsAlloc(arena.allocator());

    if (args.len == 1 or args.len > 3) {
        std.debug.print(
            "Usage: {s} <wasm-module> [function]\n" ++
                "  If no function is provided, invokes the start function.\n",
            .{args[0]},
        );

        return;
    }

    const wasm_path = args[1];
    var vm = try runtime.Runtime.from(arena.allocator(), wasm_path);
    defer vm.deinit();

    if (args.len == 2) {
        try vm.invokeStartFunc();
    } else {
        const results = try vm.invokeExportedFunc(args[2]);

        for (results, 0..) |res, i| {
            std.debug.print("{f}", .{res});

            if (i != results.len - 1) {
                std.debug.print(", ", .{});
            }
        }

        std.debug.print("\n", .{});
    }
}
