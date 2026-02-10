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
    var module_inst = try store.instantiate(allocator, module, &.{});
    defer module_inst.deinit(allocator);

    var vm = try runtime.Runtime.init(allocator, &store);
    defer vm.deinit();

    const result = try vm.invokeExportedFunc(&module_inst, "main");
    if (result) |res| {
        std.debug.print("{any}\n", .{res});
    }
}
