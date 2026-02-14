const std = @import("std");
const waddle = @import("waddle");
const builtin = @import("builtin");
const parse = waddle.parse;
const wat = waddle.wat;
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

    if (args.len == 1 or args.len > 4) {
        std.debug.print(
            "Usage: {s} [options] <wasm-module> [function]\n" ++
                "Options:\n" ++
                "  -p, --print-bytecode  Print bytecode instructions\n" ++
                "  If no function is provided, invokes the start function.\n",
            .{args[0]},
        );

        return;
    }

    // Parse options
    var print_bytecode = false;
    var wasm_path_idx: ?usize = null;
    var func_name: ?[]const u8 = null;

    for (args[1..], 1..) |arg, idx| {
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--print-bytecode")) {
            print_bytecode = true;
        } else if (wasm_path_idx == null) {
            wasm_path_idx = idx;
        } else {
            func_name = arg;
        }
    }

    if (wasm_path_idx == null) {
        std.debug.print("Error: missing wasm-module argument\n", .{});
        return;
    }

    const wasm_path = args[wasm_path_idx.?];
    var vm = try createVM(arena.allocator(), wasm_path);
    defer vm.deinit();

    if (print_bytecode) {
        var allocating_writer = std.Io.Writer.Allocating.init(arena.allocator());
        defer allocating_writer.deinit();
        try vm.bytecode.format(&allocating_writer.writer);
        // Write accumulated buffer to stderr
        _ = try std.posix.write(std.posix.STDERR_FILENO, allocating_writer.writer.buffer);
    }

    if (func_name) |fname| {
        const results = try vm.invokeExportedFunc(fname);

        for (results, 0..) |res, i| {
            std.debug.print("{f}", .{res});

            if (i != results.len - 1) {
                std.debug.print(", ", .{});
            }
        }

        std.debug.print("\n", .{});
    } else {
        try vm.invokeStartFunc();
    }
}

const host_env = struct {
    fn printString(args: []types.Value, module: *runtime.ModuleInstance, store: *runtime.Store) ![]types.Value {
        const mem_addr = module.exports_by_name.get("memory") orelse return error.MissingMemoryExport;
        const mem = &store.mems.items[mem_addr.mem];
        const offset: usize = @intCast(args[0].i32);
        const length: usize = @intCast(args[1].i32);
        const bytes = mem.data[offset .. offset + length];
        std.debug.print("{s}", .{bytes});
        return &.{};
    }
};

fn createVM(allocator: std.mem.Allocator, module_path: []const u8) !runtime.Runtime {
    var store = runtime.Store.init(allocator);

    const file = try std.fs.cwd().openFile(module_path, .{});
    defer file.close();
    var file_read_buffer: [4096]u8 = undefined;
    var reader = file.reader(&file_read_buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .unlimited);
    var module: types.Module = undefined;

    if (std.ascii.endsWithIgnoreCase(module_path, ".wasm")) {
        var parser = parse.Parser.init(allocator, bytes);
        module = try parser.readModule();
    } else if (std.ascii.endsWithIgnoreCase(module_path, ".wat")) {
        var parser = try wat.Parser.init(bytes, allocator);
        const wat_module = try parser.parseModule();
        module = types.Module{
            .custom = &.{},
            .types = wat_module.types,
            .imports = wat_module.imports,
            .functions = wat_module.functions,
            .tables = wat_module.tables,
            .memories = wat_module.memories,
            .globals = wat_module.globals,
            .exports = wat_module.exports,
            .start = wat_module.start,
            .elements = wat_module.elements,
            .codes = wat_module.codes,
            .data = wat_module.data,
        };
    } else {
        return error.UnsupportedModuleFormat;
    }

    const module_inst = try store.instantiate(module, &.{
        .{
            .module = "index",
            .name = "printString",
            .value = .{ .func = host_env.printString },
        },
    });

    var start_func_addr: ?runtime.FuncAddr = null;
    if (module.start) |start_func_idx| {
        const start_func_idx_usize = @as(usize, start_func_idx);

        if (start_func_idx_usize >= module_inst.func_addrs.len) {
            return error.InvalidStartFuncIndex;
        }

        start_func_addr = module_inst.func_addrs[start_func_idx_usize];
    }

    return try runtime.Runtime.init(allocator, store, module_inst, start_func_addr);
}
