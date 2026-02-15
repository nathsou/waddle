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

    if (args.len == 1) {
        printUsage(args[0]);
        return;
    }

    var print_bytecode = false;
    var wasm_path: ?[]const u8 = null;
    var invoke_idx: ?usize = null;

    for (args[1..], 1..) |arg, idx| {
        if (std.mem.eql(u8, arg, "--invoke")) {
            invoke_idx = idx;
            break;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--print-bytecode")) {
            print_bytecode = true;
        } else if (wasm_path == null) {
            wasm_path = arg;
        } else {
            std.debug.print(
                "Error: unexpected argument before --invoke: {s}\n",
                .{arg},
            );
            return;
        }
    }

    if (wasm_path == null) {
        std.debug.print("Error: missing <file.wasm/.wat> argument\n", .{});
        printUsage(args[0]);
        return;
    }

    var vm = try createVM(arena.allocator(), wasm_path.?);
    defer vm.deinit();

    if (print_bytecode) {
        var allocating_writer = std.Io.Writer.Allocating.init(arena.allocator());
        defer allocating_writer.deinit();
        try vm.bytecode.format(&allocating_writer.writer);
        // Write accumulated buffer to stderr
        _ = try std.posix.write(std.posix.STDERR_FILENO, allocating_writer.writer.buffer);
    }

    if (invoke_idx) |invoke_flag_idx| {
        if (invoke_flag_idx + 1 >= args.len) {
            std.debug.print("Error: missing <func_name> after --invoke\n", .{});
            printUsage(args[0]);
            return;
        }

        const func_name = args[invoke_flag_idx + 1];
        const func_arg_strings = args[invoke_flag_idx + 2 ..];

        const func_type = try vm.getExportedFuncType(func_name);
        if (func_type.params.len != func_arg_strings.len) {
            std.debug.print(
                "Error: function '{s}' expects {d} argument(s), got {d}\n",
                .{ func_name, func_type.params.len, func_arg_strings.len },
            );
            return;
        }

        const func_args = try arena.allocator().alloc(types.Value, func_type.params.len);
        for (func_type.params, 0..) |param_type, i| {
            func_args[i] = try parseValue(func_arg_strings[i], param_type);
        }

        const results = try vm.invokeExportedFunc(func_name, func_args);

        for (results, 0..) |res, i| {
            std.debug.print("{f}", .{res});

            if (i != results.len - 1) {
                std.debug.print(", ", .{});
            }
        }

        if (results.len > 0) {
            std.debug.print("\n", .{});
        }
    } else {
        try vm.invokeStartFunc();
    }
}

fn parseValue(raw: []const u8, val_type: types.ValType) !types.Value {
    return switch (val_type) {
        .i32 => .{ .i32 = try std.fmt.parseInt(i32, raw, 0) },
        .i64 => .{ .i64 = try std.fmt.parseInt(i64, raw, 0) },
        .f32 => .{ .f32 = try std.fmt.parseFloat(f32, raw) },
        .f64 => .{ .f64 = try std.fmt.parseFloat(f64, raw) },
    };
}

fn printUsage(program_name: []const u8) void {
    std.debug.print(
        "Usage: {s} [options] <file.wasm/.wat> [--invoke <func_name> [<func_args>]]\n" ++
            "Options:\n" ++
            "  -p, --print-bytecode  Print bytecode instructions\n",
        .{program_name},
    );
}

const host_env = struct {
    fn printChar(args: []const types.Value, _: *runtime.ModuleInstance, _: *runtime.Store) ![]types.Value {
        const char_code: u8 = @intCast(args[0].i32);
        std.debug.print("{c}", .{char_code});
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
            .module = "spectest",
            .name = "print_char",
            .value = .{ .func = host_env.printChar },
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
