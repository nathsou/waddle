const std = @import("std");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const Value = union(enum) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
};

pub const Result = Value;

pub const Store = struct {
    allocator: Allocator,
    funcs: ArrayList(FuncInstance),
    tables: ArrayList(TableInstance),
    mems: ArrayList(MemoryInstance),
    globals: ArrayList(GlobalInstance),

    pub fn init(allocator: Allocator) Store {
        return Store{
            .allocator = allocator,
            .funcs = .empty,
            .tables = .empty,
            .mems = .empty,
            .globals = .empty,
        };
    }

    pub fn deinit(self: *Store) void {
        for (self.tables.items) |table| {
            self.allocator.free(table.elem);
        }

        for (self.mems.items) |mem| {
            self.allocator.free(mem.data);
        }

        self.funcs.deinit(self.allocator);
        self.tables.deinit(self.allocator);
        self.mems.deinit(self.allocator);
        self.globals.deinit(self.allocator);
    }

    fn allocModule(
        self: *Store,
        allocator: Allocator,
        module: types.Module,
        extern_val_imports: []const ExternVal,
        global_init_vals: []const Value,
    ) !ModuleInstance {
        var num_func_extern_vals: usize = 0;
        var num_table_extern_vals: usize = 0;
        var num_mem_extern_vals: usize = 0;
        var num_global_extern_vals: usize = 0;

        for (module.imports) |extern_val| {
            switch (extern_val.desc) {
                .func => num_func_extern_vals += 1,
                .table => num_table_extern_vals += 1,
                .mem => num_mem_extern_vals += 1,
                .global => num_global_extern_vals += 1,
            }
        }

        const func_addrs = try allocator.alloc(FuncAddr, num_func_extern_vals + module.functions.len);
        errdefer allocator.free(func_addrs);
        const table_addrs = try allocator.alloc(TableAddr, num_table_extern_vals + module.tables.len);
        errdefer allocator.free(table_addrs);
        const mem_addrs = try allocator.alloc(MemAddr, num_mem_extern_vals + module.memories.len);
        errdefer allocator.free(mem_addrs);
        const global_addrs = try allocator.alloc(GlobalAddr, num_global_extern_vals + module.globals.len);
        errdefer allocator.free(global_addrs);
        const exports = try allocator.alloc(ExportInstance, module.exports.len);
        errdefer allocator.free(exports);

        var module_inst = ModuleInstance{
            .types = module.types,
            .func_addrs = func_addrs,
            .table_addrs = table_addrs,
            .mem_addrs = mem_addrs,
            .global_addrs = global_addrs,
            .exports = exports,
        };

        const func_base = self.funcs.items.len;
        const table_base = self.tables.items.len;
        const mem_base = self.mems.items.len;
        const global_base = self.globals.items.len;

        var next_func_idx: usize = 0;
        var next_table_idx: usize = 0;
        var next_mem_idx: usize = 0;
        var next_global_idx: usize = 0;

        // Handle imports
        for (module.imports, 0..) |import, i| {
            switch (import.desc) {
                .func => {
                    const addr = switch (extern_val_imports[i]) {
                        .func => |imported_addr| imported_addr,
                        else => return error.InvalidFuncImport,
                    };
                    module_inst.func_addrs[next_func_idx] = addr;
                    next_func_idx += 1;
                },
                .table => {
                    const addr = switch (extern_val_imports[i]) {
                        .table => |imported_addr| imported_addr,
                        else => return error.InvalidTableImport,
                    };
                    module_inst.table_addrs[next_table_idx] = addr;
                    next_table_idx += 1;
                },
                .mem => {
                    const addr = switch (extern_val_imports[i]) {
                        .mem => |imported_addr| imported_addr,
                        else => return error.InvalidMemImport,
                    };
                    module_inst.mem_addrs[next_mem_idx] = addr;
                    next_mem_idx += 1;
                },
                .global => {
                    const addr = switch (extern_val_imports[i]) {
                        .global => |imported_addr| imported_addr,
                        else => return error.InvalidGlobalImport,
                    };
                    module_inst.global_addrs[next_global_idx] = addr;
                    next_global_idx += 1;
                },
            }
        }

        // Allocate functions
        if (module.codes.len != module.functions.len) {
            return error.FunctionCodeCountMismatch;
        }

        var local_func_idx: usize = 0;
        for (module.functions, 0..) |type_idx, i| {
            const type_idx_usize = @as(usize, type_idx);
            if (type_idx_usize >= module.types.len) {
                return error.InvalidTypeIndex;
            }

            const func_inst = FuncInstance{
                .wasm = .{
                    .type = module.types[type_idx_usize],
                    .module = module_inst,
                    .code = module.codes[i],
                },
            };

            const func_addr = func_base + local_func_idx;
            module_inst.func_addrs[next_func_idx] = func_addr;
            next_func_idx += 1;
            local_func_idx += 1;
            try self.funcs.append(self.allocator, func_inst);
        }

        // Allocate tables
        var local_table_idx: usize = 0;
        for (module.tables) |table_type| {
            const elem = try self.allocator.alloc(?FuncAddr, table_type.limits.min);
            @memset(elem, null);
            const table_inst = TableInstance{
                .elem = elem,
                .max = table_type.limits.max,
            };

            const table_addr = table_base + local_table_idx;
            module_inst.table_addrs[next_table_idx] = table_addr;
            next_table_idx += 1;
            local_table_idx += 1;
            try self.tables.append(self.allocator, table_inst);
        }

        // Allocate memories
        var local_mem_idx: usize = 0;
        for (module.memories) |mem_type| {
            const mem_inst = MemoryInstance{
                .data = try self.allocator.alloc(types.Byte, mem_type.limits.min * page_size),
                .max = mem_type.limits.max,
            };

            @memset(mem_inst.data, 0);

            const mem_addr = mem_base + local_mem_idx;
            module_inst.mem_addrs[next_mem_idx] = mem_addr;
            next_mem_idx += 1;
            local_mem_idx += 1;
            try self.mems.append(self.allocator, mem_inst);
        }

        // Allocate globals
        var local_global_idx: usize = 0;
        for (module.globals, 0..) |global, i| {
            const global_inst = GlobalInstance{
                .value = global_init_vals[i],
                .mutable = global.type.mutable,
            };

            const global_addr = global_base + local_global_idx;
            module_inst.global_addrs[next_global_idx] = global_addr;
            next_global_idx += 1;
            local_global_idx += 1;
            try self.globals.append(self.allocator, global_inst);
        }

        // Build exports
        for (module.exports, 0..) |exp, i| {
            switch (exp.desc) {
                .func => |func_idx| {
                    const func_idx_usize = @as(usize, func_idx);
                    if (func_idx_usize >= module_inst.func_addrs.len) {
                        return error.InvalidFuncIndex;
                    }
                    const func_addr = module_inst.func_addrs[func_idx_usize];
                    module_inst.exports[i] = ExportInstance{
                        .name = exp.name,
                        .value = .{ .func = func_addr },
                    };
                },
                .table => |table_idx| {
                    const table_idx_usize = @as(usize, table_idx);
                    if (table_idx_usize >= module_inst.table_addrs.len) {
                        return error.InvalidTableIndex;
                    }
                    const table_addr = module_inst.table_addrs[table_idx_usize];
                    module_inst.exports[i] = ExportInstance{
                        .name = exp.name,
                        .value = .{ .table = table_addr },
                    };
                },
                .mem => |mem_idx| {
                    const mem_idx_usize = @as(usize, mem_idx);
                    if (mem_idx_usize >= module_inst.mem_addrs.len) {
                        return error.InvalidMemIndex;
                    }
                    const mem_addr = module_inst.mem_addrs[mem_idx_usize];
                    module_inst.exports[i] = ExportInstance{
                        .name = exp.name,
                        .value = .{ .mem = mem_addr },
                    };
                },
                .global => |global_idx| {
                    const global_idx_usize = @as(usize, global_idx);
                    if (global_idx_usize >= module_inst.global_addrs.len) {
                        return error.InvalidGlobalIndex;
                    }
                    const global_addr = module_inst.global_addrs[global_idx_usize];
                    module_inst.exports[i] = ExportInstance{
                        .name = exp.name,
                        .value = .{ .global = global_addr },
                    };
                },
            }
        }

        return module_inst;
    }

    fn evalConstExpr(self: *Store, frame: *ActivationFrame, expr: types.Expr) !Value {
        if (expr.len != 1) {
            return error.InvalidConstExpr;
        }

        switch (expr[0]) {
            .i32_const => |val| return .{ .i32 = val },
            .i64_const => |val| return .{ .i64 = val },
            .f32_const => |val| return .{ .f32 = val },
            .f64_const => |val| return .{ .f64 = val },
            .global_get => |global_idx| {
                const global_idx_usize = @as(usize, global_idx);
                if (global_idx_usize >= frame.module.global_addrs.len) {
                    return error.InvalidGlobalIndex;
                }
                const global_addr = frame.module.global_addrs[global_idx_usize];
                const global_inst = self.globals.items[global_addr];
                return global_inst.value;
            },
            else => return error.InvalidConstExpr,
        }
    }

    pub fn instantiate(self: *Store, allocator: Allocator, module: types.Module, extern_vals: []const ExternVal) !ModuleInstance {
        // TODO: Validate the module

        if (extern_vals.len != module.imports.len) {
            return error.ImportCountMismatch;
        }

        // TODO: Validate extern vals against import details (limits, signatures).

        const num_global_imports = blk: {
            var count: usize = 0;
            for (module.imports) |import| {
                if (import.desc == .global) {
                    count += 1;
                }
            }
            break :blk count;
        };

        const global_extern_vals = try allocator.alloc(GlobalAddr, num_global_imports);
        defer allocator.free(global_extern_vals);
        var global_import_idx: usize = 0;

        for (module.imports, 0..) |import, i| {
            const extern_val = extern_vals[i];
            switch (import.desc) {
                .func => {
                    switch (extern_val) {
                        .func => {},
                        else => return error.InvalidFuncImport,
                    }
                },
                .table => {
                    switch (extern_val) {
                        .table => {},
                        else => return error.InvalidTableImport,
                    }
                },
                .mem => {
                    switch (extern_val) {
                        .mem => {},
                        else => return error.InvalidMemImport,
                    }
                },
                .global => {
                    global_extern_vals[global_import_idx] = switch (extern_val) {
                        .global => |addr| addr,
                        else => return error.InvalidGlobalImport,
                    };
                    global_import_idx += 1;
                },
            }
        }

        var aux_module_inst = ModuleInstance{
            .types = &.{},
            .func_addrs = &.{},
            .table_addrs = &.{},
            .mem_addrs = &.{},
            .global_addrs = global_extern_vals,
            .exports = &.{},
        };

        var aux_frame = ActivationFrame{
            .arity = 1,
            .locals = &.{},
            .module = &aux_module_inst,
        };

        const global_init_vals = try allocator.alloc(Value, module.globals.len);
        defer allocator.free(global_init_vals);

        for (module.globals, 0..) |global, i| {
            const val = try self.evalConstExpr(&aux_frame, global.init);
            global_init_vals[i] = val;
        }

        return self.allocModule(allocator, module, extern_vals, global_init_vals);
    }
};

