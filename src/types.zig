// WASM Core 1.0 types

const std = @import("std");

pub const Byte = u8;

// Indices
pub const TypeIndex = u32;
pub const FuncIndex = u32;
pub const TableIndex = u32;
pub const MemIndex = u32;
pub const GlobalIndex = u32;
pub const LocalIndex = u32;
pub const LabelIndex = u32;
pub const DataIndex = u32;
pub const ElemIndex = u32;

pub const Name = []const u8;

pub const NumType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,
};

pub const RefType = enum(u8) {
    funcref = 0x70,
    externref = 0x6F,

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return switch (self) {
            .funcref => try writer.writeAll("funcref"),
            .externref => try writer.writeAll("externref"),
        };
    }
};

pub const ValType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,
    funcref = 0x70,
    externref = 0x6F,

    pub fn isNumType(self: ValType) bool {
        return switch (self) {
            .i32, .i64, .f32, .f64 => true,
            .funcref, .externref => false,
        };
    }

    pub fn isRefType(self: ValType) bool {
        return switch (self) {
            .i32, .i64, .f32, .f64 => false,
            .funcref, .externref => true,
        };
    }
};

pub const ResultType = []const ValType;

pub const BlockType = union(enum) {
    empty,
    val_type: ValType,
    type_index: TypeIndex,
};

pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,

    pub fn eql(self: FuncType, other: FuncType) bool {
        return std.mem.eql(ValType, self.params, other.params) and std.mem.eql(ValType, self.results, other.results);
    }

    pub fn deinit(self: *FuncType, allocator: std.mem.Allocator) void {
        allocator.free(self.params);
        allocator.free(self.results);
    }
};

pub const Limits = struct {
    min: u32,
    max: ?u32,
};

pub const MemType = struct {
    limits: Limits,
};

pub const TableType = struct {
    elem_type: RefType,
    limits: Limits,
};

pub const GlobalType = struct {
    val_type: ValType,
    mutable: bool,
};

pub const ImportDesc = union(enum) {
    func: FuncIndex,
    table: TableType,
    mem: MemType,
    global: GlobalType,
};

pub const MemoryInstrArg = struct { alignment: u32, offset: u32 };

pub const Block = struct {
    block_type: BlockType,
    instructions: []Instr,
};

