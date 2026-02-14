const std = @import("std");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Value = types.Value;
const LocalIndex = types.LocalIndex;
const GlobalIndex = types.GlobalIndex;
const MemIndex = types.MemIndex;

const PC = usize;

const MemArg = struct {
    alignment: u32,
    offset: u32,
    mem: *const MemoryInstance,
};

const BranchTableArg = struct {
    label_pcs: []PC,
    default_pc: PC,
};

pub const FlatInstr = union(enum) {
    // Control instructions
    @"unreachable",
    nop,
    sentinel,
    br: PC,
    br_if: PC,
    br_table: BranchTableArg,
    @"return": usize, // number of values to return
    call: struct { entry_pc: PC, arguments: usize },
    call_indirect: struct { func_type: types.FuncType, table: *const TableInstance },
    call_host: *const HostFunc,

    // Super instructions
    super_i32_eqz_br_if: PC,
    super_i32_eq_br_if: PC,
    super_local_get_local_get: struct { lhs: LocalIndex, rhs: LocalIndex },
    super_local_get_local_get_i32_add: struct { lhs: LocalIndex, rhs: LocalIndex },
    super_local_get_local_get_i32_mul: struct { lhs: LocalIndex, rhs: LocalIndex },
    super_local_get_i32_const_i32_add: struct { local: LocalIndex, imm: i32 },
    super_local_add_i32_const_set: struct { local: LocalIndex, imm: i32 },
    super_local_sub_i32_const_set: struct { local: LocalIndex, imm: i32 },
    super_local_get_i32_const_i32_eq_br_if: struct { local: LocalIndex, imm: i32, target: PC },
    super_local_get_i32_const_i32_ge_u_br_if: struct { local: LocalIndex, imm: i32, target: PC },
    super_local_get_i32_const_i32_le_u_br_if: struct { local: LocalIndex, imm: i32, target: PC },
    super_i32_const_local_set: struct { imm: i32, local: LocalIndex },
    super_i64_const_local_set: struct { imm: i64, local: LocalIndex },
    super_f32_const_local_set: struct { imm: f32, local: LocalIndex },
    super_f64_const_local_set: struct { imm: f64, local: LocalIndex },
    super_i32_const_return: i32,
    super_i64_const_return: i64,
    super_f32_const_return: f32,
    super_f64_const_return: f64,

    // Parametric instructions
    drop,
    select,

    // Variable instructions
    local_get: LocalIndex,
    local_set: LocalIndex,
    local_tee: LocalIndex,
    global_get: *const GlobalInstance,
    global_set: *GlobalInstance,

    // Memory instructions
    i32_load: MemArg,
    i64_load: MemArg,
    f32_load: MemArg,
    f64_load: MemArg,
    i32_load8_s: MemArg,
    i32_load8_u: MemArg,
    i32_load16_s: MemArg,
    i32_load16_u: MemArg,
    i64_load8_s: MemArg,
    i64_load8_u: MemArg,
    i64_load16_s: MemArg,
    i64_load16_u: MemArg,
    i64_load32_s: MemArg,
    i64_load32_u: MemArg,
    i32_store: MemArg,
    i64_store: MemArg,
    f32_store: MemArg,
    f64_store: MemArg,
    i32_store8: MemArg,
    i32_store16: MemArg,
    i64_store8: MemArg,
    i64_store16: MemArg,
    i64_store32: MemArg,
    memory_size: *const MemoryInstance,
    memory_grow: *MemoryInstance,

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

    pub fn format(self: FlatInstr, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            // Control instructions
            .@"unreachable" => try writer.writeAll("unreachable"),
            .nop => try writer.writeAll("nop"),
            .sentinel => try writer.writeAll("placeholder"),
            .br => |target| try writer.print("br {d}", .{target}),
            .br_if => |target| try writer.print("br_if {d}", .{target}),
            .br_table => |arg| {
                try writer.writeAll("br_table [");
                for (arg.label_pcs, 0..) |pc_val, i| {
                    try writer.print("{d}", .{pc_val});
                    if (i != arg.label_pcs.len - 1) try writer.writeAll(", ");
                }
                try writer.print("] default={d}", .{arg.default_pc});
            },
            .@"return" => try writer.print("return", .{}),
            .call => |arg| try writer.print("call pc={d} args={d}", .{ arg.entry_pc, arg.arguments }),
            .call_indirect => try writer.writeAll("call_indirect"),
            .call_host => try writer.writeAll("call_host"),

            // Super instructions
            .super_i32_eqz_br_if => |target| try writer.print("super.i32.eqz.br_if {d}", .{target}),
            .super_i32_eq_br_if => |target| try writer.print("super.i32.eq.br_if {d}", .{target}),
            .super_local_get_local_get => |arg| try writer.print("super.local.get.get {d} {d}", .{ arg.lhs, arg.rhs }),
            .super_local_get_local_get_i32_add => |arg| try writer.print("super.local.get.get.i32.add {d} {d}", .{ arg.lhs, arg.rhs }),
            .super_local_get_local_get_i32_mul => |arg| try writer.print("super.local.get.get.i32.mul {d} {d}", .{ arg.lhs, arg.rhs }),
            .super_local_get_i32_const_i32_add => |arg| try writer.print("super.local.get.i32.const.i32.add {d} {d}", .{ arg.local, arg.imm }),
            .super_local_add_i32_const_set => |arg| try writer.print("super.local.add.i32.const.set {d} {d}", .{ arg.local, arg.imm }),
            .super_local_sub_i32_const_set => |arg| try writer.print("super.local.sub.i32.const.set {d} {d}", .{ arg.local, arg.imm }),
            .super_local_get_i32_const_i32_eq_br_if => |arg| try writer.print("super.local.get.i32.const.i32.eq.br_if {d} {d} -> {d}", .{ arg.local, arg.imm, arg.target }),
            .super_local_get_i32_const_i32_ge_u_br_if => |arg| try writer.print("super.local.get.i32.const.i32.ge_u.br_if {d} {d} -> {d}", .{ arg.local, arg.imm, arg.target }),
            .super_local_get_i32_const_i32_le_u_br_if => |arg| try writer.print("super.local.get.i32.const.i32.le_u.br_if {d} {d} -> {d}", .{ arg.local, arg.imm, arg.target }),
            .super_i32_const_local_set => |arg| try writer.print("super.i32.const.local.set {d} {d}", .{ arg.imm, arg.local }),
            .super_i64_const_local_set => |arg| try writer.print("super.i64.const.local.set {d} {d}", .{ arg.imm, arg.local }),
            .super_f32_const_local_set => |arg| try writer.print("super.f32.const.local.set {d} {d}", .{ arg.imm, arg.local }),
            .super_f64_const_local_set => |arg| try writer.print("super.f64.const.local.set {d} {d}", .{ arg.imm, arg.local }),
            .super_i32_const_return => |imm| try writer.print("super.i32.const.return {d}", .{imm}),
            .super_i64_const_return => |imm| try writer.print("super.i64.const.return {d}", .{imm}),
            .super_f32_const_return => |imm| try writer.print("super.f32.const.return {d}", .{imm}),
            .super_f64_const_return => |imm| try writer.print("super.f64.const.return {d}", .{imm}),

            // Parametric instructions
            .drop => try writer.writeAll("drop"),
            .select => try writer.writeAll("select"),

            // Variable instructions
            .local_get => |idx| try writer.print("local.get {d}", .{idx}),
            .local_set => |idx| try writer.print("local.set {d}", .{idx}),
            .local_tee => |idx| try writer.print("local.tee {d}", .{idx}),
            .global_get => try writer.writeAll("global.get"),
            .global_set => try writer.writeAll("global.set"),

            // Memory instructions
            .i32_load => |arg| try writer.print("i32.load offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .i64_load => |arg| try writer.print("i64.load offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .f32_load => |arg| try writer.print("f32.load offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .f64_load => |arg| try writer.print("f64.load offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .i32_load8_s => |arg| try writer.print("i32.load8_s offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .i32_load8_u => |arg| try writer.print("i32.load8_u offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .i32_load16_s => |arg| try writer.print("i32.load16_s offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .i32_load16_u => |arg| try writer.print("i32.load16_u offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .i64_load8_s => |arg| try writer.print("i64.load8_s offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .i64_load8_u => |arg| try writer.print("i64.load8_u offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .i64_load16_s => |arg| try writer.print("i64.load16_s offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .i64_load16_u => |arg| try writer.print("i64.load16_u offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .i64_load32_s => |arg| try writer.print("i64.load32_s offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .i64_load32_u => |arg| try writer.print("i64.load32_u offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .i32_store => |arg| try writer.print("i32.store offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .i64_store => |arg| try writer.print("i64.store offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .f32_store => |arg| try writer.print("f32.store offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .f64_store => |arg| try writer.print("f64.store offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .i32_store8 => |arg| try writer.print("i32.store8 offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .i32_store16 => |arg| try writer.print("i32.store16 offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .i64_store8 => |arg| try writer.print("i64.store8 offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .i64_store16 => |arg| try writer.print("i64.store16 offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .i64_store32 => |arg| try writer.print("i64.store32 offset={d} align={d}", .{ arg.offset, arg.alignment }),
            .memory_size => try writer.writeAll("memory.size"),
            .memory_grow => try writer.writeAll("memory.grow"),

            // Numeric instructions - constants
            .i32_const => |val| try writer.print("i32.const {d}", .{val}),
            .i64_const => |val| try writer.print("i64.const {d}", .{val}),
            .f32_const => |val| try writer.print("f32.const {d}", .{val}),
            .f64_const => |val| try writer.print("f64.const {d}", .{val}),

            // Numeric instructions - comparisons
            .i32_eqz => try writer.writeAll("i32.eqz"),
            .i32_eq => try writer.writeAll("i32.eq"),
            .i32_ne => try writer.writeAll("i32.ne"),
            .i32_lt_s => try writer.writeAll("i32.lt_s"),
            .i32_lt_u => try writer.writeAll("i32.lt_u"),
            .i32_gt_s => try writer.writeAll("i32.gt_s"),
            .i32_gt_u => try writer.writeAll("i32.gt_u"),
            .i32_le_s => try writer.writeAll("i32.le_s"),
            .i32_le_u => try writer.writeAll("i32.le_u"),
            .i32_ge_s => try writer.writeAll("i32.ge_s"),
            .i32_ge_u => try writer.writeAll("i32.ge_u"),
            .i64_eqz => try writer.writeAll("i64.eqz"),
            .i64_eq => try writer.writeAll("i64.eq"),
            .i64_ne => try writer.writeAll("i64.ne"),
            .i64_lt_s => try writer.writeAll("i64.lt_s"),
            .i64_lt_u => try writer.writeAll("i64.lt_u"),
            .i64_gt_s => try writer.writeAll("i64.gt_s"),
            .i64_gt_u => try writer.writeAll("i64.gt_u"),
            .i64_le_s => try writer.writeAll("i64.le_s"),
            .i64_le_u => try writer.writeAll("i64.le_u"),
            .i64_ge_s => try writer.writeAll("i64.ge_s"),
            .i64_ge_u => try writer.writeAll("i64.ge_u"),
            .f32_eq => try writer.writeAll("f32.eq"),
            .f32_ne => try writer.writeAll("f32.ne"),
            .f32_lt => try writer.writeAll("f32.lt"),
            .f32_gt => try writer.writeAll("f32.gt"),
            .f32_le => try writer.writeAll("f32.le"),
            .f32_ge => try writer.writeAll("f32.ge"),
            .f64_eq => try writer.writeAll("f64.eq"),
            .f64_ne => try writer.writeAll("f64.ne"),
            .f64_lt => try writer.writeAll("f64.lt"),
            .f64_gt => try writer.writeAll("f64.gt"),
            .f64_le => try writer.writeAll("f64.le"),
            .f64_ge => try writer.writeAll("f64.ge"),

            // Numeric instructions - i32 operations
            .i32_clz => try writer.writeAll("i32.clz"),
            .i32_ctz => try writer.writeAll("i32.ctz"),
            .i32_popcnt => try writer.writeAll("i32.popcnt"),
            .i32_add => try writer.writeAll("i32.add"),
            .i32_sub => try writer.writeAll("i32.sub"),
            .i32_mul => try writer.writeAll("i32.mul"),
            .i32_div_s => try writer.writeAll("i32.div_s"),
            .i32_div_u => try writer.writeAll("i32.div_u"),
            .i32_rem_s => try writer.writeAll("i32.rem_s"),
            .i32_rem_u => try writer.writeAll("i32.rem_u"),
            .i32_and => try writer.writeAll("i32.and"),
            .i32_or => try writer.writeAll("i32.or"),
            .i32_xor => try writer.writeAll("i32.xor"),
            .i32_shl => try writer.writeAll("i32.shl"),
            .i32_shr_s => try writer.writeAll("i32.shr_s"),
            .i32_shr_u => try writer.writeAll("i32.shr_u"),
            .i32_rotl => try writer.writeAll("i32.rotl"),
            .i32_rotr => try writer.writeAll("i32.rotr"),

            // Numeric instructions - i64 operations
            .i64_clz => try writer.writeAll("i64.clz"),
            .i64_ctz => try writer.writeAll("i64.ctz"),
            .i64_popcnt => try writer.writeAll("i64.popcnt"),
            .i64_add => try writer.writeAll("i64.add"),
            .i64_sub => try writer.writeAll("i64.sub"),
            .i64_mul => try writer.writeAll("i64.mul"),
            .i64_div_s => try writer.writeAll("i64.div_s"),
            .i64_div_u => try writer.writeAll("i64.div_u"),
            .i64_rem_s => try writer.writeAll("i64.rem_s"),
            .i64_rem_u => try writer.writeAll("i64.rem_u"),
            .i64_and => try writer.writeAll("i64.and"),
            .i64_or => try writer.writeAll("i64.or"),
            .i64_xor => try writer.writeAll("i64.xor"),
            .i64_shl => try writer.writeAll("i64.shl"),
            .i64_shr_s => try writer.writeAll("i64.shr_s"),
            .i64_shr_u => try writer.writeAll("i64.shr_u"),
            .i64_rotl => try writer.writeAll("i64.rotl"),
            .i64_rotr => try writer.writeAll("i64.rotr"),

            // Numeric instructions - f32 operations
            .f32_abs => try writer.writeAll("f32.abs"),
            .f32_neg => try writer.writeAll("f32.neg"),
            .f32_ceil => try writer.writeAll("f32.ceil"),
            .f32_floor => try writer.writeAll("f32.floor"),
            .f32_trunc => try writer.writeAll("f32.trunc"),
            .f32_nearest => try writer.writeAll("f32.nearest"),
            .f32_sqrt => try writer.writeAll("f32.sqrt"),
            .f32_add => try writer.writeAll("f32.add"),
            .f32_sub => try writer.writeAll("f32.sub"),
            .f32_mul => try writer.writeAll("f32.mul"),
            .f32_div => try writer.writeAll("f32.div"),
            .f32_min => try writer.writeAll("f32.min"),
            .f32_max => try writer.writeAll("f32.max"),
            .f32_copysign => try writer.writeAll("f32.copysign"),

            // Numeric instructions - f64 operations
            .f64_abs => try writer.writeAll("f64.abs"),
            .f64_neg => try writer.writeAll("f64.neg"),
            .f64_ceil => try writer.writeAll("f64.ceil"),
            .f64_floor => try writer.writeAll("f64.floor"),
            .f64_trunc => try writer.writeAll("f64.trunc"),
            .f64_nearest => try writer.writeAll("f64.nearest"),
            .f64_sqrt => try writer.writeAll("f64.sqrt"),
            .f64_add => try writer.writeAll("f64.add"),
            .f64_sub => try writer.writeAll("f64.sub"),
            .f64_mul => try writer.writeAll("f64.mul"),
            .f64_div => try writer.writeAll("f64.div"),
            .f64_min => try writer.writeAll("f64.min"),
            .f64_max => try writer.writeAll("f64.max"),
            .f64_copysign => try writer.writeAll("f64.copysign"),

            // Conversion instructions
            .i32_wrap_i64 => try writer.writeAll("i32.wrap_i64"),
            .i32_trunc_f32_s => try writer.writeAll("i32.trunc_f32_s"),
            .i32_trunc_f32_u => try writer.writeAll("i32.trunc_f32_u"),
            .i32_trunc_f64_s => try writer.writeAll("i32.trunc_f64_s"),
            .i32_trunc_f64_u => try writer.writeAll("i32.trunc_f64_u"),
            .i64_extend_i32_s => try writer.writeAll("i64.extend_i32_s"),
            .i64_extend_i32_u => try writer.writeAll("i64.extend_i32_u"),
            .i64_trunc_f32_s => try writer.writeAll("i64.trunc_f32_s"),
            .i64_trunc_f32_u => try writer.writeAll("i64.trunc_f32_u"),
            .i64_trunc_f64_s => try writer.writeAll("i64.trunc_f64_s"),
            .i64_trunc_f64_u => try writer.writeAll("i64.trunc_f64_u"),
            .f32_convert_i32_s => try writer.writeAll("f32.convert_i32_s"),
            .f32_convert_i32_u => try writer.writeAll("f32.convert_i32_u"),
            .f32_convert_i64_s => try writer.writeAll("f32.convert_i64_s"),
            .f32_convert_i64_u => try writer.writeAll("f32.convert_i64_u"),
            .f32_demote_f64 => try writer.writeAll("f32.demote_f64"),
            .f64_convert_i32_s => try writer.writeAll("f64.convert_i32_s"),
            .f64_convert_i32_u => try writer.writeAll("f64.convert_i32_u"),
            .f64_convert_i64_s => try writer.writeAll("f64.convert_i64_s"),
            .f64_convert_i64_u => try writer.writeAll("f64.convert_i64_u"),
            .f64_promote_f32 => try writer.writeAll("f64.promote_f32"),
            .i32_reinterpret_f32 => try writer.writeAll("i32.reinterpret_f32"),
            .i64_reinterpret_f64 => try writer.writeAll("i64.reinterpret_f64"),
            .f32_reinterpret_i32 => try writer.writeAll("f32.reinterpret_i32"),
            .f64_reinterpret_i64 => try writer.writeAll("f64.reinterpret_i64"),
            .i32_extend8_s => try writer.writeAll("i32.extend8_s"),
            .i32_extend16_s => try writer.writeAll("i32.extend16_s"),
            .i64_extend8_s => try writer.writeAll("i64.extend8_s"),
            .i64_extend16_s => try writer.writeAll("i64.extend16_s"),
            .i64_extend32_s => try writer.writeAll("i64.extend32_s"),
        }
    }
};

const BranchToPatch = union(enum) {
    br_patch: usize, // branch instruction index
    br_table_patch: struct { instr_idx: usize, label: union(enum) { default, index: usize } },
};

pub const BlockLabelKind = enum { block, loop, @"if" };
pub const BlockLabel = struct {
    kind: BlockLabelKind,
    start: PC,
    end: PC,
    branches_to_patch: ArrayList(BranchToPatch),

    fn deinit(self: *BlockLabel, allocator: Allocator) void {
        self.branches_to_patch.deinit(allocator);
    }
};

pub const FuncLabel = struct {
    entry: PC,
    calls_to_patch: ArrayList(usize),

    fn deinit(self: *FuncLabel, allocator: Allocator) void {
        self.calls_to_patch.deinit(allocator);
    }
};

pub const Bytecode = struct {
    instrs: []FlatInstr,
    functions: []?PC, // store function addr -> entry program counter

    pub fn deinit(self: *Bytecode, allocator: Allocator) void {
        for (self.instrs) |instr| {
            switch (instr) {
                .br_table => |arg| {
                    allocator.free(arg.label_pcs);
                },
                else => {},
            }
        }

        allocator.free(self.instrs);
        allocator.free(self.functions);
    }

    pub fn format(self: *const Bytecode, writer: *std.Io.Writer) !void {
        try writer.writeAll("\n=== Bytecode Instructions ===\n");
        try writer.print("Total instructions: {d}\n", .{self.instrs.len});
        try writer.print("Function count: {d}\n\n", .{self.functions.len});

        // Print function entry points
        try writer.writeAll("Function Entry Points:\n");
        for (self.functions, 0..) |maybe_entry, func_idx| {
            if (maybe_entry) |entry| {
                try writer.print("  func[{d}] -> {d}\n", .{ func_idx, entry });
            }
        }
        try writer.writeAll("\n");

        // Print instructions
        try writer.writeAll("Instructions:\n");

        for (self.instrs, 0..) |instr, pc| {
            try writer.print("  {d:4}: ", .{pc});
            try instr.format(writer);
            try writer.writeAll("\n");
        }

        try writer.writeAll("=============================\n\n");
    }
};

const BytecodeLowering = struct {
    allocator: Allocator,
    instrs: ArrayList(FlatInstr),
    block_labels: ArrayList(BlockLabel),
    func_labels: []FuncLabel,
    flat: ArrayList(FlatInstr),
    store: *const Store,
    current_func: ?*const WasmFunc,

    pub fn init(allocator: Allocator, store: *const Store) !BytecodeLowering {
        const func_labels = try allocator.alloc(FuncLabel, store.funcs.items.len);

        for (func_labels) |*label| {
            label.* = FuncLabel{
                .entry = 0,
                .calls_to_patch = .empty,
            };
        }

        return BytecodeLowering{
            .allocator = allocator,
            .instrs = .empty,
            .block_labels = .empty,
            .func_labels = func_labels,
            .flat = .empty,
            .store = store,
            .current_func = null,
        };
    }

    pub fn deinit(self: *BytecodeLowering) void {
        self.instrs.deinit(self.allocator);

        for (self.block_labels.items) |*label| {
            label.deinit(self.allocator);
        }

        self.block_labels.deinit(self.allocator);

        for (self.func_labels) |*label| {
            label.deinit(self.allocator);
        }

        self.allocator.free(self.func_labels);

        self.flat.deinit(self.allocator);
    }

    fn emit(self: *BytecodeLowering, instr: FlatInstr) !void {
        try self.flat.append(self.allocator, instr);
    }

    pub fn lower(self: *BytecodeLowering) !Bytecode {
        for (self.store.funcs.items, 0..) |func, i| {
            switch (func) {
                .wasm => |wasm_func| {
                    try self.lowerFunc(&wasm_func, i);
                },
                .host => {
                    return error.UnsupportedFuncTypeForLowering;
                },
            }
        }

        // Patch call instructions with actual function addresses
        for (self.func_labels) |func_label| {
            for (func_label.calls_to_patch.items) |call_idx| {
                switch (self.flat.items[call_idx]) {
                    .call => |*arg| {
                        arg.*.entry_pc = func_label.entry;
                    },
                    else => {
                        return error.InvalidCallInstructionForPatching;
                    },
                }
            }
        }

        try self.detectSuperInstructions();
        try self.moveSentinelsToTailAndTrim();

        var function_pc_mapping = try self.allocator.alloc(?PC, self.store.funcs.items.len);
        @memset(function_pc_mapping, null);

        for (self.func_labels, 0..) |func_label, i| {
            function_pc_mapping[i] = func_label.entry;
        }

        const instrs = try self.flat.toOwnedSlice(self.allocator);

        return Bytecode{
            .instrs = instrs,
            .functions = function_pc_mapping,
        };
    }

    fn moveSentinelsToTailAndTrim(self: *BytecodeLowering) !void {
        if (self.flat.items.len == 0) return;

        const old_len = self.flat.items.len;

        const remapPc = struct {
            fn countNonSentinelsBefore(instrs: []const FlatInstr, limit: PC) PC {
                var count: PC = 0;
                var i: usize = 0;

                while (i < limit) : (i += 1) {
                    if (instrs[i] != .sentinel) {
                        count += 1;
                    }
                }

                return count;
            }

            fn countNonSentinels(instrs: []const FlatInstr) PC {
                return countNonSentinelsBefore(instrs, instrs.len);
            }

            fn resolve(instrs: []const FlatInstr, old_pc: PC) PC {
                std.debug.assert(old_pc <= instrs.len);

                var pc = old_pc;
                while (pc < instrs.len and instrs[pc] == .sentinel) : (pc += 1) {}

                if (pc == instrs.len) {
                    return countNonSentinels(instrs);
                }

                return countNonSentinelsBefore(instrs, pc);
            }
        }.resolve;

        // Rewrite all PC-based targets against the pre-compaction layout
        const original_instrs = self.flat.items;
        for (self.flat.items) |*instr| {
            switch (instr.*) {
                .br => |*target| {
                    target.* = remapPc(original_instrs, target.*);
                },
                .br_if => |*target| {
                    target.* = remapPc(original_instrs, target.*);
                },
                .br_table => |*arg| {
                    for (arg.label_pcs) |*label_pc| {
                        label_pc.* = remapPc(original_instrs, label_pc.*);
                    }

                    arg.default_pc = remapPc(original_instrs, arg.default_pc);
                },
                .call => |*arg| {
                    arg.entry_pc = remapPc(original_instrs, arg.entry_pc);
                },
                .super_i32_eqz_br_if => |*target| {
                    target.* = remapPc(original_instrs, target.*);
                },
                .super_i32_eq_br_if => |*target| {
                    target.* = remapPc(original_instrs, target.*);
                },
                .super_local_get_i32_const_i32_eq_br_if => |*arg| {
                    arg.target = remapPc(original_instrs, arg.target);
                },
                .super_local_get_i32_const_i32_ge_u_br_if => |*arg| {
                    arg.target = remapPc(original_instrs, arg.target);
                },
                .super_local_get_i32_const_i32_le_u_br_if => |*arg| {
                    arg.target = remapPc(original_instrs, arg.target);
                },
                else => {},
            }
        }

        for (self.func_labels) |*label| {
            label.entry = remapPc(original_instrs, label.entry);
        }

        // Stable in-place compaction: keep non-sentinel instructions in order,
        // then shrink logical length to trim all sentinels from execution.
        var write: usize = 0;
        for (0..old_len) |read| {
            const instr = self.flat.items[read];
            if (instr != .sentinel) {
                if (write != read) {
                    self.flat.items[write] = instr;
                }

                write += 1;
            }
        }

        self.flat.items.len = write;
    }

    fn detectSuperInstructions(self: *BytecodeLowering) !void {
        if (self.flat.items.len < 2) return;

        // List of branch/function-entry targets. We never fuse away an
        // instruction at one of these PCs (except pattern start) to avoid
        // changing externally reachable control-flow entry points.
        var target_pcs: ArrayList(PC) = .empty;
        defer target_pcs.deinit(self.allocator);

        for (self.func_labels) |func_label| {
            if (func_label.entry < self.flat.items.len) {
                try self.appendTargetPcUnique(&target_pcs, func_label.entry);
            }
        }

        for (self.flat.items) |instr| {
            switch (instr) {
                .br => |target| if (target < self.flat.items.len) {
                    try self.appendTargetPcUnique(&target_pcs, target);
                },
                .br_if => |target| if (target < self.flat.items.len) {
                    try self.appendTargetPcUnique(&target_pcs, target);
                },
                .br_table => |arg| {
                    for (arg.label_pcs) |target| {
                        if (target < self.flat.items.len) {
                            try self.appendTargetPcUnique(&target_pcs, target);
                        }
                    }

                    if (arg.default_pc < self.flat.items.len) {
                        try self.appendTargetPcUnique(&target_pcs, arg.default_pc);
                    }
                },
                else => {},
            }
        }

        var i: usize = 0;
        while (i < self.flat.items.len) : (i += 1) {
            if (self.matchTagPattern(i, &.{ .i32_eqz, .br_if }, target_pcs.items)) {
                const target = self.flat.items[i + 1].br_if;
                self.flat.items[i] = .{ .super_i32_eqz_br_if = target };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .i32_const, .local_set }, target_pcs.items)) {
                const imm = self.flat.items[i].i32_const;
                const local = self.flat.items[i + 1].local_set;
                self.flat.items[i] = .{ .super_i32_const_local_set = .{ .imm = imm, .local = local } };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .i64_const, .local_set }, target_pcs.items)) {
                const imm = self.flat.items[i].i64_const;
                const local = self.flat.items[i + 1].local_set;
                self.flat.items[i] = .{ .super_i64_const_local_set = .{ .imm = imm, .local = local } };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .f32_const, .local_set }, target_pcs.items)) {
                const imm = self.flat.items[i].f32_const;
                const local = self.flat.items[i + 1].local_set;
                self.flat.items[i] = .{ .super_f32_const_local_set = .{ .imm = imm, .local = local } };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .f64_const, .local_set }, target_pcs.items)) {
                const imm = self.flat.items[i].f64_const;
                const local = self.flat.items[i + 1].local_set;
                self.flat.items[i] = .{ .super_f64_const_local_set = .{ .imm = imm, .local = local } };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .i32_const, .ret }, target_pcs.items) and self.flat.items[i + 1].@"return" == 1) {
                const imm = self.flat.items[i].i32_const;
                self.flat.items[i] = .{ .super_i32_const_return = imm };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .i64_const, .ret }, target_pcs.items) and self.flat.items[i + 1].@"return" == 1) {
                const imm = self.flat.items[i].i64_const;
                self.flat.items[i] = .{ .super_i64_const_return = imm };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .f32_const, .ret }, target_pcs.items) and self.flat.items[i + 1].@"return" == 1) {
                const imm = self.flat.items[i].f32_const;
                self.flat.items[i] = .{ .super_f32_const_return = imm };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .f64_const, .ret }, target_pcs.items) and self.flat.items[i + 1].@"return" == 1) {
                const imm = self.flat.items[i].f64_const;
                self.flat.items[i] = .{ .super_f64_const_return = imm };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .i32_eq, .br_if }, target_pcs.items)) {
                const target = self.flat.items[i + 1].br_if;
                self.flat.items[i] = .{ .super_i32_eq_br_if = target };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .local_get, .local_get, .i32_add }, target_pcs.items)) {
                const lhs = self.flat.items[i].local_get;
                const rhs = self.flat.items[i + 1].local_get;
                self.flat.items[i] = .{ .super_local_get_local_get_i32_add = .{ .lhs = lhs, .rhs = rhs } };
                self.flat.items[i + 1] = .sentinel;
                self.flat.items[i + 2] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .local_get, .local_get, .i32_mul }, target_pcs.items)) {
                const lhs = self.flat.items[i].local_get;
                const rhs = self.flat.items[i + 1].local_get;
                self.flat.items[i] = .{ .super_local_get_local_get_i32_mul = .{ .lhs = lhs, .rhs = rhs } };
                self.flat.items[i + 1] = .sentinel;
                self.flat.items[i + 2] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .local_get, .i32_const, .i32_add }, target_pcs.items)) {
                const lhs = self.flat.items[i].local_get;
                const imm = self.flat.items[i + 1].i32_const;
                self.flat.items[i] = .{ .super_local_get_i32_const_i32_add = .{ .local = lhs, .imm = imm } };
                self.flat.items[i + 1] = .sentinel;
                self.flat.items[i + 2] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .local_get, .local_get }, target_pcs.items)) {
                const lhs = self.flat.items[i].local_get;
                const rhs = self.flat.items[i + 1].local_get;
                self.flat.items[i] = .{ .super_local_get_local_get = .{ .lhs = lhs, .rhs = rhs } };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .local_get, .i32_const, .i32_add, .local_set }, target_pcs.items)) {
                const local = self.flat.items[i].local_get;
                const set_local = self.flat.items[i + 3].local_set;
                if (local == set_local) {
                    const imm = self.flat.items[i + 1].i32_const;
                    self.flat.items[i] = .{ .super_local_add_i32_const_set = .{ .local = local, .imm = imm } };
                    self.flat.items[i + 1] = .sentinel;
                    self.flat.items[i + 2] = .sentinel;
                    self.flat.items[i + 3] = .sentinel;
                    continue;
                }
            }

            if (self.matchTagPattern(i, &.{ .local_get, .i32_const, .i32_sub, .local_set }, target_pcs.items)) {
                const local = self.flat.items[i].local_get;
                const set_local = self.flat.items[i + 3].local_set;
                if (local == set_local) {
                    const imm = self.flat.items[i + 1].i32_const;
                    self.flat.items[i] = .{ .super_local_sub_i32_const_set = .{ .local = local, .imm = imm } };
                    self.flat.items[i + 1] = .sentinel;
                    self.flat.items[i + 2] = .sentinel;
                    self.flat.items[i + 3] = .sentinel;
                    continue;
                }
            }

            if (self.matchTagPattern(i, &.{ .local_get, .i32_const, .i32_eq, .br_if }, target_pcs.items)) {
                const local = self.flat.items[i].local_get;
                const imm = self.flat.items[i + 1].i32_const;
                const target = self.flat.items[i + 3].br_if;
                self.flat.items[i] = .{ .super_local_get_i32_const_i32_eq_br_if = .{ .local = local, .imm = imm, .target = target } };
                self.flat.items[i + 1] = .sentinel;
                self.flat.items[i + 2] = .sentinel;
                self.flat.items[i + 3] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .local_get, .i32_const, .i32_ge_u, .br_if }, target_pcs.items)) {
                const local = self.flat.items[i].local_get;
                const imm = self.flat.items[i + 1].i32_const;
                const target = self.flat.items[i + 3].br_if;
                self.flat.items[i] = .{ .super_local_get_i32_const_i32_ge_u_br_if = .{ .local = local, .imm = imm, .target = target } };
                self.flat.items[i + 1] = .sentinel;
                self.flat.items[i + 2] = .sentinel;
                self.flat.items[i + 3] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .local_get, .i32_const, .i32_le_u, .br_if }, target_pcs.items)) {
                const local = self.flat.items[i].local_get;
                const imm = self.flat.items[i + 1].i32_const;
                const target = self.flat.items[i + 3].br_if;
                self.flat.items[i] = .{ .super_local_get_i32_const_i32_le_u_br_if = .{ .local = local, .imm = imm, .target = target } };
                self.flat.items[i + 1] = .sentinel;
                self.flat.items[i + 2] = .sentinel;
                self.flat.items[i + 3] = .sentinel;
                continue;
            }
        }
    }

    fn appendTargetPcUnique(self: *BytecodeLowering, target_pcs: *ArrayList(PC), pc: PC) !void {
        for (target_pcs.items) |existing| {
            if (existing == pc) return;
        }

        try target_pcs.append(self.allocator, pc);
    }

    const InstrTag = enum {
        other,
        i32_eqz,
        i32_eq,
        i32_add,
        i32_sub,
        i32_mul,
        i32_ge_u,
        i32_le_u,
        i32_const,
        i64_const,
        f32_const,
        f64_const,
        local_get,
        local_set,
        br_if,
        ret,
    };

    fn tagOf(instr: FlatInstr) InstrTag {
        return switch (instr) {
            .i32_eqz => .i32_eqz,
            .i32_eq => .i32_eq,
            .i32_add => .i32_add,
            .i32_sub => .i32_sub,
            .i32_mul => .i32_mul,
            .i32_ge_u => .i32_ge_u,
            .i32_le_u => .i32_le_u,
            .i32_const => .i32_const,
            .i64_const => .i64_const,
            .f32_const => .f32_const,
            .f64_const => .f64_const,
            .local_get => .local_get,
            .local_set => .local_set,
            .br_if => .br_if,
            .@"return" => .ret,
            else => .other,
        };
    }

    fn matchTagPattern(self: *const BytecodeLowering, start: usize, tags: []const InstrTag, target_pcs: []const PC) bool {
        if (start + tags.len > self.flat.items.len) return false;

        for (tags, 0..) |tag, offset| {
            if (offset > 0 and isTargetPc(target_pcs, start + offset)) return false;
            if (tagOf(self.flat.items[start + offset]) != tag) return false;
        }

        return true;
    }

    fn isTargetPc(target_pcs: []const PC, pc: PC) bool {
        for (target_pcs) |target| {
            if (target == pc) return true;
        }

        return false;
    }

    fn lowerFunc(self: *BytecodeLowering, func: *const WasmFunc, func_index: usize) !void {
        // record the start of the function
        var label = &self.func_labels[func_index];
        label.entry = self.flat.items.len;
        self.current_func = func;
        defer self.current_func = null;

        // Emit instructions to initialize local variables with default values
        // Note: parameters are already on the stack, pushed by caller
        for (func.code.locals) |local_group| {
            for (0..local_group.count) |_| {
                // Emit const instruction to push default value
                switch (local_group.type) {
                    .i32 => try self.emit(.{ .i32_const = 0 }),
                    .i64 => try self.emit(.{ .i64_const = 0 }),
                    .f32 => try self.emit(.{ .f32_const = 0.0 }),
                    .f64 => try self.emit(.{ .f64_const = 0.0 }),
                }
            }
        }

        for (func.code.body) |instr| {
            try self.lowerInstr(instr);
        }

        try self.emit(.{ .@"return" = func.type.results.len });
    }

    fn patchBranches(self: *BytecodeLowering, label: *const BlockLabel) !void {
        for (label.branches_to_patch.items) |entry| {
            switch (entry) {
                .br_patch => |instr_idx| {
                    switch (self.flat.items[instr_idx]) {
                        .br => |*pc| {
                            pc.* = label.end;
                        },
                        .br_if => |*pc| {
                            pc.* = label.end;
                        },
                        else => {
                            return error.InvalidBranchInstructionForPatching;
                        },
                    }
                },
                .br_table_patch => |arg| {
                    switch (self.flat.items[arg.instr_idx]) {
                        .br_table => |*table| {
                            switch (arg.label) {
                                .default => {
                                    table.default_pc = label.end;
                                },
                                .index => |label_idx| {
                                    if (label_idx >= table.label_pcs.len) {
                                        return error.InvalidBranchTableLabelIndexForPatching;
                                    }

                                    table.label_pcs[label_idx] = label.end;
                                },
                            }
                        },
                        else => {
                            return error.InvalidBranchTableInstructionForPatching;
                        },
                    }
                },
            }
        }
    }

    fn memArg(self: *BytecodeLowering, memarg: types.MemoryInstrArg) MemArg {
        const mem_addr = self.current_func.?.module.mem_addrs[0];

        return MemArg{
            .alignment = memarg.alignment,
            .offset = memarg.offset,
            .mem = &self.store.mems.items[mem_addr],
        };
    }

    fn registerBranchPatch(self: *BytecodeLowering, pc: *PC, label_idx: usize, patch: BranchToPatch) !void {
        if (self.block_labels.items.len <= label_idx) {
            return error.InvalidLabelIndex;
        }

        const label = &self.block_labels.items[self.block_labels.items.len - 1 - label_idx];

        switch (label.kind) {
            .loop => {
                // Branch to the start of the loop
                pc.* = label.start;
            },
            .block, .@"if" => {
                // Emit a placeholder branch instruction and record it for patching
                try label.branches_to_patch.append(self.allocator, patch);

                pc.* = 0; // Placeholder
            },
        }
    }

    fn lowerInstr(self: *BytecodeLowering, instr: types.Instr) !void {
        switch (instr) {
            .@"unreachable" => try self.emit(.@"unreachable"),
            .nop => try self.emit(.nop),
            .block, .loop => |block| {
                const label_kind: BlockLabelKind = switch (instr) {
                    .block => .block,
                    .loop => .loop,
                    else => unreachable,
                };

                try self.block_labels.append(self.allocator, BlockLabel{
                    .kind = label_kind,
                    .start = self.flat.items.len,
                    .end = 0, // To be patched
                    .branches_to_patch = .empty,
                });

                const label_idx = self.block_labels.items.len - 1;

                for (block.instructions) |block_instr| {
                    try self.lowerInstr(block_instr);
                }

                if (label_kind == .block) {
                    var label = &self.block_labels.items[label_idx];
                    label.end = self.flat.items.len;
                    try self.patchBranches(label);
                }

                self.block_labels.items[label_idx].deinit(self.allocator);
                self.block_labels.items.len -= 1; // Pop the label
            },
            .@"if" => |if_| {
                try self.block_labels.append(self.allocator, BlockLabel{
                    .kind = .@"if",
                    .start = self.flat.items.len,
                    .end = 0, // To be patched
                    .branches_to_patch = .empty,
                });

                const exit_label_idx = self.block_labels.items.len - 1;

                // negate condition to skip then block if false
                try self.emit(.i32_eqz);
                const else_jump_idx = self.flat.items.len;
                try self.emit(.{ .br_if = 0 }); // Placeholder for branch to else block

                for (if_.then_instructions) |then_instr| {
                    try self.lowerInstr(then_instr);
                }

                // Unconditionally jump to end of if after then block
                try self.block_labels.items[exit_label_idx].branches_to_patch.append(self.allocator, BranchToPatch{
                    .br_patch = self.flat.items.len,
                });

                try self.emit(.{ .br = 0 });

                self.flat.items[else_jump_idx] = .{ .br_if = self.flat.items.len }; // Patch branch to else block

                for (if_.else_instructions) |else_instr| {
                    try self.lowerInstr(else_instr);
                }

                var exit_label = &self.block_labels.items[exit_label_idx];
                exit_label.end = self.flat.items.len;
                try self.patchBranches(exit_label);
                exit_label.deinit(self.allocator);
                self.block_labels.items.len -= 1; // Pop the label
            },
            .br, .br_if => |label_idx| {
                if (self.block_labels.items.len <= label_idx) {
                    return error.InvalidLabelIndex;
                }

                const label = &self.block_labels.items[self.block_labels.items.len - 1 - label_idx];

                switch (label.kind) {
                    .loop => {
                        // Branch to the start of the loop
                        try self.emit(switch (instr) {
                            .br => .{ .br = label.start },
                            .br_if => .{ .br_if = label.start },
                            else => unreachable,
                        });
                    },
                    .block, .@"if" => {
                        // Emit a placeholder branch instruction and record it for patching
                        const patch_idx = self.flat.items.len;
                        try label.branches_to_patch.append(self.allocator, BranchToPatch{
                            .br_patch = patch_idx,
                        });

                        try self.emit(switch (instr) {
                            .br => .{ .br = 0 },
                            .br_if => .{ .br_if = 0 },
                            else => unreachable,
                        });
                    },
                }
            },
            .br_table => |arg| {
                const label_pcs = try self.allocator.alloc(PC, arg.label_indices.len);
                errdefer self.allocator.free(label_pcs);
                const instr_idx = self.flat.items.len;

                for (label_pcs, 0..) |*pc, i| {
                    const label_idx = arg.label_indices[i];
                    try self.registerBranchPatch(pc, label_idx, BranchToPatch{ .br_table_patch = .{
                        .instr_idx = instr_idx,
                        .label = .{ .index = i },
                    } });
                }

                var br_table_arg = BranchTableArg{
                    .label_pcs = label_pcs,
                    .default_pc = 0, // To be patched
                };

                try self.registerBranchPatch(&br_table_arg.default_pc, arg.default_idx, BranchToPatch{ .br_table_patch = .{
                    .instr_idx = instr_idx,
                    .label = .default,
                } });

                try self.emit(.{ .br_table = .{ .label_pcs = label_pcs, .default_pc = 0 } });
            },
            .call => |func_idx| {
                const call_instr_idx = self.flat.items.len;
                const func_inst = self.store.funcs.items[func_idx];

                switch (func_inst) {
                    .wasm => |wasm_func| {
                        try self.emit(.{ .call = .{ .entry_pc = 0, .arguments = wasm_func.type.params.len } });
                        std.debug.assert(func_idx < self.func_labels.len);
                        try self.func_labels[func_idx].calls_to_patch.append(self.allocator, call_instr_idx);
                    },
                    .host => |*host_func| {
                        try self.emit(.{ .call_host = host_func });
                    },
                }
            },
            .call_indirect => |arg| {
                std.debug.assert(self.current_func != null);
                std.debug.assert(self.current_func.?.module.table_addrs.len > arg.table_idx);
                const module_inst = self.current_func.?.module;
                const table_addr = module_inst.table_addrs[arg.table_idx];
                const table_inst = &self.store.tables.items[table_addr];
                std.debug.assert(module_inst.types.len > arg.type_idx);
                const func_type = module_inst.types[arg.type_idx];
                try self.emit(.{ .call_indirect = .{ .func_type = func_type, .table = table_inst } });
            },
            .@"return" => {
                if (self.current_func) |f| {
                    try self.emit(.{ .@"return" = f.type.results.len });
                } else {
                    return error.ReturnInstructionOutsideOfFunction;
                }
            },
            .drop => try self.emit(.drop),
            .select => try self.emit(.select),
            .local_get => |idx| try self.emit(.{ .local_get = idx }),
            .local_set => |idx| try self.emit(.{ .local_set = idx }),
            .local_tee => |idx| try self.emit(.{ .local_tee = idx }),
            .global_get, .global_set => |idx| {
                std.debug.assert(self.current_func.?.module.global_addrs.len > idx);
                const global_addr = self.current_func.?.module.global_addrs[idx];
                const global_inst = &self.store.globals.items[global_addr];

                switch (instr) {
                    .global_get => try self.emit(.{ .global_get = global_inst }),
                    else => try self.emit(.{ .global_set = global_inst }),
                }
            },
            .i32_load => |arg| try self.emit(.{ .i32_load = self.memArg(arg) }),
            .i64_load => |arg| try self.emit(.{ .i64_load = self.memArg(arg) }),
            .f32_load => |arg| try self.emit(.{ .f32_load = self.memArg(arg) }),
            .f64_load => |arg| try self.emit(.{ .f64_load = self.memArg(arg) }),
            .i32_load8_s => |arg| try self.emit(.{ .i32_load8_s = self.memArg(arg) }),
            .i32_load8_u => |arg| try self.emit(.{ .i32_load8_u = self.memArg(arg) }),
            .i32_load16_s => |arg| try self.emit(.{ .i32_load16_s = self.memArg(arg) }),
            .i32_load16_u => |arg| try self.emit(.{ .i32_load16_u = self.memArg(arg) }),
            .i64_load8_s => |arg| try self.emit(.{ .i64_load8_s = self.memArg(arg) }),
            .i64_load8_u => |arg| try self.emit(.{ .i64_load8_u = self.memArg(arg) }),
            .i64_load16_s => |arg| try self.emit(.{ .i64_load16_s = self.memArg(arg) }),
            .i64_load16_u => |arg| try self.emit(.{ .i64_load16_u = self.memArg(arg) }),
            .i64_load32_s => |arg| try self.emit(.{ .i64_load32_s = self.memArg(arg) }),
            .i64_load32_u => |arg| try self.emit(.{ .i64_load32_u = self.memArg(arg) }),
            .i32_store => |arg| try self.emit(.{ .i32_store = self.memArg(arg) }),
            .i64_store => |arg| try self.emit(.{ .i64_store = self.memArg(arg) }),
            .f32_store => |arg| try self.emit(.{ .f32_store = self.memArg(arg) }),
            .f64_store => |arg| try self.emit(.{ .f64_store = self.memArg(arg) }),
            .i32_store8 => |arg| try self.emit(.{ .i32_store8 = self.memArg(arg) }),
            .i32_store16 => |arg| try self.emit(.{ .i32_store16 = self.memArg(arg) }),
            .i64_store8 => |arg| try self.emit(.{ .i64_store8 = self.memArg(arg) }),
            .i64_store16 => |arg| try self.emit(.{ .i64_store16 = self.memArg(arg) }),
            .i64_store32 => |arg| try self.emit(.{ .i64_store32 = self.memArg(arg) }),
            .memory_size => |idx| {
                const mem_addr = self.current_func.?.module.mem_addrs[idx];
                try self.emit(.{ .memory_size = &self.store.mems.items[mem_addr] });
            },
            .memory_grow => |idx| {
                const mem_addr = self.current_func.?.module.mem_addrs[idx];
                try self.emit(.{ .memory_grow = &self.store.mems.items[mem_addr] });
            },
            .i32_const => |n| try self.emit(.{ .i32_const = n }),
            .i64_const => |n| try self.emit(.{ .i64_const = n }),
            .f32_const => |x| try self.emit(.{ .f32_const = x }),
            .f64_const => |x| try self.emit(.{ .f64_const = x }),
            .i32_eqz => try self.emit(.i32_eqz),
            .i32_eq => try self.emit(.i32_eq),
            .i32_ne => try self.emit(.i32_ne),
            .i32_lt_s => try self.emit(.i32_lt_s),
            .i32_lt_u => try self.emit(.i32_lt_u),
            .i32_gt_s => try self.emit(.i32_gt_s),
            .i32_gt_u => try self.emit(.i32_gt_u),
            .i32_le_s => try self.emit(.i32_le_s),
            .i32_le_u => try self.emit(.i32_le_u),
            .i32_ge_s => try self.emit(.i32_ge_s),
            .i32_ge_u => try self.emit(.i32_ge_u),
            .i64_eqz => try self.emit(.i64_eqz),
            .i64_eq => try self.emit(.i64_eq),
            .i64_ne => try self.emit(.i64_ne),
            .i64_lt_s => try self.emit(.i64_lt_s),
            .i64_lt_u => try self.emit(.i64_lt_u),
            .i64_gt_s => try self.emit(.i64_gt_s),
            .i64_gt_u => try self.emit(.i64_gt_u),
            .i64_le_s => try self.emit(.i64_le_s),
            .i64_le_u => try self.emit(.i64_le_u),
            .i64_ge_s => try self.emit(.i64_ge_s),
            .i64_ge_u => try self.emit(.i64_ge_u),
            .f32_eq => try self.emit(.f32_eq),
            .f32_ne => try self.emit(.f32_ne),
            .f32_lt => try self.emit(.f32_lt),
            .f32_gt => try self.emit(.f32_gt),
            .f32_le => try self.emit(.f32_le),
            .f32_ge => try self.emit(.f32_ge),
            .f64_eq => try self.emit(.f64_eq),
            .f64_ne => try self.emit(.f64_ne),
            .f64_lt => try self.emit(.f64_lt),
            .f64_gt => try self.emit(.f64_gt),
            .f64_le => try self.emit(.f64_le),
            .f64_ge => try self.emit(.f64_ge),
            .i32_clz => try self.emit(.i32_clz),
            .i32_ctz => try self.emit(.i32_ctz),
            .i32_popcnt => try self.emit(.i32_popcnt),
            .i32_add => try self.emit(.i32_add),
            .i32_sub => try self.emit(.i32_sub),
            .i32_mul => try self.emit(.i32_mul),
            .i32_div_s => try self.emit(.i32_div_s),
            .i32_div_u => try self.emit(.i32_div_u),
            .i32_rem_s => try self.emit(.i32_rem_s),
            .i32_rem_u => try self.emit(.i32_rem_u),
            .i32_and => try self.emit(.i32_and),
            .i32_or => try self.emit(.i32_or),
            .i32_xor => try self.emit(.i32_xor),
            .i32_shl => try self.emit(.i32_shl),
            .i32_shr_s => try self.emit(.i32_shr_s),
            .i32_shr_u => try self.emit(.i32_shr_u),
            .i32_rotl => try self.emit(.i32_rotl),
            .i32_rotr => try self.emit(.i32_rotr),
            .i64_clz => try self.emit(.i64_clz),
            .i64_ctz => try self.emit(.i64_ctz),
            .i64_popcnt => try self.emit(.i64_popcnt),
            .i64_add => try self.emit(.i64_add),
            .i64_sub => try self.emit(.i64_sub),
            .i64_mul => try self.emit(.i64_mul),
            .i64_div_s => try self.emit(.i64_div_s),
            .i64_div_u => try self.emit(.i64_div_u),
            .i64_rem_s => try self.emit(.i64_rem_s),
            .i64_rem_u => try self.emit(.i64_rem_u),
            .i64_and => try self.emit(.i64_and),
            .i64_or => try self.emit(.i64_or),
            .i64_xor => try self.emit(.i64_xor),
            .i64_shl => try self.emit(.i64_shl),
            .i64_shr_s => try self.emit(.i64_shr_s),
            .i64_shr_u => try self.emit(.i64_shr_u),
            .i64_rotl => try self.emit(.i64_rotl),
            .i64_rotr => try self.emit(.i64_rotr),
            .f32_abs => try self.emit(.f32_abs),
            .f32_neg => try self.emit(.f32_neg),
            .f32_ceil => try self.emit(.f32_ceil),
            .f32_floor => try self.emit(.f32_floor),
            .f32_trunc => try self.emit(.f32_trunc),
            .f32_nearest => try self.emit(.f32_nearest),
            .f32_sqrt => try self.emit(.f32_sqrt),
            .f32_add => try self.emit(.f32_add),
            .f32_sub => try self.emit(.f32_sub),
            .f32_mul => try self.emit(.f32_mul),
            .f32_div => try self.emit(.f32_div),
            .f32_min => try self.emit(.f32_min),
            .f32_max => try self.emit(.f32_max),
            .f32_copysign => try self.emit(.f32_copysign),
            .f64_abs => try self.emit(.f64_abs),
            .f64_neg => try self.emit(.f64_neg),
            .f64_ceil => try self.emit(.f64_ceil),
            .f64_floor => try self.emit(.f64_floor),
            .f64_trunc => try self.emit(.f64_trunc),
            .f64_nearest => try self.emit(.f64_nearest),
            .f64_sqrt => try self.emit(.f64_sqrt),
            .f64_add => try self.emit(.f64_add),
            .f64_sub => try self.emit(.f64_sub),
            .f64_mul => try self.emit(.f64_mul),
            .f64_div => try self.emit(.f64_div),
            .f64_min => try self.emit(.f64_min),
            .f64_max => try self.emit(.f64_max),
            .f64_copysign => try self.emit(.f64_copysign),
            .i32_wrap_i64 => try self.emit(.i32_wrap_i64),
            .i32_trunc_f32_s => try self.emit(.i32_trunc_f32_s),
            .i32_trunc_f32_u => try self.emit(.i32_trunc_f32_u),
            .i32_trunc_f64_s => try self.emit(.i32_trunc_f64_s),
            .i32_trunc_f64_u => try self.emit(.i32_trunc_f64_u),
            .i64_extend_i32_s => try self.emit(.i64_extend_i32_s),
            .i64_extend_i32_u => try self.emit(.i64_extend_i32_u),
            .i64_trunc_f32_s => try self.emit(.i64_trunc_f32_s),
            .i64_trunc_f32_u => try self.emit(.i64_trunc_f32_u),
            .i64_trunc_f64_s => try self.emit(.i64_trunc_f64_s),
            .i64_trunc_f64_u => try self.emit(.i64_trunc_f64_u),
            .f32_convert_i32_s => try self.emit(.f32_convert_i32_s),
            .f32_convert_i32_u => try self.emit(.f32_convert_i32_u),
            .f32_convert_i64_s => try self.emit(.f32_convert_i64_s),
            .f32_convert_i64_u => try self.emit(.f32_convert_i64_u),
            .f32_demote_f64 => try self.emit(.f32_demote_f64),
            .f64_convert_i32_s => try self.emit(.f64_convert_i32_s),
            .f64_convert_i32_u => try self.emit(.f64_convert_i32_u),
            .f64_convert_i64_s => try self.emit(.f64_convert_i64_s),
            .f64_convert_i64_u => try self.emit(.f64_convert_i64_u),
            .f64_promote_f32 => try self.emit(.f64_promote_f32),
            .i32_reinterpret_f32 => try self.emit(.i32_reinterpret_f32),
            .i64_reinterpret_f64 => try self.emit(.i64_reinterpret_f64),
            .f32_reinterpret_i32 => try self.emit(.f32_reinterpret_i32),
            .f64_reinterpret_i64 => try self.emit(.f64_reinterpret_i64),
            .i32_extend8_s => try self.emit(.i32_extend8_s),
            .i32_extend16_s => try self.emit(.i32_extend16_s),
            .i64_extend8_s => try self.emit(.i64_extend8_s),
            .i64_extend16_s => try self.emit(.i64_extend16_s),
            .i64_extend32_s => try self.emit(.i64_extend32_s),
        }
    }
};

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
    ) !*ModuleInstance {
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

        const module_inst = try allocator.create(ModuleInstance);
        errdefer allocator.destroy(module_inst);
        module_inst.* = ModuleInstance{
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

    fn evalConstExpr(self: *Store, global_addrs: []GlobalAddr, expr: types.Expr) !Value {
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
                if (global_idx_usize >= global_addrs.len) {
                    return error.InvalidGlobalIndex;
                }
                const global_addr = global_addrs[global_idx_usize];
                const global_inst = self.globals.items[global_addr];
                return global_inst.value;
            },
            else => return error.InvalidConstExpr,
        }
    }

    pub fn instantiate(self: *Store, module: types.Module, extern_vals: []const ExternVal) !*ModuleInstance {
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

        const global_extern_vals = try self.allocator.alloc(GlobalAddr, num_global_imports);
        defer self.allocator.free(global_extern_vals);
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

        const global_init_vals = try self.allocator.alloc(Value, module.globals.len);
        defer self.allocator.free(global_init_vals);

        for (module.globals, 0..) |global, i| {
            const val = try self.evalConstExpr(global_extern_vals, global.init);
            global_init_vals[i] = val;
        }

        const module_inst = try self.allocModule(self.allocator, module, extern_vals, global_init_vals);

        // Initalise element segments
        for (module.elements) |elem| {
            const offset_val = try self.evalConstExpr(global_extern_vals, elem.offset);
            const offset = switch (offset_val) {
                .i32 => |n| blk: {
                    if (n < 0) {
                        return error.InvalidElemSegmentOffset;
                    }

                    break :blk @as(usize, @as(u32, @bitCast(n)));
                },
                else => return error.InvalidElemSegmentOffset,
            };

            const table_idx_usize = @as(usize, elem.table);
            if (table_idx_usize >= module_inst.table_addrs.len) {
                return error.InvalidTableIndex;
            }

            const table_addr = module_inst.table_addrs[table_idx_usize];
            const table_inst = self.tables.items[table_addr];
            if (offset + elem.init.len > table_inst.elem.len) {
                return error.ElementSegmentOutOfBounds;
            }

            for (elem.init, 0..) |func_idx, i| {
                const func_idx_usize = @as(usize, func_idx);
                if (func_idx_usize >= module_inst.func_addrs.len) {
                    return error.InvalidFuncIndex;
                }

                const func_addr = module_inst.func_addrs[func_idx_usize];
                table_inst.elem[offset + i] = func_addr;
            }
        }

        // Initialise data segments
        for (module.data) |data| {
            const offset_val = try self.evalConstExpr(global_extern_vals, data.offset);
            const offset = switch (offset_val) {
                .i32 => |n| blk: {
                    if (n < 0) {
                        return error.InvalidDataSegmentOffset;
                    }

                    break :blk @as(usize, @as(u32, @bitCast(n)));
                },
                else => return error.InvalidDataSegmentOffset,
            };

            const mem_idx_usize = @as(usize, data.mem);
            if (mem_idx_usize >= module_inst.mem_addrs.len) {
                return error.InvalidMemIndex;
            }

            const mem_addr = module_inst.mem_addrs[mem_idx_usize];
            const mem_inst = self.mems.items[mem_addr];
            if (offset + data.init.len > mem_inst.data.len) {
                return error.DataSegmentOutOfBounds;
            }

            for (data.init, 0..) |byte, i| {
                mem_inst.data[offset + i] = byte;
            }
        }

        return module_inst;
    }
};

