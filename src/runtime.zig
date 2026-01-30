const std = @import("std");
const types = @import("types.zig");

pub const Value = union(enum) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
};

pub const Result = Value;

const Store = struct {
    funcs: []FuncInstance,
    tables: []TableInstance,
    mems: []MemoryInstance,
    globals: []GlobalInstance,
};

const Addr = usize;
const FuncAddr = Addr;
const TableAddr = Addr;
const MemAddr = Addr;
const GlobalAddr = Addr;

const ModuleInstance = struct {
    types: []types.FuncType,
    func_addrs: []FuncAddr,
    table_addrs: []TableAddr,
    mem_addrs: []MemAddr,
    global_addrs: []GlobalAddr,
    exports: []ExportInstance,
};

const HostFunc = *const fn ([]Value) anyerror![]Value;

const FuncInstance = union(enum) {
    module: struct {
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

const ExternVal = union(enum) {
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
    const Self = @This();
    allocator: std.mem.Allocator,
    module: ModuleInstance,
    value_stack: std.ArrayList(Value),
    label_stack: std.ArrayList(Label),
    frame_stack: std.ArrayList(ActivationFrame),

    pub fn init(allocator: std.mem.Allocator, module: *types.Module) Self {
        return Self{
            .allocator = allocator,
            .module = module,
        };
    }
};