pub const Instr = union(enum) {
    // Control instructions
    @"unreachable",
    nop,
    block: Block,
    loop: Block,
    @"if": struct {
        block_type: BlockType,
        then_instructions: []Instr,
        else_instructions: []Instr,
    },
    br: LabelIndex,
    br_if: LabelIndex,
    br_table: struct { label_indices: []LabelIndex, default_idx: LabelIndex },
    @"return",
    call: FuncIndex,
    call_indirect: struct { type_idx: TypeIndex, table_idx: TableIndex },

    // Parametric instructions
    drop,
    select,

    // Variable instructions
    local_get: LocalIndex,
    local_set: LocalIndex,
    local_tee: LocalIndex,
    global_get: GlobalIndex,
    global_set: GlobalIndex,

    // Table instructions
    table_get: TableIndex,
    table_set: TableIndex,
    table_init: struct { elem_idx: ElemIndex, table_idx: TableIndex },
    elem_drop: ElemIndex,
    table_copy: struct { dst_table_idx: TableIndex, src_table_idx: TableIndex },
    table_grow: TableIndex,
    table_size: TableIndex,
    table_fill: TableIndex,

    // Memory instructions
    i32_load: MemoryInstrArg,
    i64_load: MemoryInstrArg,
    f32_load: MemoryInstrArg,
    f64_load: MemoryInstrArg,
    i32_load8_s: MemoryInstrArg,
    i32_load8_u: MemoryInstrArg,
    i32_load16_s: MemoryInstrArg,
    i32_load16_u: MemoryInstrArg,
    i64_load8_s: MemoryInstrArg,
    i64_load8_u: MemoryInstrArg,
    i64_load16_s: MemoryInstrArg,
    i64_load16_u: MemoryInstrArg,
    i64_load32_s: MemoryInstrArg,
    i64_load32_u: MemoryInstrArg,
    i32_store: MemoryInstrArg,
    i64_store: MemoryInstrArg,
    f32_store: MemoryInstrArg,
    f64_store: MemoryInstrArg,
    i32_store8: MemoryInstrArg,
    i32_store16: MemoryInstrArg,
    i64_store8: MemoryInstrArg,
    i64_store16: MemoryInstrArg,
    i64_store32: MemoryInstrArg,
    memory_size: MemIndex,
    memory_grow: MemIndex,
    memory_init: struct { data_idx: DataIndex, mem_idx: MemIndex },
    data_drop: DataIndex,
    memory_copy: struct { dst_mem_idx: MemIndex, src_mem_idx: MemIndex },
    memory_fill: MemIndex,

    // Numeric instructions
    i32_const: i32,
    i64_const: i64,
    f32_const: f32,
    f64_const: f64,
    i32_eqz,
    i32_eq,
    i32_ne,
    i32_lt_s,
    i32_lt_u,
    i32_gt_s,
    i32_gt_u,
    i32_le_s,
    i32_le_u,
    i32_ge_s,
    i32_ge_u,
    i64_eqz,
    i64_eq,
    i64_ne,
    i64_lt_s,
    i64_lt_u,
    i64_gt_s,
    i64_gt_u,
    i64_le_s,
    i64_le_u,
    i64_ge_s,
    i64_ge_u,
    f32_eq,
    f32_ne,
    f32_lt,
    f32_gt,
    f32_le,
    f32_ge,
    f64_eq,
    f64_ne,
    f64_lt,
    f64_gt,
    f64_le,
    f64_ge,
    i32_clz,
    i32_ctz,
    i32_popcnt,
    i32_add,
    i32_sub,
    i32_mul,
    i32_div_s,
    i32_div_u,
    i32_rem_s,
    i32_rem_u,
    i32_and,
    i32_or,
    i32_xor,
    i32_shl,
    i32_shr_s,
    i32_shr_u,
    i32_rotl,
    i32_rotr,
    i64_clz,
    i64_ctz,
    i64_popcnt,
    i64_add,
    i64_sub,
    i64_mul,
    i64_div_s,
    i64_div_u,
    i64_rem_s,
    i64_rem_u,
    i64_and,
    i64_or,
    i64_xor,
    i64_shl,
    i64_shr_s,
    i64_shr_u,
    i64_rotl,
    i64_rotr,
    f32_abs,
    f32_neg,
    f32_ceil,
    f32_floor,
    f32_trunc,
    f32_nearest,
    f32_sqrt,
    f32_add,
    f32_sub,
    f32_mul,
    f32_div,
    f32_min,
    f32_max,
    f32_copysign,
    f64_abs,
    f64_neg,
    f64_ceil,
    f64_floor,
    f64_trunc,
    f64_nearest,
    f64_sqrt,
    f64_add,
    f64_sub,
    f64_mul,
    f64_div,
    f64_min,
    f64_max,
    f64_copysign,
    i32_wrap_i64,
    i32_trunc_f32_s,
    i32_trunc_f32_u,
    i32_trunc_f64_s,
    i32_trunc_f64_u,
    i64_extend_i32_s,
    i64_extend_i32_u,
    i64_trunc_f32_s,
    i64_trunc_f32_u,
    i64_trunc_f64_s,
    i64_trunc_f64_u,
    f32_convert_i32_s,
    f32_convert_i32_u,
    f32_convert_i64_s,
    f32_convert_i64_u,
    f32_demote_f64,
    f64_convert_i32_s,
    f64_convert_i32_u,
    f64_convert_i64_s,
    f64_convert_i64_u,
    f64_promote_f32,
    i32_reinterpret_f32,
    i64_reinterpret_f64,
    f32_reinterpret_i32,
    f64_reinterpret_i64,
    i32_extend8_s,
    i32_extend16_s,
    i64_extend8_s,
    i64_extend16_s,
    i64_extend32_s,
    i32_trunc_sat_f32_s,
    i32_trunc_sat_f32_u,
    i32_trunc_sat_f64_s,
    i32_trunc_sat_f64_u,
    i64_trunc_sat_f32_s,
    i64_trunc_sat_f32_u,
    i64_trunc_sat_f64_s,
    i64_trunc_sat_f64_u,

    // Reference instructions
    ref_null: RefType,
    ref_is_null,
    ref_func: FuncIndex,
};