pub const Addr = usize;
pub const FuncAddr = Addr;
pub const TableAddr = Addr;
pub const MemAddr = Addr;
pub const GlobalAddr = Addr;

pub const ModuleInstance = struct {
    types: []types.FuncType,
    func_addrs: []FuncAddr,
    table_addrs: []TableAddr,
    mem_addrs: []MemAddr,
    global_addrs: []GlobalAddr,
    exports: []ExportInstance,

    pub fn deinit(self: *ModuleInstance, allocator: Allocator) void {
        allocator.free(self.func_addrs);
        allocator.free(self.table_addrs);
        allocator.free(self.mem_addrs);
        allocator.free(self.global_addrs);
        allocator.free(self.exports);
    }
};

const WasmFunc = struct {
    type: types.FuncType,
    module: *ModuleInstance,
    code: types.Func,
};

const HostFunc = struct {
    type: types.FuncType,
    code: *const fn ([]Value) anyerror![]Value,
};

const FuncInstance = union(enum) {
    wasm: WasmFunc,
    host: HostFunc,

    pub fn getType(self: FuncInstance) types.FuncType {
        return switch (self) {
            .wasm => |wasm_func| wasm_func.type,
            .host => |host_func| host_func.type,
        };
    }
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

const Frame = struct {
    base_ptr: usize,
    return_pc: ?usize,
};

fn FixedSizedStack(comptime T: type, Size: comptime_int) type {
    return struct {
        const Self = @This();
        items: [Size]T,
        top: usize,

        fn init() Self {
            return Self{
                .items = undefined,
                .top = 0,
            };
        }

        fn push(self: *Self, val: T) !void {
            if (self.top >= Size) {
                return error.StackOverflow;
            }

            self.items[self.top] = val;
            self.top += 1;
        }

        fn pop(self: *Self) !T {
            if (self.top == 0) {
                return error.StackUnderflow;
            }

            self.top -= 1;
            return self.items[self.top];
        }
    };
}

const ValueStack = struct {
    const Size = 16384;
    const Self = @This();
    values: [Size]u64,
    types: [Size]types.ValType,
    top: usize,

    fn init() Self {
        return Self{
            .values = undefined,
            .types = undefined,
            .top = 0,
        };
    }

    fn matching_val_type(comptime T: type) types.ValType {
        return switch (T) {
            i32 => types.ValType.i32,
            i64 => types.ValType.i64,
            f32 => types.ValType.f32,
            f64 => types.ValType.f64,
            else => unreachable,
        };
    }

    fn encode(comptime T: type, val: T) u64 {
        return switch (T) {
            i32 => @as(u64, @as(u32, @bitCast(val))),
            i64 => @as(u64, @bitCast(val)),
            f32 => @as(u64, @as(u32, @bitCast(val))),
            f64 => @as(u64, @bitCast(val)),
            else => unreachable,
        };
    }

    fn decode(comptime T: type, val: u64) T {
        return switch (T) {
            i32 => @bitCast(@as(u32, @truncate(val))),
            i64 => @bitCast(val),
            f32 => @bitCast(@as(u32, @truncate(val))),
            f64 => @bitCast(val),
            else => unreachable,
        };
    }

    fn push(self: *Self, comptime T: type, val: T) !void {
        if (self.top >= Size) {
            return error.StackOverflow;
        }

        self.values[self.top] = encode(T, val);
        self.types[self.top] = matching_val_type(T);
        self.top += 1;
    }

    fn pushValue(self: *Self, val: Value) !void {
        if (self.top >= Size) {
            return error.StackOverflow;
        }

        self.setValue(self.top, val);

        self.top += 1;
    }

    fn pop(self: *Self, comptime T: type) !T {
        if (self.top == 0) {
            return error.StackUnderflow;
        }

        self.top -= 1;

        std.debug.assert(self.types[self.top] == matching_val_type(T));

        return decode(T, self.values[self.top]);
    }

    fn popValue(self: *Self) !Value {
        if (self.top == 0) {
            return error.StackUnderflow;
        }

        self.top -= 1;

        const val_type = self.types[self.top];
        const val = self.values[self.top];

        return switch (val_type) {
            .i32 => .{ .i32 = decode(i32, val) },
            .i64 => .{ .i64 = decode(i64, val) },
            .f32 => .{ .f32 = decode(f32, val) },
            .f64 => .{ .f64 = decode(f64, val) },
        };
    }

    fn getValue(self: *const Self, idx: usize) Value {
        const val = self.values[idx];
        return switch (self.types[idx]) {
            .i32 => .{ .i32 = decode(i32, val) },
            .i64 => .{ .i64 = decode(i64, val) },
            .f32 => .{ .f32 = decode(f32, val) },
            .f64 => .{ .f64 = decode(f64, val) },
        };
    }

    fn setValue(self: *Self, idx: usize, val: Value) void {
        switch (val) {
            .i32 => |v| {
                self.values[idx] = encode(i32, v);
                self.types[idx] = types.ValType.i32;
            },
            .i64 => |v| {
                self.values[idx] = encode(i64, v);
                self.types[idx] = types.ValType.i64;
            },
            .f32 => |v| {
                self.values[idx] = encode(f32, v);
                self.types[idx] = types.ValType.f32;
            },
            .f64 => |v| {
                self.values[idx] = encode(f64, v);
                self.types[idx] = types.ValType.f64;
            },
        }
    }
};

pub const Runtime = struct {
    allocator: Allocator,
    store: Store,
    bytecode: Bytecode,
    stack: ValueStack,
    call_stack: FixedSizedStack(Frame, 16384),
    module: *ModuleInstance,
    start_func_addr: ?FuncAddr,

    pub fn init(allocator: Allocator, store: Store, module: *ModuleInstance, start_func_addr: ?FuncAddr) !Runtime {
        var lowering = try BytecodeLowering.init(allocator, &store);
        defer lowering.deinit();

        return Runtime{
            .allocator = allocator,
            .store = store,
            .bytecode = try lowering.lower(),
            .stack = .init(),
            .call_stack = .init(),
            .start_func_addr = start_func_addr,
            .module = module,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.bytecode.deinit(self.allocator);
        self.module.deinit(self.allocator);
        self.allocator.destroy(self.module);
        self.store.deinit();
    }

    pub fn invokeStartFunc(self: *Runtime) !void {
        if (self.start_func_addr) |addr| {
            _ = try self.invokeFunc(addr);
        }
    }

    pub fn invokeExportedFunc(self: *Runtime, export_name: types.Name) ![]Value {
        for (self.module.exports) |exp| {
            if (std.mem.eql(u8, exp.name, export_name)) {
                return switch (exp.value) {
                    .func => |func_addr| try self.invokeFunc(func_addr),
                    else => error.ExportNotAFunction,
                };
            }
        }

        return error.ExportNotFound;
    }

    pub fn invokeFunc(self: *Runtime, func_addr: FuncAddr) ![]Value {
        const func_inst = self.store.funcs.items[func_addr];
        const func_type = func_inst.getType();

        if (self.stack.top < func_type.params.len) {
            return error.InvalidArgumentCount;
        }

        const args_start = self.stack.top - func_type.params.len;

        for (func_type.params, 0..) |param_type, i| {
            if (self.stack.types[args_start + i] != param_type) {
                return error.InvalidArgumentType;
            }
        }

        switch (func_inst) {
            .wasm => |*wasm_func| {
                const base_ptr = args_start;

                // Locals are initialized by bytecode instructions emitted during lowering
                // Parameters are already on the stack at base_ptr
                try self.call_stack.push(Frame{
                    .base_ptr = base_ptr,
                    .return_pc = null,
                });

                defer self.call_stack.top -= 1;

                if (self.bytecode.functions[func_addr]) |entry_pc| {
                    try self.execute(entry_pc);
                    var result: []Value = &[_]Value{};
                    if (wasm_func.type.results.len > 0) {
                        const result_count = wasm_func.type.results.len;
                        const result_start = self.stack.top - result_count;
                        result = try self.allocator.alloc(Value, result_count);
                        for (0..result_count) |i| {
                            result[i] = self.stack.getValue(result_start + i);
                        }
                    }

                    self.stack.top = base_ptr;

                    return result;
                } else {
                    return error.FunctionNotFound;
                }
            },
            .host => |host_func| {
                const arg_count = func_type.params.len;
                const args = try self.allocator.alloc(Value, arg_count);
                defer self.allocator.free(args);
                for (0..arg_count) |i| {
                    args[i] = self.stack.getValue(args_start + i);
                }
                const res = try host_func.code(args);
                self.stack.top = args_start;
                return res;
            },
        }
    }

    inline fn push(self: *Runtime, comptime T: type, val: T) !void {
        try self.stack.push(T, val);
    }

    inline fn pushValue(self: *Runtime, val: Value) !void {
        try self.stack.pushValue(val);
    }

    inline fn pushBool(self: *Runtime, b: bool) !void {
        try self.push(i32, if (b) 1 else 0);
    }

    inline fn pop(self: *Runtime, comptime T: type) T {
        return self.stack.pop(T) catch unreachable;
    }

    inline fn popValue(self: *Runtime) Value {
        return self.stack.popValue() catch unreachable;
    }

    fn pop2Values(self: *Runtime, comptime T: type) [2]T {
        const rhs = ValueStack.decode(T, self.stack.values[self.stack.top - 1]);
        const lhs = ValueStack.decode(T, self.stack.values[self.stack.top - 2]);
        self.stack.top -= 2;
        return .{ lhs, rhs };
    }

    fn peek(self: *Runtime) !Value {
        if (self.stack.top > 0) {
            return self.stack.getValue(self.stack.top - 1);
        } else {
            return error.ValueStackUnderflow;
        }
    }

    fn getCurrentFrame(self: *Runtime) !*Frame {
        if (self.call_stack.top == 0) {
            return error.CallStackUnderflow;
        }

        return &self.call_stack.items[self.call_stack.top - 1];
    }

    fn getLocal(self: *Runtime, idx: usize) !Value {
        const frame = try self.getCurrentFrame();
        return self.stack.getValue(frame.base_ptr + idx);
    }

    fn setLocal(self: *Runtime, idx: usize, val: Value) !void {
        const frame = try self.getCurrentFrame();
        self.stack.setValue(frame.base_ptr + idx, val);
    }

    fn superConstReturn(self: *Runtime, comptime T: type, imm: T, pc: *usize) !bool {
        try self.push(T, imm);
        const frame = try self.getCurrentFrame();

        if (frame.return_pc) |return_pc| {
            const len = self.stack.top;
            const results_start = len - 1;
            @memmove(self.stack.values[frame.base_ptr .. frame.base_ptr + 1], self.stack.values[results_start..len]);
            self.stack.top = frame.base_ptr + 1;
            pc.* = return_pc;
            self.call_stack.top -= 1;
            return false;
        }

        return true;
    }

    fn intDiv(comptime T: type, lhs: T, rhs: T) !T {
        if (rhs == 0) {
            return error.IntegerDivideByZero;
        }

        // Spec: undefined when result = 2^(N-1), i.e. minInt / -1
        // since it is not representable in the type.
        if (@typeInfo(T).int.signedness == .signed and lhs == std.math.minInt(T) and rhs == -1) {
            return error.IntegerOverflow;
        }

        return @divTrunc(lhs, rhs);
    }

    fn intRem(comptime T: type, lhs: T, rhs: T) !T {
        if (rhs == 0) {
            return error.IntegerDivideByZero;
        }

        // Zig's @rem panics on minInt % -1 because the intermediate
        // division overflows, but the mathematical result is 0.
        if (@typeInfo(T).int.signedness == .signed and lhs == std.math.minInt(T) and rhs == -1) {
            return 0;
        }

        return @rem(lhs, rhs);
    }

    fn intShl(comptime T: type, lhs: T, rhs: T) T {
        const UT = std.meta.Int(.unsigned, @bitSizeOf(T));
        const shift: std.math.Log2Int(UT) = @truncate(@as(UT, @bitCast(rhs)));
        return lhs << shift;
    }

    fn intShr(comptime T: type, lhs: T, rhs: T) T {
        const UT = std.meta.Int(.unsigned, @bitSizeOf(T));
        const shift: std.math.Log2Int(UT) = @truncate(@as(UT, @bitCast(rhs)));
        return lhs >> shift;
    }

    fn floatCopysign(comptime T: type, mag: T, sign: T) T {
        const bits = @bitSizeOf(T);
        const IT = std.meta.Int(.unsigned, bits);
        const sign_mask: IT = 1 << (bits - 1);
        const mag_bits: IT = @bitCast(mag);
        const sign_bits: IT = @bitCast(sign);
        return @bitCast((mag_bits & ~sign_mask) | (sign_bits & sign_mask));
    }

    fn truncFloat(comptime TI: type, comptime TF: type, val: TF) !TI {
        if (std.math.isNan(val) or std.math.isInf(val)) return error.InvalidConversionToInteger;
        return @intFromFloat(val);
    }

    fn intExtend(comptime Dst: type, comptime Src: type, val: anytype) Dst {
        const Val = @TypeOf(val);
        const UVal = std.meta.Int(.unsigned, @bitSizeOf(Val));
        const USrc = std.meta.Int(.unsigned, @bitSizeOf(Src));
        const truncated: USrc = @truncate(@as(UVal, @bitCast(val)));
        return @intCast(@as(Src, @bitCast(truncated)));
    }

    fn memLoad(self: *Runtime, comptime T: type, memarg: MemArg) !T {
        const i = self.pop(i32);
        const N = @divExact(@typeInfo(T).int.bits, 8);
        const effective_addr = @as(usize, @intCast(i)) + @as(usize, memarg.offset);

        if (effective_addr + N >= memarg.mem.data.len) {
            return error.MemoryAccessOutOfBounds;
        }

        const bytes = memarg.mem.data[effective_addr .. effective_addr + N];
        return std.mem.readInt(T, bytes[0..N], .little);
    }

    fn memStore(self: *Runtime, comptime T: type, memarg: MemArg, val: T) !void {
        const i = self.pop(i32);
        const N = @divExact(@typeInfo(T).int.bits, 8);
        const effective_addr = @as(usize, @intCast(i)) + @as(usize, memarg.offset);

        if (effective_addr + N >= memarg.mem.data.len) {
            return error.MemoryAccessOutOfBounds;
        }

        const bytes = memarg.mem.data[effective_addr .. effective_addr + N];
        std.mem.writeInt(T, bytes[0..N], val, .little);
    }

    pub fn execute(self: *Runtime, start_pc: usize) !void {
        var pc = start_pc;

        while (pc < self.bytecode.instrs.len) {
            const instr = self.bytecode.instrs[pc];
            pc += 1;

            switch (instr) {
                .@"unreachable" => {
                    return error.Unreachable;
                },
                .nop => {},
                .sentinel => unreachable,
                .br => |target_pc| {
                    pc = target_pc;
                },
                .br_if => |target_pc| {
                    const condition = self.pop(i32);

                    if (condition != 0) {
                        pc = target_pc;
                    }
                },
                .br_table => |table| {
                    const i: usize = @intCast(self.pop(i32));

                    if (i < table.label_pcs.len) {
                        pc = table.label_pcs[i];
                    } else {
                        pc = table.default_pc;
                    }
                },
                .@"return" => |arity| {
                    const frame = try self.getCurrentFrame();

                    if (frame.return_pc) |return_pc| {
                        // Keep return values, drop locals for this frame
                        if (arity == 0) {
                            self.stack.top = frame.base_ptr;
                        } else {
                            const len = self.stack.top;
                            const results_start = len - arity;
                            @memmove(self.stack.values[frame.base_ptr .. frame.base_ptr + arity], self.stack.values[results_start..len]);
                            self.stack.top = frame.base_ptr + arity;
                        }

                        pc = return_pc;
                        self.call_stack.top -= 1;
                    } else {
                        return; // end execution
                    }
                },
                .call => |call| {
                    try self.call_stack.push(Frame{
                        .base_ptr = self.stack.top - call.arguments,
                        .return_pc = pc,
                    });

                    pc = call.entry_pc;
                },
                .call_host => |host_func| {
                    const arg_count = host_func.type.params.len;
                    const args = try self.allocator.alloc(Value, arg_count);
                    defer self.allocator.free(args);
                    const args_start = self.stack.top - arg_count;
                    for (0..arg_count) |i| {
                        args[i] = self.stack.getValue(args_start + i);
                    }
                    self.stack.top -= arg_count;
                    const result = try host_func.code(args);
                    for (result) |val| {
                        try self.pushValue(val);
                    }
                },
                .call_indirect => |call| {
                    const i: usize = @intCast(self.pop(i32));

                    if (i >= call.table.elem.len) {
                        return error.InvalidIndirectCallIndex;
                    }

                    if (call.table.elem[i]) |func_addr| {
                        const func_inst = self.store.funcs.items[func_addr];

                        if (!func_inst.getType().eql(call.func_type)) {
                            return error.IndirectCallTypeMismatch;
                        }

                        if (self.bytecode.functions[func_addr]) |entry_pc| {
                            try self.call_stack.push(Frame{
                                .base_ptr = self.stack.top - call.func_type.params.len,
                                .return_pc = pc,
                            });

                            pc = entry_pc;
                        } else {
                            return error.FunctionNotFound;
                        }
                    } else {
                        return error.UninitializedTableElement;
                    }
                },
                .super_i32_eqz_br_if => |target_pc| {
                    const condition = self.pop(i32);
                    if (condition == 0) {
                        pc = target_pc;
                    }
                },
                .super_i32_eq_br_if => |target_pc| {
                    const args = self.pop2Values(i32);
                    if (args[0] == args[1]) {
                        pc = target_pc;
                    }
                },
                .super_local_get_local_get => |arg| {
                    const lhs = try self.getLocal(arg.lhs);
                    const rhs = try self.getLocal(arg.rhs);
                    try self.stack.pushValue(lhs);
                    try self.stack.pushValue(rhs);
                },
                .super_local_get_local_get_i32_add => |arg| {
                    const lhs = (try self.getLocal(arg.lhs)).i32;
                    const rhs = (try self.getLocal(arg.rhs)).i32;
                    try self.push(i32, lhs +% rhs);
                },
                .super_local_get_local_get_i32_mul => |arg| {
                    const lhs = (try self.getLocal(arg.lhs)).i32;
                    const rhs = (try self.getLocal(arg.rhs)).i32;
                    try self.push(i32, lhs *% rhs);
                },
                .super_local_get_i32_const_i32_add => |arg| {
                    const lhs = (try self.getLocal(arg.local)).i32;
                    try self.push(i32, lhs +% arg.imm);
                },
                .super_local_add_i32_const_set => |arg| {
                    const lhs = (try self.getLocal(arg.local)).i32;
                    try self.setLocal(arg.local, .{ .i32 = lhs +% arg.imm });
                },
                .super_local_sub_i32_const_set => |arg| {
                    const lhs = (try self.getLocal(arg.local)).i32;
                    try self.setLocal(arg.local, .{ .i32 = lhs -% arg.imm });
                },
                .super_local_get_i32_const_i32_eq_br_if => |arg| {
                    const lhs = (try self.getLocal(arg.local)).i32;
                    if (lhs == arg.imm) {
                        pc = arg.target;
                    }
                },
                .super_local_get_i32_const_i32_ge_u_br_if => |arg| {
                    const lhs: u32 = @bitCast((try self.getLocal(arg.local)).i32);
                    const rhs: u32 = @bitCast(arg.imm);
                    if (lhs >= rhs) {
                        pc = arg.target;
                    }
                },
                .super_local_get_i32_const_i32_le_u_br_if => |arg| {
                    const lhs: u32 = @bitCast((try self.getLocal(arg.local)).i32);
                    const rhs: u32 = @bitCast(arg.imm);
                    if (lhs <= rhs) {
                        pc = arg.target;
                    }
                },
                .super_i32_const_local_set => |arg| {
                    try self.setLocal(arg.local, .{ .i32 = arg.imm });
                },
                .super_i64_const_local_set => |arg| {
                    try self.setLocal(arg.local, .{ .i64 = arg.imm });
                },
                .super_f32_const_local_set => |arg| {
                    try self.setLocal(arg.local, .{ .f32 = arg.imm });
                },
                .super_f64_const_local_set => |arg| {
                    try self.setLocal(arg.local, .{ .f64 = arg.imm });
                },
                .super_i32_const_return => |imm| {
                    if (try self.superConstReturn(i32, imm, &pc)) return;
                },
                .super_i64_const_return => |imm| {
                    if (try self.superConstReturn(i64, imm, &pc)) return;
                },
                .super_f32_const_return => |imm| {
                    if (try self.superConstReturn(f32, imm, &pc)) return;
                },
                .super_f64_const_return => |imm| {
                    if (try self.superConstReturn(f64, imm, &pc)) return;
                },
                .drop => {
                    self.stack.top -= 1;
                },
                .select => {
                    const condition = self.pop(i32);
                    const a = try self.stack.popValue();
                    const b = try self.stack.popValue();
                    try self.stack.pushValue(if (condition != 0) a else b);
                },
                .local_get => |local_idx| {
                    const val = try self.getLocal(local_idx);
                    try self.stack.pushValue(val);
                },
                .local_set => |local_idx| {
                    const val = try self.stack.popValue();
                    try self.setLocal(local_idx, val);
                },
                .local_tee => |local_idx| {
                    const val = try self.peek();
                    try self.setLocal(local_idx, val);
                },
                .global_get => |global_inst| {
                    try self.stack.pushValue(global_inst.value);
                },
                .global_set => |global_inst| {
                    const val = self.popValue();
                    std.debug.assert(global_inst.mutable);
                    global_inst.value = val;
                },
                .i32_load => |memarg| {
                    const val = try self.memLoad(i32, memarg);
                    try self.push(i32, val);
                },
                .i64_load => |memarg| {
                    const val = try self.memLoad(i64, memarg);
                    try self.push(i64, val);
                },
                .i32_store => |memarg| {
                    const val = self.pop(i32);
                    try self.memStore(i32, memarg, val);
                },
                .i64_store => |memarg| {
                    const val = self.pop(i64);
                    try self.memStore(i64, memarg, val);
                },
                .i32_const => |n| {
                    try self.push(i32, n);
                },
                .i64_const => |n| {
                    try self.push(i64, n);
                },
                .f32_const => |x| {
                    try self.push(f32, x);
                },
                .f64_const => |x| {
                    try self.push(f64, x);
                },
                .i32_eqz => {
                    const val = self.pop(i32);
                    try self.pushBool(val == 0);
                },
                .i32_eq => {
                    const args = self.pop2Values(i32);
                    try self.pushBool(args[0] == args[1]);
                },
                .i32_ne => {
                    const args = self.pop2Values(i32);
                    try self.pushBool(args[0] != args[1]);
                },
                .i32_lt_s => {
                    const args = self.pop2Values(i32);
                    try self.pushBool(args[0] < args[1]);
                },
                .i32_lt_u => {
                    const args = self.pop2Values(i32);
                    const lhs: u32 = @bitCast(args[0]);
                    const rhs: u32 = @bitCast(args[1]);
                    try self.pushBool(lhs < rhs);
                },
                .i32_gt_s => {
                    const args = self.pop2Values(i32);
                    try self.pushBool(args[0] > args[1]);
                },
                .i32_gt_u => {
                    const args = self.pop2Values(i32);
                    const lhs: u32 = @bitCast(args[0]);
                    const rhs: u32 = @bitCast(args[1]);
                    try self.pushBool(lhs > rhs);
                },
                .i32_le_s => {
                    const args = self.pop2Values(i32);
                    try self.pushBool(args[0] <= args[1]);
                },
                .i32_le_u => {
                    const args = self.pop2Values(i32);
                    const lhs: u32 = @bitCast(args[0]);
                    const rhs: u32 = @bitCast(args[1]);
                    try self.pushBool(lhs <= rhs);
                },
                .i32_ge_s => {
                    const args = self.pop2Values(i32);
                    try self.pushBool(args[0] >= args[1]);
                },
                .i32_ge_u => {
                    const args = self.pop2Values(i32);
                    const lhs: u32 = @bitCast(args[0]);
                    const rhs: u32 = @bitCast(args[1]);
                    try self.pushBool(lhs >= rhs);
                },
                .i32_clz => {
                    const val = self.pop(i32);
                    try self.push(i32, @clz(val));
                },
                .i32_ctz => {
                    const val = self.pop(i32);
                    try self.push(i32, @ctz(val));
                },
                .i32_popcnt => {
                    const val = self.pop(i32);
                    try self.push(i32, @popCount(val));
                },
                .i32_add => {
                    const args = self.pop2Values(i32);
                    try self.push(i32, args[0] +% args[1]);
                },
                .i32_sub => {
                    const args = self.pop2Values(i32);
                    try self.push(i32, args[0] -% args[1]);
                },
                .i32_mul => {
                    const args = self.pop2Values(i32);
                    try self.push(i32, args[0] *% args[1]);
                },
                .i32_div_s => {
                    const args = self.pop2Values(i32);
                    try self.push(i32, try intDiv(i32, args[0], args[1]));
                },
                .i32_div_u => {
                    const args = self.pop2Values(i32);
                    const lhs: u32 = @bitCast(args[0]);
                    const rhs: u32 = @bitCast(args[1]);
                    try self.push(i32, @bitCast(try intDiv(u32, lhs, rhs)));
                },
                .i32_rem_s => {
                    const args = self.pop2Values(i32);
                    try self.push(i32, try intRem(i32, args[0], args[1]));
                },
                .i32_rem_u => {
                    const args = self.pop2Values(i32);
                    const lhs: u32 = @bitCast(args[0]);
                    const rhs: u32 = @bitCast(args[1]);
                    try self.push(i32, @bitCast(try intRem(u32, lhs, rhs)));
                },
                .i32_and => {
                    const args = self.pop2Values(i32);
                    try self.push(i32, args[0] & args[1]);
                },
                .i32_or => {
                    const args = self.pop2Values(i32);
                    try self.push(i32, args[0] | args[1]);
                },
                .i32_xor => {
                    const args = self.pop2Values(i32);
                    try self.push(i32, args[0] ^ args[1]);
                },
                .i32_shl => {
                    const args = self.pop2Values(i32);
                    try self.push(i32, intShl(i32, args[0], args[1]));
                },
                .i32_shr_s => {
                    const args = self.pop2Values(i32);
                    try self.push(i32, intShr(i32, args[0], args[1]));
                },
                .i32_shr_u => {
                    const args = self.pop2Values(i32);
                    try self.push(i32, @bitCast(intShr(u32, @as(u32, @bitCast(args[0])), @as(u32, @bitCast(args[1])))));
                },
                .i32_rotl => {
                    const args = self.pop2Values(i32);
                    const val: u32 = @bitCast(args[0]);
                    const shift = @as(u32, @bitCast(args[1])) & 31;
                    try self.push(i32, @bitCast(std.math.rotl(u32, val, shift)));
                },
                .i32_rotr => {
                    const args = self.pop2Values(i32);
                    const val: u32 = @bitCast(args[0]);
                    const shift = @as(u32, @bitCast(args[1])) & 31;
                    try self.push(i32, @bitCast(std.math.rotr(u32, val, shift)));
                },
                .i32_wrap_i64 => {
                    const val = self.pop(i64);
                    try self.push(i32, @truncate(val));
                },
                .f32_load => |memarg| {
                    const bits = try self.memLoad(u32, memarg);
                    try self.push(f32, @bitCast(bits));
                },
                .f64_load => |memarg| {
                    const bits = try self.memLoad(u64, memarg);
                    try self.push(f64, @bitCast(bits));
                },
                .i32_load8_s => |memarg| {
                    const val = try self.memLoad(i8, memarg);
                    try self.push(i32, @intCast(val));
                },
                .i32_load8_u => |memarg| {
                    const val = try self.memLoad(u8, memarg);
                    try self.push(i32, @intCast(val));
                },
                .i32_load16_s => |memarg| {
                    const val = try self.memLoad(i16, memarg);
                    try self.push(i32, @intCast(val));
                },
                .i32_load16_u => |memarg| {
                    const val = try self.memLoad(u16, memarg);
                    try self.push(i32, @intCast(val));
                },
                .i64_load8_s => |memarg| {
                    const val = try self.memLoad(i8, memarg);
                    try self.push(i64, @intCast(val));
                },
                .i64_load8_u => |memarg| {
                    const val = try self.memLoad(u8, memarg);
                    try self.push(i64, @intCast(val));
                },
                .i64_load16_s => |memarg| {
                    const val = try self.memLoad(i16, memarg);
                    try self.push(i64, @intCast(val));
                },
                .i64_load16_u => |memarg| {
                    const val = try self.memLoad(u16, memarg);
                    try self.push(i64, @intCast(val));
                },
                .i64_load32_s => |memarg| {
                    const val = try self.memLoad(i32, memarg);
                    try self.push(i64, @intCast(val));
                },
                .i64_load32_u => |memarg| {
                    const val = try self.memLoad(u32, memarg);
                    try self.push(i64, @intCast(val));
                },
                .f32_store => |memarg| {
                    const val = self.pop(f32);
                    try self.memStore(u32, memarg, @bitCast(val));
                },
                .f64_store => |memarg| {
                    const val = self.pop(f64);
                    try self.memStore(u64, memarg, @bitCast(val));
                },
                .i32_store8 => |memarg| {
                    const val = self.pop(i32);
                    try self.memStore(u8, memarg, @truncate(@as(u32, @bitCast(val))));
                },
                .i32_store16 => |memarg| {
                    const val = self.pop(i32);
                    try self.memStore(u16, memarg, @truncate(@as(u32, @bitCast(val))));
                },
                .i64_store8 => |memarg| {
                    const val = self.pop(i64);
                    try self.memStore(u8, memarg, @truncate(@as(u64, @bitCast(val))));
                },
                .i64_store16 => |memarg| {
                    const val = self.pop(i64);
                    try self.memStore(u16, memarg, @truncate(@as(u64, @bitCast(val))));
                },
                .i64_store32 => |memarg| {
                    const val = self.pop(i64);
                    try self.memStore(u32, memarg, @truncate(@as(u64, @bitCast(val))));
                },
                .memory_size => |mem_inst| {
                    const size: i32 = @intCast(mem_inst.data.len / page_size);
                    try self.push(i32, size);
                },
                .memory_grow => |mem_inst| {
                    const n: u32 = @bitCast(self.pop(i32));
                    const old_pages: u32 = @intCast(mem_inst.data.len / page_size);
                    const new_pages: u64 = @as(u64, old_pages) + @as(u64, n);
                    var result: i32 = -1;

                    grow: {
                        if (mem_inst.max) |max| {
                            if (new_pages > max) {
                                break :grow;
                            }
                        }

                        const new_byte_size: usize = @intCast(new_pages * page_size);
                        const old_len = mem_inst.data.len;
                        const new_data = self.allocator.realloc(mem_inst.data, new_byte_size) catch break :grow;
                        @memset(new_data[old_len..], 0);
                        mem_inst.data = new_data;
                        result = @bitCast(old_pages);
                    }

                    try self.push(i32, result);
                },
                .i64_eqz => {
                    const val = self.pop(i64);
                    try self.pushBool(val == 0);
                },
                .i64_eq => {
                    const args = self.pop2Values(i64);
                    try self.pushBool(args[0] == args[1]);
                },
                .i64_ne => {
                    const args = self.pop2Values(i64);
                    try self.pushBool(args[0] != args[1]);
                },
                .i64_lt_s => {
                    const args = self.pop2Values(i64);
                    try self.pushBool(args[0] < args[1]);
                },
                .i64_lt_u => {
                    const args = self.pop2Values(i64);
                    const lhs: u64 = @bitCast(args[0]);
                    const rhs: u64 = @bitCast(args[1]);
                    try self.pushBool(lhs < rhs);
                },
                .i64_gt_s => {
                    const args = self.pop2Values(i64);
                    try self.pushBool(args[0] > args[1]);
                },
                .i64_gt_u => {
                    const args = self.pop2Values(i64);
                    const lhs: u64 = @bitCast(args[0]);
                    const rhs: u64 = @bitCast(args[1]);
                    try self.pushBool(lhs > rhs);
                },
                .i64_le_s => {
                    const args = self.pop2Values(i64);
                    try self.pushBool(args[0] <= args[1]);
                },
                .i64_le_u => {
                    const args = self.pop2Values(i64);
                    const lhs: u64 = @bitCast(args[0]);
                    const rhs: u64 = @bitCast(args[1]);
                    try self.pushBool(lhs <= rhs);
                },
                .i64_ge_s => {
                    const args = self.pop2Values(i64);
                    try self.pushBool(args[0] >= args[1]);
                },
                .i64_ge_u => {
                    const args = self.pop2Values(i64);
                    const lhs: u64 = @bitCast(args[0]);
                    const rhs: u64 = @bitCast(args[1]);
                    try self.pushBool(lhs >= rhs);
                },
                .f32_eq => {
                    const args = self.pop2Values(f32);
                    try self.pushBool(args[0] == args[1]);
                },
                .f32_ne => {
                    const args = self.pop2Values(f32);
                    try self.pushBool(args[0] != args[1]);
                },
                .f32_lt => {
                    const args = self.pop2Values(f32);
                    try self.pushBool(args[0] < args[1]);
                },
                .f32_gt => {
                    const args = self.pop2Values(f32);
                    try self.pushBool(args[0] > args[1]);
                },
                .f32_le => {
                    const args = self.pop2Values(f32);
                    try self.pushBool(args[0] <= args[1]);
                },
                .f32_ge => {
                    const args = self.pop2Values(f32);
                    try self.pushBool(args[0] >= args[1]);
                },
                .f64_eq => {
                    const args = self.pop2Values(f64);
                    try self.pushBool(args[0] == args[1]);
                },
                .f64_ne => {
                    const args = self.pop2Values(f64);
                    try self.pushBool(args[0] != args[1]);
                },
                .f64_lt => {
                    const args = self.pop2Values(f64);
                    try self.pushBool(args[0] < args[1]);
                },
                .f64_gt => {
                    const args = self.pop2Values(f64);
                    try self.pushBool(args[0] > args[1]);
                },
                .f64_le => {
                    const args = self.pop2Values(f64);
                    try self.pushBool(args[0] <= args[1]);
                },
                .f64_ge => {
                    const args = self.pop2Values(f64);
                    try self.pushBool(args[0] >= args[1]);
                },
                .i64_clz => {
                    const val = self.pop(i64);
                    try self.push(i64, @clz(val));
                },
                .i64_ctz => {
                    const val = self.pop(i64);
                    try self.push(i64, @ctz(val));
                },
                .i64_popcnt => {
                    const val = self.pop(i64);
                    try self.push(i64, @popCount(val));
                },
                .i64_add => {
                    const args = self.pop2Values(i64);
                    try self.push(i64, args[0] +% args[1]);
                },
                .i64_sub => {
                    const args = self.pop2Values(i64);
                    try self.push(i64, args[0] -% args[1]);
                },
                .i64_mul => {
                    const args = self.pop2Values(i64);
                    try self.push(i64, args[0] *% args[1]);
                },
                .i64_div_s => {
                    const args = self.pop2Values(i64);
                    try self.push(i64, try intDiv(i64, args[0], args[1]));
                },
                .i64_div_u => {
                    const args = self.pop2Values(i64);
                    const lhs: u64 = @bitCast(args[0]);
                    const rhs: u64 = @bitCast(args[1]);
                    try self.push(i64, @bitCast(try intDiv(u64, lhs, rhs)));
                },
                .i64_rem_s => {
                    const args = self.pop2Values(i64);
                    try self.push(i64, try intRem(i64, args[0], args[1]));
                },
                .i64_rem_u => {
                    const args = self.pop2Values(i64);
                    const lhs: u64 = @bitCast(args[0]);
                    const rhs: u64 = @bitCast(args[1]);
                    try self.push(i64, @bitCast(try intRem(u64, lhs, rhs)));
                },
                .i64_and => {
                    const args = self.pop2Values(i64);
                    try self.push(i64, args[0] & args[1]);
                },
                .i64_or => {
                    const args = self.pop2Values(i64);
                    try self.push(i64, args[0] | args[1]);
                },
                .i64_xor => {
                    const args = self.pop2Values(i64);
                    try self.push(i64, args[0] ^ args[1]);
                },
                .i64_shl => {
                    const args = self.pop2Values(i64);
                    try self.push(i64, intShl(i64, args[0], args[1]));
                },
                .i64_shr_s => {
                    const args = self.pop2Values(i64);
                    try self.push(i64, intShr(i64, args[0], args[1]));
                },
                .i64_shr_u => {
                    const args = self.pop2Values(i64);
                    try self.push(i64, @bitCast(intShr(u64, @as(u64, @bitCast(args[0])), @as(u64, @bitCast(args[1])))));
                },
                .i64_rotl => {
                    const args = self.pop2Values(i64);
                    const val: u64 = @bitCast(args[0]);
                    const shift = @as(u64, @bitCast(args[1])) & 63;
                    try self.push(i64, @bitCast(std.math.rotl(u64, val, shift)));
                },
                .i64_rotr => {
                    const args = self.pop2Values(i64);
                    const val: u64 = @bitCast(args[0]);
                    const shift = @as(u64, @bitCast(args[1])) & 63;
                    try self.push(i64, @bitCast(std.math.rotr(u64, val, shift)));
                },
                .f32_abs => {
                    const val = self.pop(f32);
                    try self.push(f32, @abs(val));
                },
                .f32_neg => {
                    const val = self.pop(f32);
                    try self.push(f32, -val);
                },
                .f32_ceil => {
                    const val = self.pop(f32);
                    try self.push(f32, @ceil(val));
                },
                .f32_floor => {
                    const val = self.pop(f32);
                    try self.push(f32, @floor(val));
                },
                .f32_trunc => {
                    const val = self.pop(f32);
                    try self.push(f32, @trunc(val));
                },
                .f32_nearest => {
                    const val = self.pop(f32);
                    try self.push(f32, @round(val));
                },
                .f32_sqrt => {
                    const val = self.pop(f32);
                    try self.push(f32, @sqrt(val));
                },
                .f32_add => {
                    const args = self.pop2Values(f32);
                    try self.push(f32, args[0] + args[1]);
                },
                .f32_sub => {
                    const args = self.pop2Values(f32);
                    try self.push(f32, args[0] - args[1]);
                },
                .f32_mul => {
                    const args = self.pop2Values(f32);
                    try self.push(f32, args[0] * args[1]);
                },
                .f32_div => {
                    const args = self.pop2Values(f32);
                    try self.push(f32, args[0] / args[1]);
                },
                .f32_min => {
                    const args = self.pop2Values(f32);
                    try self.push(f32, @min(args[0], args[1]));
                },
                .f32_max => {
                    const args = self.pop2Values(f32);
                    try self.push(f32, @max(args[0], args[1]));
                },
                .f32_copysign => {
                    const args = self.pop2Values(f32);
                    try self.push(f32, floatCopysign(f32, args[0], args[1]));
                },
                .f64_abs => {
                    const val = self.pop(f64);
                    try self.push(f64, @abs(val));
                },
                .f64_neg => {
                    const val = self.pop(f64);
                    try self.push(f64, -val);
                },
                .f64_ceil => {
                    const val = self.pop(f64);
                    try self.push(f64, @ceil(val));
                },
                .f64_floor => {
                    const val = self.pop(f64);
                    try self.push(f64, @floor(val));
                },
                .f64_trunc => {
                    const val = self.pop(f64);
                    try self.push(f64, @trunc(val));
                },
                .f64_nearest => {
                    const val = self.pop(f64);
                    try self.push(f64, @round(val));
                },
                .f64_sqrt => {
                    const val = self.pop(f64);
                    try self.push(f64, @sqrt(val));
                },
                .f64_add => {
                    const args = self.pop2Values(f64);
                    try self.push(f64, args[0] + args[1]);
                },
                .f64_sub => {
                    const args = self.pop2Values(f64);
                    try self.push(f64, args[0] - args[1]);
                },
                .f64_mul => {
                    const args = self.pop2Values(f64);
                    try self.push(f64, args[0] * args[1]);
                },
                .f64_div => {
                    const args = self.pop2Values(f64);
                    try self.push(f64, args[0] / args[1]);
                },
                .f64_min => {
                    const args = self.pop2Values(f64);
                    try self.push(f64, @min(args[0], args[1]));
                },
                .f64_max => {
                    const args = self.pop2Values(f64);
                    try self.push(f64, @max(args[0], args[1]));
                },
                .f64_copysign => {
                    const args = self.pop2Values(f64);
                    try self.push(f64, floatCopysign(f64, args[0], args[1]));
                },
                .i32_trunc_f32_s => {
                    try self.push(i32, try truncFloat(i32, f32, self.pop(f32)));
                },
                .i32_trunc_f32_u => {
                    try self.push(i32, @bitCast(try truncFloat(u32, f32, self.pop(f32))));
                },
                .i32_trunc_f64_s => {
                    try self.push(i32, try truncFloat(i32, f64, self.pop(f64)));
                },
                .i32_trunc_f64_u => {
                    try self.push(i32, @bitCast(try truncFloat(u32, f64, self.pop(f64))));
                },
                .i64_extend_i32_s => {
                    try self.push(i64, intExtend(i64, i32, self.pop(i32)));
                },
                .i64_extend_i32_u => {
                    try self.push(i64, intExtend(i64, u32, self.pop(i32)));
                },
                .i64_trunc_f32_s => {
                    try self.push(i64, try truncFloat(i64, f32, self.pop(f32)));
                },
                .i64_trunc_f32_u => {
                    try self.push(i64, @bitCast(try truncFloat(u64, f32, self.pop(f32))));
                },
                .i64_trunc_f64_s => {
                    try self.push(i64, try truncFloat(i64, f64, self.pop(f64)));
                },
                .i64_trunc_f64_u => {
                    try self.push(i64, @bitCast(try truncFloat(u64, f64, self.pop(f64))));
                },
                .f32_convert_i32_s => {
                    const v = self.pop(i32);
                    try self.push(f32, @floatFromInt(v));
                },
                .f32_convert_i32_u => {
                    const v: u32 = @bitCast(self.pop(i32));
                    try self.push(f32, @floatFromInt(v));
                },
                .f32_convert_i64_s => {
                    const v = self.pop(i64);
                    try self.push(f32, @floatFromInt(v));
                },
                .f32_convert_i64_u => {
                    const v: u64 = @bitCast(self.pop(i64));
                    try self.push(f32, @floatFromInt(v));
                },
                .f64_convert_i32_s => {
                    const v = self.pop(i32);
                    try self.push(f64, @floatFromInt(v));
                },
                .f64_convert_i32_u => {
                    const v: u32 = @bitCast(self.pop(i32));
                    try self.push(f64, @floatFromInt(v));
                },
                .f64_convert_i64_s => {
                    const v = self.pop(i64);
                    try self.push(f64, @floatFromInt(v));
                },
                .f64_convert_i64_u => {
                    const v: u64 = @bitCast(self.pop(i64));
                    try self.push(f64, @floatFromInt(v));
                },
                .f32_demote_f64 => {
                    const v = self.pop(f64);
                    try self.push(f32, @floatCast(v));
                },
                .f64_promote_f32 => {
                    const v = self.pop(f32);
                    try self.push(f64, @floatCast(v));
                },
                .i32_reinterpret_f32 => {
                    const v = self.pop(f32);
                    try self.push(i32, @bitCast(v));
                },
                .i64_reinterpret_f64 => {
                    const v = self.pop(f64);
                    try self.push(i64, @bitCast(v));
                },
                .f32_reinterpret_i32 => {
                    const v = self.pop(i32);
                    try self.push(f32, @bitCast(v));
                },
                .f64_reinterpret_i64 => {
                    const v = self.pop(i64);
                    try self.push(f64, @bitCast(v));
                },
                .i32_extend8_s => {
                    try self.push(i32, intExtend(i32, i8, self.pop(i32)));
                },
                .i32_extend16_s => {
                    try self.push(i32, intExtend(i32, i16, self.pop(i32)));
                },
                .i64_extend8_s => {
                    try self.push(i64, intExtend(i64, i8, self.pop(i64)));
                },
                .i64_extend16_s => {
                    try self.push(i64, intExtend(i64, i16, self.pop(i64)));
                },
                .i64_extend32_s => {
                    try self.push(i64, intExtend(i64, i32, self.pop(i64)));
                },
            }
        }
    }
};