const Addr = usize;
const FuncAddr = Addr;
const TableAddr = Addr;
const MemAddr = Addr;
const GlobalAddr = Addr;

pub const ModuleInstance = struct {
    types: []types.FuncType,
    func_addrs: []FuncAddr,
    table_addrs: []TableAddr,
    mem_addrs: []MemAddr,
    global_addrs: []GlobalAddr,
    exports: []ExportInstance,
};

const HostFunc = *const fn ([]Value) anyerror!Value;

const FuncInstance = union(enum) {
    wasm: struct {
        type: types.FuncType,
        module: ModuleInstance,
        code: types.Func,
    },
    host: struct {
        type: types.FuncType,
        code: HostFunc,
    },
};

const FuncElem = ?FuncAddr;

const TableInstance = struct {
    elem: []FuncElem,
    max: ?u32,
};

const page_size: usize = 65_536;

const MemoryInstance = struct {
    data: []types.Byte,
    max: ?u32,
};

const GlobalInstance = struct {
    value: Value,
    mutable: bool,
};

const ExportInstance = struct {
    name: types.Name,
    value: ExternVal,
};

pub const ExternVal = union(enum) {
    func: FuncAddr,
    table: TableAddr,
    mem: MemAddr,
    global: GlobalAddr,
};

const Label = struct {
    arity: usize,
    instr_start: usize,
};

const ActivationFrame = struct {
    arity: usize,
    locals: []Value,
    module: *ModuleInstance,
};

pub const Runtime = struct {
    allocator: Allocator,
    store: *Store,
    module: ModuleInstance,
    value_stack: ArrayList(Value),
    label_stack: ArrayList(Label),
    frame_stack: ArrayList(ActivationFrame),
};