pub const Expr = []Instr;

pub const Import = struct {
    module: Name,
    name: Name,
    desc: ImportDesc,
};

pub const Global = struct {
    type: GlobalType,
    init: Expr,
};

pub const ExportDesc = union(enum) {
    func: FuncIndex,
    table: TableIndex,
    mem: MemIndex,
    global: GlobalIndex,
};

pub const Export = struct {
    name: Name,
    desc: ExportDesc,
};

pub const ElemMode = union(enum) {
    passive,
    active: struct { table_idx: TableIndex, offset: Expr },
    declarative,
};

pub const ElemInit = union(enum) {
    func_indices: []FuncIndex,
    exprs: []Expr,

    pub fn length(self: ElemInit) usize {
        return switch (self) {
            .func_indices => |indices| indices.len,
            .exprs => |exprs| exprs.len,
        };
    }
};

pub const Elem = struct {
    type: RefType,
    init: ElemInit,
    mode: ElemMode,
};

pub const Locals = struct {
    count: u32,
    type: ValType,
};

pub const Func = struct {
    locals: []Locals,
    body: Expr,
};

pub const Code = Func;

pub const DataMode = union(enum) {
    active: struct { mem_idx: MemIndex, offset: Expr },
    passive,
};

pub const Data = struct {
    init: []Byte,
    mode: DataMode,
};

pub const CustomSection = struct {
    name: Name,
    data: []const Byte,
};

pub const TypeSection = []FuncType;
pub const ImportSection = []Import;
pub const FunctionSection = []TypeIndex;
pub const TableSection = []TableType;
pub const MemorySection = []MemType;
pub const GlobalSection = []Global;
pub const ExportSection = []Export;
pub const StartSection = FuncIndex;
pub const ElementSection = []Elem;
pub const CodeSection = []Code;
pub const DataSection = []Data;

pub const Module = struct {
    /// Raw WASM bytes. Names and other string-like fields are slices into this.
    bytes: []const u8,
    custom: []CustomSection,
    types: TypeSection,
    imports: ImportSection,
    functions: FunctionSection,
    tables: TableSection,
    memories: MemorySection,
    globals: GlobalSection,
    exports: ExportSection,
    start: ?StartSection,
    elements: ElementSection,
    codes: CodeSection,
    data: DataSection,

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.custom);

        for (self.types) |*ft| ft.deinit(allocator);
        allocator.free(self.types);

        allocator.free(self.imports);
        allocator.free(self.functions);
        allocator.free(self.tables);
        allocator.free(self.memories);

        for (self.globals) |global| freeExpr(allocator, global.init);
        allocator.free(self.globals);

        allocator.free(self.exports);

        for (self.elements) |elem| {
            switch (elem.mode) {
                .active => |mode| freeExpr(allocator, mode.offset),
                .passive, .declarative => {},
            }
            switch (elem.init) {
                .func_indices => |s| allocator.free(s),
                .exprs => |exprs| {
                    for (exprs) |expr| freeExpr(allocator, expr);
                    allocator.free(exprs);
                },
            }
        }
        allocator.free(self.elements);

        for (self.codes) |code| {
            allocator.free(code.locals);
            freeExpr(allocator, code.body);
        }
        allocator.free(self.codes);

        for (self.data) |d| {
            allocator.free(d.init);
            switch (d.mode) {
                .active => |mode| freeExpr(allocator, mode.offset),
                .passive => {},
            }
        }
        allocator.free(self.data);
    }

    fn freeExpr(allocator: std.mem.Allocator, expr: Expr) void {
        for (expr) |instr| freeInstr(allocator, instr);
        allocator.free(expr);
    }

    fn freeInstr(allocator: std.mem.Allocator, instr: Instr) void {
        switch (instr) {
            .block => |b| freeExpr(allocator, b.instructions),
            .loop => |b| freeExpr(allocator, b.instructions),
            .@"if" => |i| {
                freeExpr(allocator, i.then_instructions);
                freeExpr(allocator, i.else_instructions);
            },
            .br_table => |bt| allocator.free(bt.label_indices),
            else => {},
        }
    }
};
