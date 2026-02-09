const std = @import("std");
const waddle = @import("waddle");
const runtime = waddle.runtime;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const file = try std.fs.cwd().openFile("res/fact.wasm", .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(arena.allocator(), 1024 * 1024);
    var parser = waddle.parse.Parser.init(arena.allocator(), bytes);
    var store = runtime.Store.init(allocator);
    defer store.deinit();
    const module = try parser.readModule();
    _ = try store.instantiate(arena.allocator(), module, &.{});
    std.debug.print("{any}\n", .{store.funcs.items[0].wasm.code.body});

    var lowering = try runtime.BytecodeLowering.init(allocator, store.funcs.items.len);
    defer lowering.deinit();
    try lowering.lowerStore(&store);

    std.debug.print("Lowered bytecode:\n", .{});
    for (lowering.flat.items) |instr| {
        std.debug.print("{any}\n", .{instr});
    }
}
