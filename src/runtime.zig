const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const LocalIndex = types.LocalIndex;
const GlobalIndex = types.GlobalIndex;
const MemIndex = types.MemIndex;
const ValType = types.ValType;

const PC = usize;
const FuncRef = ?FuncAddr;
const ExternRef = ?*anyopaque;

pub const Value = union(ValType) {
    const NullRefSentinel = std.math.maxInt(u64);

    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
    funcref: FuncRef,
    externref: ExternRef,

    pub fn getType(self: Value) ValType {
        return std.meta.activeTag(self);
    }

    pub fn format(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .i32 => |n| try writer.print("{d}", .{n}),
            .i64 => |n| try writer.print("{d}", .{n}),
            .f32 => |x| try writer.print("{d}", .{x}),
            .f64 => |x| try writer.print("{d}", .{x}),
            .funcref => try writer.print("<funcref>", .{}),
            .externref => try writer.print("<externref>", .{}),
        }
    }

    fn matchingType(comptime VT: ValType) type {
        return switch (VT) {
            .i32 => i32,
            .i64 => i64,
            .f32 => f32,
            .f64 => f64,
            .funcref => FuncRef,
            .externref => ExternRef,
        };
    }

    fn staticEncode(comptime VT: ValType, val: matchingType(VT)) u64 {
        return switch (VT) {
            .i32 => @as(u64, @as(u32, @bitCast(val))),
            .i64 => @as(u64, @bitCast(val)),
            .f32 => @as(u64, @as(u32, @bitCast(val))),
            .f64 => @as(u64, @bitCast(val)),
            .funcref => if (val) |func_addr| @intCast(func_addr) else NullRefSentinel,
            .externref => if (val) |ref_ptr| @intCast(@intFromPtr(ref_ptr)) else NullRefSentinel,
        };
    }

    fn staticDecode(comptime VT: ValType, val: u64) matchingType(VT) {
        return switch (VT) {
            .i32 => @bitCast(@as(u32, @truncate(val))),
            .i64 => @bitCast(val),
            .f32 => @bitCast(@as(u32, @truncate(val))),
            .f64 => @bitCast(val),
            .funcref => if (val == NullRefSentinel) null else @intCast(val),
            .externref => if (val == NullRefSentinel) null else @ptrFromInt(val),
        };
    }

    fn encode(self: Value) u64 {
        return switch (self) {
            .i32 => |n| staticEncode(.i32, n),
            .i64 => |n| staticEncode(.i64, n),
            .f32 => |x| staticEncode(.f32, x),
            .f64 => |x| staticEncode(.f64, x),
            .funcref => |func_ref| staticEncode(.funcref, func_ref),
            .externref => |ref_ptr| staticEncode(.externref, ref_ptr),
        };
    }

    fn decode(val_type: ValType, val: u64) Value {
        return switch (val_type) {
            .i32 => .{ .i32 = staticDecode(.i32, val) },
            .i64 => .{ .i64 = staticDecode(.i64, val) },
            .f32 => .{ .f32 = staticDecode(.f32, val) },
            .f64 => .{ .f64 = staticDecode(.f64, val) },
            .funcref => .{ .funcref = staticDecode(.funcref, val) },
            .externref => .{ .externref = staticDecode(.externref, val) },
        };
    }

    pub fn fromBytes(comptime VT: ValType, bytes: []const u8) !matchingType(VT) {
        const T = matchingType(VT);
        if (bytes.len != @sizeOf(T)) return error.InvalidByteSliceLength;
        return std.mem.bytesToValue(T, bytes[0..@sizeOf(T)]);
    }

    pub fn toBytes(comptime VT: ValType, val: matchingType(VT)) [@sizeOf(matchingType(VT))]u8 {
        return std.mem.toBytes(val);
    }
};

const MemArg = struct {
    alignment: u32,
    offset: u32,
    mem_addr: MemAddr,
};

const BranchUnwindArg = struct {
    target_pc: PC,
    stack_height: usize, // relative to frame.base_ptr: unwind destination before placing results
    arity: usize, // number of result values to preserve on top
};

const BranchTableEntry = struct {
    target_pc: PC,
    stack_height: usize,
    arity: usize,
};

// targets[0..len-1] are indexed entries; targets[len-1] is the default.
const BranchTableArg = struct {
    targets: []BranchTableEntry,
};

pub const FlatInstr = union(enum) {
    // Control instructions
    @"unreachable",
    nop,
    sentinel,
    br: PC,
    br_unwind: BranchUnwindArg,
    br_if: PC,
    br_if_unwind: BranchUnwindArg,
    br_table: BranchTableArg,
    @"return": usize, // number of values to return
    call: struct { entry_pc: PC, arguments: usize },
    call_indirect: struct { func_type: *const types.FuncType, table_addr: TableAddr },
    call_host: FuncAddr,

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
    super_duplicate: usize, // count

    // Parametric instructions
    drop,
    select,

    // Variable instructions
    local_get: LocalIndex,
    local_set: LocalIndex,
    local_tee: LocalIndex,
    global_get: GlobalAddr,
    global_set: GlobalAddr,

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
    memory_size: MemAddr,
    memory_grow: MemAddr,
    memory_init: struct { data_idx: DataAddr, mem: MemAddr },
    data_drop: DataAddr,
    memory_copy: struct { dst_mem: MemAddr, src_mem: MemAddr },
    memory_fill: MemAddr,

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
    ref_null: types.RefType,
    ref_is_null,
    ref_func: FuncAddr,
    table_get: TableAddr,
    table_set: TableAddr,
    table_init: struct { elem_addr: ElemAddr, table_addr: TableAddr },
    elem_drop: ElemAddr,
    table_copy: struct { dst_table_addr: TableAddr, src_table_addr: TableAddr },
    table_grow: TableAddr,
    table_size: TableAddr,
    table_fill: TableAddr,

    pub fn format(self: FlatInstr, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            // Control instructions
            .@"unreachable" => try writer.writeAll("unreachable"),
            .nop => try writer.writeAll("nop"),
            .sentinel => try writer.writeAll("placeholder"),
            .br => |target_pc| try writer.print("br {d}", .{target_pc}),
            .br_unwind => |arg| try writer.print("br_unwind pc={d} height={d} arity={d}", .{ arg.target_pc, arg.stack_height, arg.arity }),
            .br_if => |target_pc| try writer.print("br_if {d}", .{target_pc}),
            .br_if_unwind => |arg| try writer.print("br_if_unwind pc={d} height={d} arity={d}", .{ arg.target_pc, arg.stack_height, arg.arity }),
            .br_table => |arg| {
                try writer.writeAll("br_table [");
                const indexed = if (arg.targets.len > 0) arg.targets[0 .. arg.targets.len - 1] else &[_]BranchTableEntry{};
                for (indexed, 0..) |entry, i| {
                    try writer.print("{d}", .{entry.target_pc});
                    if (i != indexed.len - 1) try writer.writeAll(", ");
                }
                if (arg.targets.len > 0) {
                    try writer.print("] default={d}", .{arg.targets[arg.targets.len - 1].target_pc});
                } else {
                    try writer.writeAll("] (empty)");
                }
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
            .super_duplicate => |count| try writer.print("super.duplicate {d}", .{count}),

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
            // Saturating truncation instructions
            .i32_trunc_sat_f32_s => try writer.writeAll("i32.trunc_sat_f32_s"),
            .i32_trunc_sat_f32_u => try writer.writeAll("i32.trunc_sat_f32_u"),
            .i32_trunc_sat_f64_s => try writer.writeAll("i32.trunc_sat_f64_s"),
            .i32_trunc_sat_f64_u => try writer.writeAll("i32.trunc_sat_f64_u"),
            .i64_trunc_sat_f32_s => try writer.writeAll("i64.trunc_sat_f32_s"),
            .i64_trunc_sat_f32_u => try writer.writeAll("i64.trunc_sat_f32_u"),
            .i64_trunc_sat_f64_s => try writer.writeAll("i64.trunc_sat_f64_s"),
            .i64_trunc_sat_f64_u => try writer.writeAll("i64.trunc_sat_f64_u"),

            // Bulk memory operations
            .memory_init => |arg| try writer.print("memory.init data={d} mem={d}", .{ arg.data_idx, arg.mem }),
            .data_drop => |idx| try writer.print("data.drop {d}", .{idx}),
            .memory_copy => |arg| try writer.print("memory.copy dest={d} src={d}", .{ arg.dst_mem, arg.src_mem }),
            .memory_fill => |mem| try writer.print("memory.fill mem={d}", .{mem}),

            // Reference instructions
            .ref_null => |ref_type| try writer.print("ref.null {f}", .{ref_type}),
            .ref_is_null => try writer.writeAll("ref.is_null"),
            .ref_func => |func_addr| try writer.print("ref.func {d}", .{func_addr}),
            .table_get => |table_addr| try writer.print("table.get {d}", .{table_addr}),
            .table_set => |table_addr| try writer.print("table.set {d}", .{table_addr}),
            .table_init => |arg| try writer.print("table.init elem={d} table={d}", .{ arg.elem_addr, arg.table_addr }),
            .elem_drop => |idx| try writer.print("elem.drop {d}", .{idx}),
            .table_copy => |arg| try writer.print("table.copy dest={d} src={d}", .{ arg.dst_table_addr, arg.src_table_addr }),
            .table_grow => |table_addr| try writer.print("table.grow {d}", .{table_addr}),
            .table_size => |table_addr| try writer.print("table.size {d}", .{table_addr}),
            .table_fill => |table_addr| try writer.print("table.fill {d}", .{table_addr}),
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
    stack_height: usize, // base height for unwind (relative to frame.base_ptr)
    arity: usize, // number of result/param values to preserve on branch

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
                    allocator.free(arg.targets);
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

fn Bitset(comptime T: type) type {
    if (comptime @bitSizeOf(T) & 7 != 0) {
        @compileError("Bitset word size must be a multiple of 8 bits");
    }

    return struct {
        const Self = Bitset(T);
        const word_bits = @bitSizeOf(T);
        bit_count: usize,
        words: []T,

        fn init(allocator: Allocator, bit_count: usize) !Self {
            const word_count = (bit_count + word_bits - 1) / word_bits;
            const words = try allocator.alloc(T, word_count);
            @memset(words, 0);

            return .{
                .bit_count = bit_count,
                .words = words,
            };
        }

        fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.words);
        }

        fn bitPosition(self: *const Self, idx: usize) struct { word_idx: usize, shift: std.math.Log2Int(T) } {
            std.debug.assert(idx < self.bit_count);
            return .{
                .word_idx = idx / word_bits,
                .shift = @intCast(idx & (word_bits - 1)),
            };
        }

        fn set(self: *Self, idx: usize) void {
            const pos = self.bitPosition(idx);
            self.words[pos.word_idx] |= (@as(T, 1) << pos.shift);
        }

        fn isSet(self: *const Self, idx: usize) bool {
            const pos = self.bitPosition(idx);
            return ((self.words[pos.word_idx] >> pos.shift) & 1) != 0;
        }
    };
}

const PcRemapTable = struct {
    prefix_non_sentinel: []PC,
    next_non_sentinel: []PC,

    fn init(allocator: Allocator, instrs: []const FlatInstr) !PcRemapTable {
        const old_len = instrs.len;
        const prefix_non_sentinel = try allocator.alloc(PC, old_len + 1);
        errdefer allocator.free(prefix_non_sentinel);
        prefix_non_sentinel[0] = 0;

        for (instrs, 0..) |instr, i| {
            prefix_non_sentinel[i + 1] = prefix_non_sentinel[i] + @intFromBool(instr != .sentinel);
        }

        const next_non_sentinel = try allocator.alloc(PC, old_len + 1);
        errdefer allocator.free(next_non_sentinel);
        next_non_sentinel[old_len] = old_len;

        var i = old_len;
        while (i > 0) {
            i -= 1;
            next_non_sentinel[i] = if (instrs[i] == .sentinel) next_non_sentinel[i + 1] else i;
        }

        return .{
            .prefix_non_sentinel = prefix_non_sentinel,
            .next_non_sentinel = next_non_sentinel,
        };
    }

    fn deinit(self: *PcRemapTable, allocator: Allocator) void {
        allocator.free(self.prefix_non_sentinel);
        allocator.free(self.next_non_sentinel);
    }

    fn resolve(self: *const PcRemapTable, old_pc: PC) PC {
        std.debug.assert(old_pc < self.next_non_sentinel.len);
        const next_pc = self.next_non_sentinel[old_pc];

        if (next_pc == self.prefix_non_sentinel.len - 1) {
            return self.prefix_non_sentinel[self.prefix_non_sentinel.len - 1];
        } else {
            return self.prefix_non_sentinel[next_pc];
        }
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
    branch_instr_idx: usize,
    stack_height: usize, // running value stack depth relative to frame base, for fast/slow branch selection

    pub fn init(allocator: Allocator, store: *const Store) !BytecodeLowering {
        if (comptime @sizeOf(FlatInstr) > 32) {
            @compileError("FlatInstr should be 32 bytes or less");
        }

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
            .branch_instr_idx = 0,
            .stack_height = 0,
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
                .host => {},
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
        var remap_table = try PcRemapTable.init(self.allocator, self.flat.items);
        defer remap_table.deinit(self.allocator);

        // Rewrite all PC-based targets against the pre-compaction layout
        for (self.flat.items) |*instr| {
            switch (instr.*) {
                .br => |*target| {
                    target.* = remap_table.resolve(target.*);
                },
                .br_unwind => |*arg| {
                    arg.target_pc = remap_table.resolve(arg.target_pc);
                },
                .br_if => |*target| {
                    target.* = remap_table.resolve(target.*);
                },
                .br_if_unwind => |*arg| {
                    arg.target_pc = remap_table.resolve(arg.target_pc);
                },
                .br_table => |*arg| {
                    for (arg.targets) |*entry| {
                        entry.target_pc = remap_table.resolve(entry.target_pc);
                    }
                },
                .call => |*arg| {
                    arg.entry_pc = remap_table.resolve(arg.entry_pc);
                },
                .super_i32_eqz_br_if => |*target| {
                    target.* = remap_table.resolve(target.*);
                },
                .super_i32_eq_br_if => |*target| {
                    target.* = remap_table.resolve(target.*);
                },
                .super_local_get_i32_const_i32_eq_br_if => |*arg| {
                    arg.target = remap_table.resolve(arg.target);
                },
                .super_local_get_i32_const_i32_ge_u_br_if => |*arg| {
                    arg.target = remap_table.resolve(arg.target);
                },
                .super_local_get_i32_const_i32_le_u_br_if => |*arg| {
                    arg.target = remap_table.resolve(arg.target);
                },
                else => {},
            }
        }

        for (self.func_labels) |*label| {
            label.entry = remap_table.resolve(label.entry);
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

        // PCs that are branch/function-entry targets. We never fuse away an
        // instruction at one of these PCs (except pattern start) to avoid
        // changing externally reachable control-flow entry points.
        var target_pcs = try Bitset(usize).init(self.allocator, self.flat.items.len);
        defer target_pcs.deinit(self.allocator);

        for (self.func_labels) |func_label| {
            if (func_label.entry < self.flat.items.len) {
                target_pcs.set(func_label.entry);
            }
        }

        for (self.flat.items) |instr| {
            switch (instr) {
                .br => |target| if (target < self.flat.items.len) {
                    target_pcs.set(target);
                },
                .br_unwind => |arg| if (arg.target_pc < self.flat.items.len) {
                    target_pcs.set(arg.target_pc);
                },
                .br_if => |target| if (target < self.flat.items.len) {
                    target_pcs.set(target);
                },
                .br_if_unwind => |arg| if (arg.target_pc < self.flat.items.len) {
                    target_pcs.set(arg.target_pc);
                },
                .br_table => |arg| {
                    for (arg.targets) |entry| {
                        if (entry.target_pc < self.flat.items.len) {
                            target_pcs.set(entry.target_pc);
                        }
                    }
                },
                else => {},
            }
        }

        var i: usize = 0;
        while (i < self.flat.items.len) : (i += 1) {
            if (self.matchTagPattern(i, &.{ .i32_eqz, .br_if }, &target_pcs)) {
                const target = self.flat.items[i + 1].br_if;
                self.flat.items[i] = .{ .super_i32_eqz_br_if = target };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .i32_const, .local_set }, &target_pcs)) {
                const imm = self.flat.items[i].i32_const;
                const local = self.flat.items[i + 1].local_set;
                self.flat.items[i] = .{ .super_i32_const_local_set = .{ .imm = imm, .local = local } };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .i64_const, .local_set }, &target_pcs)) {
                const imm = self.flat.items[i].i64_const;
                const local = self.flat.items[i + 1].local_set;
                self.flat.items[i] = .{ .super_i64_const_local_set = .{ .imm = imm, .local = local } };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .f32_const, .local_set }, &target_pcs)) {
                const imm = self.flat.items[i].f32_const;
                const local = self.flat.items[i + 1].local_set;
                self.flat.items[i] = .{ .super_f32_const_local_set = .{ .imm = imm, .local = local } };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .f64_const, .local_set }, &target_pcs)) {
                const imm = self.flat.items[i].f64_const;
                const local = self.flat.items[i + 1].local_set;
                self.flat.items[i] = .{ .super_f64_const_local_set = .{ .imm = imm, .local = local } };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .i32_const, .ret }, &target_pcs) and
                self.flat.items[i + 1].@"return" == 1)
            {
                const imm = self.flat.items[i].i32_const;
                self.flat.items[i] = .{ .super_i32_const_return = imm };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .i64_const, .ret }, &target_pcs) and
                self.flat.items[i + 1].@"return" == 1)
            {
                const imm = self.flat.items[i].i64_const;
                self.flat.items[i] = .{ .super_i64_const_return = imm };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .f32_const, .ret }, &target_pcs) and
                self.flat.items[i + 1].@"return" == 1)
            {
                const imm = self.flat.items[i].f32_const;
                self.flat.items[i] = .{ .super_f32_const_return = imm };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .f64_const, .ret }, &target_pcs) and
                self.flat.items[i + 1].@"return" == 1)
            {
                const imm = self.flat.items[i].f64_const;
                self.flat.items[i] = .{ .super_f64_const_return = imm };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .i32_eq, .br_if }, &target_pcs)) {
                const target = self.flat.items[i + 1].br_if;
                self.flat.items[i] = .{ .super_i32_eq_br_if = target };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .local_get, .local_get, .i32_add }, &target_pcs)) {
                const lhs = self.flat.items[i].local_get;
                const rhs = self.flat.items[i + 1].local_get;
                self.flat.items[i] = .{ .super_local_get_local_get_i32_add = .{ .lhs = lhs, .rhs = rhs } };
                self.flat.items[i + 1] = .sentinel;
                self.flat.items[i + 2] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .local_get, .local_get, .i32_mul }, &target_pcs)) {
                const lhs = self.flat.items[i].local_get;
                const rhs = self.flat.items[i + 1].local_get;
                self.flat.items[i] = .{ .super_local_get_local_get_i32_mul = .{ .lhs = lhs, .rhs = rhs } };
                self.flat.items[i + 1] = .sentinel;
                self.flat.items[i + 2] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .local_get, .i32_const, .i32_add }, &target_pcs)) {
                const lhs = self.flat.items[i].local_get;
                const imm = self.flat.items[i + 1].i32_const;
                self.flat.items[i] = .{ .super_local_get_i32_const_i32_add = .{ .local = lhs, .imm = imm } };
                self.flat.items[i + 1] = .sentinel;
                self.flat.items[i + 2] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .local_get, .local_get }, &target_pcs)) {
                const lhs = self.flat.items[i].local_get;
                const rhs = self.flat.items[i + 1].local_get;
                self.flat.items[i] = .{ .super_local_get_local_get = .{ .lhs = lhs, .rhs = rhs } };
                self.flat.items[i + 1] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .local_get, .i32_const, .i32_add, .local_set }, &target_pcs)) {
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

            if (self.matchTagPattern(i, &.{ .local_get, .i32_const, .i32_sub, .local_set }, &target_pcs)) {
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

            if (self.matchTagPattern(i, &.{ .local_get, .i32_const, .i32_eq, .br_if }, &target_pcs)) {
                const local = self.flat.items[i].local_get;
                const imm = self.flat.items[i + 1].i32_const;
                const target = self.flat.items[i + 3].br_if;
                self.flat.items[i] = .{ .super_local_get_i32_const_i32_eq_br_if = .{ .local = local, .imm = imm, .target = target } };
                self.flat.items[i + 1] = .sentinel;
                self.flat.items[i + 2] = .sentinel;
                self.flat.items[i + 3] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .local_get, .i32_const, .i32_ge_u, .br_if }, &target_pcs)) {
                const local = self.flat.items[i].local_get;
                const imm = self.flat.items[i + 1].i32_const;
                const target = self.flat.items[i + 3].br_if;
                self.flat.items[i] = .{ .super_local_get_i32_const_i32_ge_u_br_if = .{ .local = local, .imm = imm, .target = target } };
                self.flat.items[i + 1] = .sentinel;
                self.flat.items[i + 2] = .sentinel;
                self.flat.items[i + 3] = .sentinel;
                continue;
            }

            if (self.matchTagPattern(i, &.{ .local_get, .i32_const, .i32_le_u, .br_if }, &target_pcs)) {
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

    fn matchTagPattern(self: *const BytecodeLowering, start: usize, tags: []const InstrTag, target_pcs: *const Bitset(usize)) bool {
        if (start + tags.len > self.flat.items.len) return false;

        for (tags, 0..) |tag, offset| {
            if (offset > 0 and target_pcs.isSet(start + offset)) return false;
            if (tagOf(self.flat.items[start + offset]) != tag) return false;
        }

        return true;
    }

    fn lowerFunc(self: *BytecodeLowering, func: *const WasmFunc, func_index: usize) !void {
        // record the start of the function
        var label = &self.func_labels[func_index];
        label.entry = self.flat.items.len;
        self.current_func = func;
        defer self.current_func = null;

        // stack_height tracks the value stack depth relative to frame.base_ptr.
        // At function entry, params are already on the stack.
        self.stack_height = func.type.params.len;

        // Emit instructions to initialize local variables with default values
        // Note: parameters are already on the stack, pushed by caller
        for (func.code.locals) |local_group| {
            const default_val: FlatInstr = switch (local_group.type) {
                .i32 => .{ .i32_const = 0 },
                .i64 => .{ .i64_const = 0 },
                .f32 => .{ .f32_const = 0.0 },
                .f64 => .{ .f64_const = 0.0 },
                .funcref => .{ .ref_null = .funcref },
                .externref => .{ .ref_null = .externref },
            };

            try self.emit(default_val);

            if (local_group.count > 1) {
                try self.emit(.{ .super_duplicate = local_group.count - 1 });
            }

            self.stack_height += local_group.count;
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
                        .br => |*target| target.* = label.end,
                        .br_unwind => |*arg| arg.target_pc = label.end,
                        .br_if => |*target| target.* = label.end,
                        .br_if_unwind => |*arg| arg.target_pc = label.end,
                        else => return error.InvalidBranchInstructionForPatching,
                    }
                },
                .br_table_patch => |arg| {
                    switch (self.flat.items[arg.instr_idx]) {
                        .br_table => |*table| {
                            switch (arg.label) {
                                .default => {
                                    table.targets[table.targets.len - 1].target_pc = label.end;
                                },
                                .index => |label_idx| {
                                    if (label_idx >= table.targets.len - 1) {
                                        return error.InvalidBranchTableLabelIndexForPatching;
                                    }

                                    table.targets[label_idx].target_pc = label.end;
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
            .mem_addr = mem_addr,
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

    fn getCurrentModule(self: *BytecodeLowering) !*ModuleInstance {
        if (self.current_func) |func| {
            return func.module;
        } else {
            return error.NoCurrentFunction;
        }
    }

    fn blockArity(self: *BytecodeLowering, block_type: types.BlockType) !usize {
        return switch (block_type) {
            .empty => 0,
            .val_type => 1,
            .type_index => |idx| blk: {
                const module = try self.getCurrentModule();
                if (idx >= module.types.len) return error.InvalidTypeIndex;
                break :blk module.types[idx].results.len;
            },
        };
    }

    fn blockParams(self: *BytecodeLowering, block_type: types.BlockType) !usize {
        return switch (block_type) {
            .empty, .val_type => 0,
            .type_index => |idx| blk: {
                const module = try self.getCurrentModule();
                if (idx >= module.types.len) return error.InvalidTypeIndex;
                break :blk module.types[idx].params.len;
            },
        };
    }

    /// Net stack height change for non-control instructions (after execution).
    /// Control instructions (block/loop/if/br/br_table/return) manage stack_height themselves.
    fn instrStackDelta(self: *BytecodeLowering, instr: types.Instr) !isize {
        return switch (instr) {
            // Control — handled explicitly in lowerInstr
            .@"unreachable", .nop, .block, .loop, .@"if", .br, .br_if, .br_table, .@"return" => 0,
            // Calls
            .call => |func_idx| blk: {
                const module_inst = try self.getCurrentModule();
                const func_addr = module_inst.func_addrs[func_idx];
                const func_inst = self.store.funcs.items[func_addr];
                const ft = func_inst.getType();
                break :blk @as(isize, @intCast(ft.results.len)) - @as(isize, @intCast(ft.params.len));
            },
            .call_indirect => |arg| blk: {
                const module_inst = try self.getCurrentModule();
                const ft = module_inst.types[arg.type_idx];
                // -1 for the table index operand
                break :blk @as(isize, @intCast(ft.results.len)) - @as(isize, @intCast(ft.params.len)) - 1;
            },
            // Parametric
            .drop => -1,
            .select => -2, // pop val1, val2, i32 → push val
            // Variable
            .local_get => 1,
            .local_set => -1,
            .local_tee => 0,
            .global_get => 1,
            .global_set => -1,
            // Memory loads: pop addr → push value
            .i32_load, .i64_load, .f32_load, .f64_load, .i32_load8_s, .i32_load8_u, .i32_load16_s, .i32_load16_u, .i64_load8_s, .i64_load8_u, .i64_load16_s, .i64_load16_u, .i64_load32_s, .i64_load32_u => 0, // pop addr, push val = net 0
            // Memory stores: pop addr + val
            .i32_store, .i64_store, .f32_store, .f64_store, .i32_store8, .i32_store16, .i64_store8, .i64_store16, .i64_store32 => -2,
            .memory_size => 1,
            .memory_grow => 0, // pop pages → push old_size
            .memory_init => -3,
            .data_drop => 0,
            .memory_copy => -3,
            .memory_fill => -3,
            // Constants
            .i32_const, .i64_const, .f32_const, .f64_const => 1,
            // i32 unary: pop → push
            .i32_eqz, .i32_clz, .i32_ctz, .i32_popcnt => 0,
            // i32 binary: pop 2 → push 1
            .i32_eq, .i32_ne, .i32_lt_s, .i32_lt_u, .i32_gt_s, .i32_gt_u, .i32_le_s, .i32_le_u, .i32_ge_s, .i32_ge_u, .i32_add, .i32_sub, .i32_mul, .i32_div_s, .i32_div_u, .i32_rem_s, .i32_rem_u, .i32_and, .i32_or, .i32_xor, .i32_shl, .i32_shr_s, .i32_shr_u, .i32_rotl, .i32_rotr => -1,
            // i64 unary
            .i64_eqz => 0,
            .i64_clz, .i64_ctz, .i64_popcnt => 0,
            // i64 binary
            .i64_eq, .i64_ne, .i64_lt_s, .i64_lt_u, .i64_gt_s, .i64_gt_u, .i64_le_s, .i64_le_u, .i64_ge_s, .i64_ge_u, .i64_add, .i64_sub, .i64_mul, .i64_div_s, .i64_div_u, .i64_rem_s, .i64_rem_u, .i64_and, .i64_or, .i64_xor, .i64_shl, .i64_shr_s, .i64_shr_u, .i64_rotl, .i64_rotr => -1,
            // f32 unary
            .f32_abs, .f32_neg, .f32_ceil, .f32_floor, .f32_trunc, .f32_nearest, .f32_sqrt => 0,
            // f32 binary
            .f32_eq, .f32_ne, .f32_lt, .f32_gt, .f32_le, .f32_ge, .f32_add, .f32_sub, .f32_mul, .f32_div, .f32_min, .f32_max, .f32_copysign => -1,
            // f64 unary
            .f64_abs, .f64_neg, .f64_ceil, .f64_floor, .f64_trunc, .f64_nearest, .f64_sqrt => 0,
            // f64 binary
            .f64_eq, .f64_ne, .f64_lt, .f64_gt, .f64_le, .f64_ge, .f64_add, .f64_sub, .f64_mul, .f64_div, .f64_min, .f64_max, .f64_copysign => -1,
            // Conversions: all pop 1 → push 1
            .i32_wrap_i64, .i32_trunc_f32_s, .i32_trunc_f32_u, .i32_trunc_f64_s, .i32_trunc_f64_u, .i64_extend_i32_s, .i64_extend_i32_u, .i64_trunc_f32_s, .i64_trunc_f32_u, .i64_trunc_f64_s, .i64_trunc_f64_u, .f32_convert_i32_s, .f32_convert_i32_u, .f32_convert_i64_s, .f32_convert_i64_u, .f32_demote_f64, .f64_convert_i32_s, .f64_convert_i32_u, .f64_convert_i64_s, .f64_convert_i64_u, .f64_promote_f32, .i32_reinterpret_f32, .i64_reinterpret_f64, .f32_reinterpret_i32, .f64_reinterpret_i64, .i32_extend8_s, .i32_extend16_s, .i64_extend8_s, .i64_extend16_s, .i64_extend32_s, .i32_trunc_sat_f32_s, .i32_trunc_sat_f32_u, .i32_trunc_sat_f64_s, .i32_trunc_sat_f64_u, .i64_trunc_sat_f32_s, .i64_trunc_sat_f32_u, .i64_trunc_sat_f64_s, .i64_trunc_sat_f64_u => 0,
            // Reference
            .ref_null => 1,
            .ref_is_null => 0, // pop ref → push i32
            .ref_func => 1,
            // Table
            .table_get => 0, // pop idx → push ref
            .table_set => -2,
            .table_init => -3,
            .elem_drop => 0,
            .table_copy => -3,
            .table_grow => -1, // pop (ref, n) → push old_size
            .table_size => 1,
            .table_fill => -3,
        };
    }

    fn lowerInstr(self: *BytecodeLowering, instr: types.Instr) !void {
        const delta = try self.instrStackDelta(instr);
        switch (instr) {
            .@"unreachable" => try self.emit(.@"unreachable"),
            .nop => try self.emit(.nop),
            .block, .loop => |block| {
                const label_kind: BlockLabelKind = switch (instr) {
                    .block => .block,
                    .loop => .loop,
                    else => unreachable,
                };

                const num_params = try self.blockParams(block.block_type);
                const num_results = try self.blockArity(block.block_type);
                // For block: label arity = results (branch exits block with results).
                // For loop:  label arity = params (branch re-enters loop with params).
                const label_arity = if (label_kind == .loop) num_params else num_results;
                // stack_height at label entry: params are already on stack, subtract them
                // to get the base height the label targets
                const label_height = self.stack_height - num_params;

                try self.block_labels.append(self.allocator, BlockLabel{
                    .kind = label_kind,
                    .start = self.flat.items.len,
                    .end = 0, // To be patched
                    .branches_to_patch = .empty,
                    .stack_height = label_height,
                    .arity = label_arity,
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

                // After block: stack has base + results
                self.stack_height = label_height + num_results;
            },
            .@"if" => |if_| {
                const num_params = try self.blockParams(if_.block_type);
                const num_results = try self.blockArity(if_.block_type);
                const label_height = self.stack_height - num_params - 1; // -1 for the i32 condition

                try self.block_labels.append(self.allocator, BlockLabel{
                    .kind = .@"if",
                    .start = self.flat.items.len,
                    .end = 0, // To be patched
                    .branches_to_patch = .empty,
                    .stack_height = label_height,
                    .arity = num_results,
                });

                const exit_label_idx = self.block_labels.items.len - 1;

                // negate condition to skip then block if false (i32_eqz has net zero stack effect)
                try self.emit(.i32_eqz);
                const else_jump_idx = self.flat.items.len;
                // Fast-path br_if to else: br_if pops the negated condition (net -1 to stack)
                try self.emit(.{ .br_if = 0 }); // Placeholder for branch to else block
                self.stack_height -= 1; // br_if consumes the condition

                // Restore params onto stack for then body
                self.stack_height += num_params;

                for (if_.then_instructions) |then_instr| {
                    try self.lowerInstr(then_instr);
                }

                // Unconditionally jump to end of if after then block.
                // Emit fast or slow variant based on whether the stack height matches.
                {
                    const then_stack_height = self.stack_height;
                    const expected_height = label_height + num_results;
                    const patch_idx = self.flat.items.len;
                    try self.block_labels.items[exit_label_idx].branches_to_patch.append(self.allocator, BranchToPatch{
                        .br_patch = patch_idx,
                    });
                    if (then_stack_height == expected_height) {
                        try self.emit(.{ .br = 0 });
                    } else {
                        try self.emit(.{ .br_unwind = .{ .target_pc = 0, .stack_height = label_height, .arity = num_results } });
                    }
                }

                self.flat.items[else_jump_idx] = .{ .br_if = self.flat.items.len }; // Patch branch to else block

                // Reset stack for else branch: label_height + params
                self.stack_height = label_height + num_params;

                for (if_.else_instructions) |else_instr| {
                    try self.lowerInstr(else_instr);
                }

                var exit_label = &self.block_labels.items[exit_label_idx];
                exit_label.end = self.flat.items.len;
                try self.patchBranches(exit_label);
                exit_label.deinit(self.allocator);
                self.block_labels.items.len -= 1; // Pop the label

                self.stack_height = label_height + num_results;
            },
            .br, .br_if => |label_idx| {
                if (self.block_labels.items.len <= label_idx) {
                    return error.InvalidLabelIndex;
                }

                const label = &self.block_labels.items[self.block_labels.items.len - 1 - label_idx];
                // Determine whether unwinding is needed:
                // For br_if, the condition is consumed before branching, so we subtract 1
                // for the condition that br_if pops before deciding.
                const cur_height = switch (instr) {
                    .br_if => self.stack_height - 1, // br_if pops the condition first
                    else => self.stack_height,
                };
                const needs_unwind = cur_height != label.stack_height + label.arity;

                switch (label.kind) {
                    .loop => {
                        // Branch to the start of the loop (target is known, no patching needed)
                        if (needs_unwind) {
                            try self.emit(switch (instr) {
                                .br => .{ .br_unwind = .{ .target_pc = label.start, .stack_height = label.stack_height, .arity = label.arity } },
                                .br_if => .{ .br_if_unwind = .{ .target_pc = label.start, .stack_height = label.stack_height, .arity = label.arity } },
                                else => unreachable,
                            });
                        } else {
                            try self.emit(switch (instr) {
                                .br => .{ .br = label.start },
                                .br_if => .{ .br_if = label.start },
                                else => unreachable,
                            });
                        }
                    },
                    .block, .@"if" => {
                        // Emit a placeholder branch instruction and record it for patching
                        const patch_idx = self.flat.items.len;
                        try label.branches_to_patch.append(self.allocator, BranchToPatch{
                            .br_patch = patch_idx,
                        });

                        if (needs_unwind) {
                            try self.emit(switch (instr) {
                                .br => .{ .br_unwind = .{ .target_pc = 0, .stack_height = label.stack_height, .arity = label.arity } },
                                .br_if => .{ .br_if_unwind = .{ .target_pc = 0, .stack_height = label.stack_height, .arity = label.arity } },
                                else => unreachable,
                            });
                        } else {
                            try self.emit(switch (instr) {
                                .br => .{ .br = 0 },
                                .br_if => .{ .br_if = 0 },
                                else => unreachable,
                            });
                        }
                    },
                }
            },
            .br_table => |arg| {
                // Allocate label_indices.len + 1; the last entry is the default.
                const targets = try self.allocator.alloc(BranchTableEntry, arg.label_indices.len + 1);
                errdefer self.allocator.free(targets);
                const instr_idx = self.flat.items.len;
                // br_table pops the selector i32, so effective stack height is self.stack_height - 1
                const cur_height = self.stack_height - 1;

                for (targets[0..arg.label_indices.len], 0..) |*entry, i| {
                    const label_idx = arg.label_indices[i];
                    if (self.block_labels.items.len <= label_idx) return error.InvalidLabelIndex;
                    const lbl = &self.block_labels.items[self.block_labels.items.len - 1 - label_idx];
                    entry.stack_height = lbl.stack_height;
                    entry.arity = lbl.arity;
                    _ = cur_height; // already embedded in entry
                    try self.registerBranchPatch(&entry.target_pc, label_idx, BranchToPatch{
                        .br_table_patch = .{
                            .instr_idx = instr_idx,
                            .label = .{ .index = i },
                        },
                    });
                }

                // Default entry is last.
                {
                    const label_idx = arg.default_idx;
                    if (self.block_labels.items.len <= label_idx) return error.InvalidLabelIndex;
                    const lbl = &self.block_labels.items[self.block_labels.items.len - 1 - label_idx];
                    targets[targets.len - 1] = .{ .target_pc = 0, .stack_height = lbl.stack_height, .arity = lbl.arity };
                    try self.registerBranchPatch(&targets[targets.len - 1].target_pc, label_idx, BranchToPatch{
                        .br_table_patch = .{
                            .instr_idx = instr_idx,
                            .label = .default,
                        },
                    });
                }

                try self.emit(.{ .br_table = .{ .targets = targets } });
            },
            .call => |func_idx| {
                const call_instr_idx = self.flat.items.len;
                const module_inst = try self.getCurrentModule();
                const func_addr = module_inst.func_addrs[func_idx];
                const func_inst = self.store.funcs.items[func_addr];

                switch (func_inst) {
                    .wasm => |wasm_func| {
                        try self.emit(.{ .call = .{ .entry_pc = 0, .arguments = wasm_func.type.params.len } });
                        std.debug.assert(func_addr < self.func_labels.len);
                        try self.func_labels[func_addr].calls_to_patch.append(self.allocator, call_instr_idx);
                    },
                    .host => {
                        try self.emit(.{ .call_host = func_addr });
                    },
                }
            },
            .call_indirect => |arg| {
                const module_inst = try self.getCurrentModule();
                const table_addr = module_inst.table_addrs[arg.table_idx];
                std.debug.assert(module_inst.types.len > arg.type_idx);
                const func_type = &module_inst.types[arg.type_idx];
                try self.emit(.{ .call_indirect = .{ .func_type = func_type, .table_addr = table_addr } });
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

                switch (instr) {
                    .global_get => try self.emit(.{ .global_get = global_addr }),
                    else => try self.emit(.{ .global_set = global_addr }),
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
                try self.emit(.{ .memory_size = mem_addr });
            },
            .memory_grow => |idx| {
                const mem_addr = self.current_func.?.module.mem_addrs[idx];
                try self.emit(.{ .memory_grow = mem_addr });
            },
            .memory_init => |arg| {
                const data_addr = self.current_func.?.module.data_addrs[arg.data_idx];
                const mem_addr = self.current_func.?.module.mem_addrs[arg.mem_idx];
                try self.emit(.{ .memory_init = .{ .data_idx = data_addr, .mem = mem_addr } });
            },
            .data_drop => |idx| {
                const data_addr = self.current_func.?.module.data_addrs[idx];
                try self.emit(.{ .data_drop = data_addr });
            },
            .memory_copy => |arg| {
                const src_mem_addr = self.current_func.?.module.mem_addrs[arg.src_mem_idx];
                const dst_mem_addr = self.current_func.?.module.mem_addrs[arg.dst_mem_idx];
                try self.emit(.{ .memory_copy = .{ .src_mem = src_mem_addr, .dst_mem = dst_mem_addr } });
            },
            .memory_fill => |idx| {
                const mem_addr = self.current_func.?.module.mem_addrs[idx];
                try self.emit(.{ .memory_fill = mem_addr });
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
            .i32_trunc_sat_f32_s => try self.emit(.i32_trunc_sat_f32_s),
            .i32_trunc_sat_f32_u => try self.emit(.i32_trunc_sat_f32_u),
            .i32_trunc_sat_f64_s => try self.emit(.i32_trunc_sat_f64_s),
            .i32_trunc_sat_f64_u => try self.emit(.i32_trunc_sat_f64_u),
            .i64_trunc_sat_f32_s => try self.emit(.i64_trunc_sat_f32_s),
            .i64_trunc_sat_f32_u => try self.emit(.i64_trunc_sat_f32_u),
            .i64_trunc_sat_f64_s => try self.emit(.i64_trunc_sat_f64_s),
            .i64_trunc_sat_f64_u => try self.emit(.i64_trunc_sat_f64_u),
            .ref_null => |rt| try self.emit(.{ .ref_null = rt }),
            .ref_is_null => try self.emit(.ref_is_null),
            .ref_func => |func_idx| {
                const module_inst = try self.getCurrentModule();
                const func_addr = module_inst.func_addrs[func_idx];
                try self.emit(.{ .ref_func = func_addr });
            },
            .table_get => |idx| {
                const module_inst = try self.getCurrentModule();
                const table_addr = module_inst.table_addrs[idx];
                try self.emit(.{ .table_get = table_addr });
            },
            .table_set => |idx| {
                const module_inst = try self.getCurrentModule();
                const table_addr = module_inst.table_addrs[idx];
                try self.emit(.{ .table_set = table_addr });
            },
            .table_init => |arg| {
                const module_inst = try self.getCurrentModule();
                const table_addr = module_inst.table_addrs[arg.table_idx];
                const elem_addr = module_inst.elem_addrs[arg.elem_idx];
                try self.emit(.{ .table_init = .{ .elem_addr = elem_addr, .table_addr = table_addr } });
            },
            .elem_drop => |elem_idx| {
                const module_inst = try self.getCurrentModule();
                const elem_addr = module_inst.elem_addrs[elem_idx];
                try self.emit(.{ .elem_drop = elem_addr });
            },
            .table_copy => |arg| {
                const module_inst = try self.getCurrentModule();
                const src_table_addr = module_inst.table_addrs[arg.src_table_idx];
                const dst_table_addr = module_inst.table_addrs[arg.dst_table_idx];
                try self.emit(.{
                    .table_copy = .{
                        .src_table_addr = src_table_addr,
                        .dst_table_addr = dst_table_addr,
                    },
                });
            },
            .table_grow => |idx| {
                const module_inst = try self.getCurrentModule();
                const table_addr = module_inst.table_addrs[idx];
                try self.emit(.{ .table_grow = table_addr });
            },
            .table_size => |idx| {
                const module_inst = try self.getCurrentModule();
                const table_addr = module_inst.table_addrs[idx];
                try self.emit(.{ .table_size = table_addr });
            },
            .table_fill => |idx| {
                const module_inst = try self.getCurrentModule();
                const table_addr = module_inst.table_addrs[idx];
                try self.emit(.{ .table_fill = table_addr });
            },
        }
        // Apply net stack height change for non-control instructions.
        // Control instructions (block/loop/if/br/br_if/br_table/return) already
        // update self.stack_height directly and have delta == 0.
        if (delta > 0) {
            self.stack_height += @intCast(delta);
        } else if (delta < 0) {
            self.stack_height -= @intCast(-delta);
        }
    }
};

pub const Store = struct {
    allocator: Allocator,
    host_ctx: ?*anyopaque,
    funcs: ArrayList(FuncInstance),
    tables: ArrayList(TableInstance),
    mems: ArrayList(MemoryInstance),
    elems: ArrayList(ElemInstance),
    datas: ArrayList(DataInstance),
    globals: ArrayList(GlobalInstance),

    pub fn init(allocator: Allocator, host_ctx: ?*anyopaque) Store {
        return Store{
            .allocator = allocator,
            .host_ctx = host_ctx,
            .funcs = .empty,
            .tables = .empty,
            .mems = .empty,
            .elems = .empty,
            .datas = .empty,
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

        for (self.elems.items) |*elem| {
            elem.deinit(self.allocator);
        }

        for (self.funcs.items) |func| {
            switch (func) {
                .host => |hf| {
                    self.allocator.free(hf.type.params);
                    self.allocator.free(hf.type.results);
                },
                .wasm => {},
            }
        }

        self.funcs.deinit(self.allocator);
        self.tables.deinit(self.allocator);
        self.mems.deinit(self.allocator);
        self.elems.deinit(self.allocator);
        self.datas.deinit(self.allocator);
        self.globals.deinit(self.allocator);
    }

    pub fn getContext(self: *Store, comptime T: type) !*T {
        if (self.host_ctx) |ctx| {
            return @ptrCast(@alignCast(ctx));
        } else {
            return error.NoHostContext;
        }
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
        const data_addrs = try allocator.alloc(DataAddr, module.data.len);
        errdefer allocator.free(data_addrs);
        const global_addrs = try allocator.alloc(GlobalAddr, num_global_extern_vals + module.globals.len);
        errdefer allocator.free(global_addrs);
        const elem_addrs = try allocator.alloc(ElemAddr, module.elements.len);
        errdefer allocator.free(elem_addrs);
        const exports = try allocator.alloc(ExportInstance, module.exports.len);
        errdefer allocator.free(exports);

        const module_inst = try allocator.create(ModuleInstance);
        errdefer allocator.destroy(module_inst);

        // Deep-copy the type section so the module's parsed memory can be freed
        // after instantiation. FuncType params/results are referenced at runtime
        // (call_indirect checks, invokeFunc, etc.) so they must outlive the module.
        const types_copy = try allocator.alloc(types.FuncType, module.types.len);
        errdefer {
            for (types_copy) |*ft| ft.deinit(allocator);
            allocator.free(types_copy);
        }
        for (module.types, 0..) |ft, i| {
            const params = try allocator.dupe(types.ValType, ft.params);
            errdefer allocator.free(params);
            const results = try allocator.dupe(types.ValType, ft.results);
            types_copy[i] = .{ .params = params, .results = results };
        }

        module_inst.* = ModuleInstance{
            .types = types_copy,
            .func_addrs = func_addrs,
            .table_addrs = table_addrs,
            .mem_addrs = mem_addrs,
            .data_addrs = data_addrs,
            .global_addrs = global_addrs,
            .elem_addrs = elem_addrs,
            .exports = exports,
            .exports_by_name = .init(allocator),
            .start_addr = null,
        };

        errdefer module_inst.deinit(self.allocator);
        const func_base = self.funcs.items.len;
        const table_base = self.tables.items.len;
        const mem_base = self.mems.items.len;
        const global_base = self.globals.items.len;
        const elem_base = self.elems.items.len;

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
            if (type_idx_usize >= module_inst.types.len) {
                return error.InvalidTypeIndex;
            }

            const func_inst = FuncInstance{
                .wasm = .{
                    // Use the copied types so WasmFunc.type survives module.deinit().
                    .type = module_inst.types[type_idx_usize],
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

        if (module.start) |start_idx| {
            const start_idx_usize = @as(usize, start_idx);
            if (start_idx_usize >= module_inst.func_addrs.len) {
                return error.InvalidStartFunctionIndex;
            }

            module_inst.start_addr = module_inst.func_addrs[start_idx_usize];
        }

        // Allocate tables
        var local_table_idx: usize = 0;
        for (module.tables) |table_type| {
            const elem = try self.allocator.alloc(u64, table_type.limits.min);
            @memset(elem, Value.NullRefSentinel);
            const table_inst = TableInstance{
                .type = table_type.elem_type,
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
        for (module.globals, 0..) |global, i| {
            const global_inst = GlobalInstance{
                .value = global_init_vals[i],
                .mutable = global.type.mutable,
            };

            const global_addr = global_base + i;
            module_inst.global_addrs[next_global_idx] = global_addr;
            next_global_idx += 1;
            try self.globals.append(self.allocator, global_inst);
        }

        // Allocate elements
        for (module.elements, 0..) |*elem, i| {
            var elem_inst = ElemInstance{
                .refs = try self.allocator.alloc(u64, elem.init.length()),
            };

            switch (elem.init) {
                .func_indices => |indices| {
                    for (indices, 0..) |func_idx, j| {
                        const func_idx_usize = @as(usize, func_idx);
                        if (func_idx_usize >= module_inst.func_addrs.len) {
                            return error.InvalidFuncIndex;
                        }

                        const func_addr = module_inst.func_addrs[func_idx_usize];
                        elem_inst.refs[j] = Value.staticEncode(.funcref, func_addr);
                    }
                },
                .exprs => |exprs| {
                    for (exprs, 0..) |expr, j| {
                        const val = try self.evalConstExpr(global_addrs, expr);

                        if (!val.getType().isRefType()) {
                            return error.InvalidElemInitExpr;
                        }

                        elem_inst.refs[j] = val.encode();
                    }
                },
            }

            const elem_addr = elem_base + i;
            module_inst.elem_addrs[i] = elem_addr;
            try self.elems.append(self.allocator, elem_inst);
        }

        // Build exports, copying names so they survive module.deinit().
        for (module.exports, 0..) |exp, i| {
            const name = try allocator.dupe(u8, exp.name);
            errdefer allocator.free(name);

            const value: ExternVal = switch (exp.desc) {
                .func => |func_idx| blk: {
                    const func_idx_usize = @as(usize, func_idx);
                    if (func_idx_usize >= module_inst.func_addrs.len) {
                        return error.InvalidFuncIndex;
                    }
                    break :blk .{ .func = module_inst.func_addrs[func_idx_usize] };
                },
                .table => |table_idx| blk: {
                    const table_idx_usize = @as(usize, table_idx);
                    if (table_idx_usize >= module_inst.table_addrs.len) {
                        return error.InvalidTableIndex;
                    }
                    break :blk .{ .table = module_inst.table_addrs[table_idx_usize] };
                },
                .mem => |mem_idx| blk: {
                    const mem_idx_usize = @as(usize, mem_idx);
                    if (mem_idx_usize >= module_inst.mem_addrs.len) {
                        return error.InvalidMemIndex;
                    }
                    break :blk .{ .mem = module_inst.mem_addrs[mem_idx_usize] };
                },
                .global => |global_idx| blk: {
                    const global_idx_usize = @as(usize, global_idx);
                    if (global_idx_usize >= module_inst.global_addrs.len) {
                        return error.InvalidGlobalIndex;
                    }
                    break :blk .{ .global = module_inst.global_addrs[global_idx_usize] };
                },
            };

            module_inst.exports[i] = ExportInstance{ .name = name, .value = value };

            if (module_inst.exports_by_name.contains(name)) {
                return error.DuplicateExportName;
            }

            try module_inst.exports_by_name.put(name, value);
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

    fn registerHostFunc(self: *Store, ty: types.FuncType, func: HostFuncPtr) !FuncAddr {
        const params = try self.allocator.dupe(types.ValType, ty.params);
        errdefer self.allocator.free(params);
        const results = try self.allocator.dupe(types.ValType, ty.results);
        const func_addr = self.funcs.items.len;
        try self.funcs.append(self.allocator, .{ .host = .{ .type = .{ .params = params, .results = results }, .code = func } });
        return func_addr;
    }

    const ImportVal = union(enum) {
        func: HostFuncPtr,
        global: GlobalAddr,
    };

    pub const Import = struct {
        module: types.Name,
        name: types.Name,
        value: ImportVal,
    };

    fn lookupImport(module: types.Name, name: types.Name, imports: []const Import) ?ImportVal {
        for (imports) |import| {
            if (std.mem.eql(u8, import.module, module) and std.mem.eql(u8, import.name, name)) {
                return import.value;
            }
        }

        return null;
    }

    fn initTable(
        self: *Store,
        table_addr: TableAddr,
        elem_addr: ElemAddr,
        table_src_offset: usize,
        elem_dst_offset: usize,
        count: usize,
    ) !void {
        if (count == 0) return;
        const table_inst = &self.tables.items[table_addr];
        const values = self.elems.items[elem_addr].refs;
        if (table_src_offset + count > table_inst.elem.len or elem_dst_offset + count > values.len) {
            return error.TableInitOutOfBounds;
        }

        @memcpy(
            table_inst.elem[table_src_offset .. table_src_offset + count],
            values[elem_dst_offset .. elem_dst_offset + count],
        );
    }

    pub fn instantiate(self: *Store, module: types.Module, imports: []const Import) !*ModuleInstance {
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

        var extern_vals: std.ArrayList(ExternVal) = try .initCapacity(self.allocator, module.imports.len);
        defer extern_vals.deinit(self.allocator);

        for (module.imports) |import| {
            if (lookupImport(import.module, import.name, imports)) |import_val| {
                switch (import.desc) {
                    .func => |func_type_index| {
                        switch (import_val) {
                            .func => |host_func| {
                                const func_type = module.types[@as(usize, func_type_index)];
                                const func_addr = try self.registerHostFunc(func_type, host_func);
                                try extern_vals.append(self.allocator, .{ .func = func_addr });
                            },
                            else => return error.InvalidFuncImport,
                        }
                    },
                    .table => {
                        return error.TableImportNotSupported;
                    },
                    .mem => {
                        return error.MemImportNotSupported;
                    },
                    .global => {
                        const addr = switch (import_val) {
                            .global => |addr| addr,
                            else => return error.InvalidGlobalImport,
                        };
                        global_extern_vals[global_import_idx] = addr;
                        global_import_idx += 1;
                        try extern_vals.append(self.allocator, .{ .global = addr });
                    },
                }
            } else {
                // list all missing imports
                for (module.imports) |imp| {
                    if (lookupImport(imp.module, imp.name, imports) == null) {
                        std.debug.print("Missing import: {s}.{s}\n", .{ imp.module, imp.name });
                    }
                }

                return error.MissingImport;
            }
        }

        const global_init_vals = try self.allocator.alloc(Value, module.globals.len);
        defer self.allocator.free(global_init_vals);

        for (module.globals, 0..) |global, i| {
            const val = try self.evalConstExpr(global_extern_vals, global.init);
            global_init_vals[i] = val;
        }

        const elems_base_idx = self.elems.items.len;
        const module_inst = try self.allocModule(self.allocator, module, extern_vals.items, global_init_vals);

        // Initalise element segments
        for (module.elements, 0..) |elem, i| {
            switch (elem.mode) {
                .passive, .declarative => {},
                .active => |mode| {
                    const offset_val = try self.evalConstExpr(global_extern_vals, mode.offset);
                    const offset = switch (offset_val) {
                        .i32 => |n| blk: {
                            if (n < 0) {
                                return error.InvalidElemSegmentOffset;
                            }

                            break :blk @as(usize, @as(u32, @bitCast(n)));
                        },
                        else => return error.InvalidElemSegmentOffset,
                    };

                    const table_idx_usize = @as(usize, mode.table_idx);
                    if (table_idx_usize >= module_inst.table_addrs.len) {
                        return error.InvalidTableIndex;
                    }

                    const table_addr = module_inst.table_addrs[table_idx_usize];
                    const elem_addr = elems_base_idx + i;

                    try self.initTable(
                        table_addr,
                        elem_addr,
                        offset,
                        0,
                        elem.init.length(),
                    );
                },
            }
        }

        // Initialise data segments
        for (module.data) |data| {
            switch (data.mode) {
                .passive => {},
                .active => |active_mode| {
                    const offset_val = try self.evalConstExpr(global_extern_vals, active_mode.offset);
                    const offset = switch (offset_val) {
                        .i32 => |n| blk: {
                            if (n < 0) {
                                return error.InvalidDataSegmentOffset;
                            }

                            break :blk @as(usize, @as(u32, @bitCast(n)));
                        },
                        else => return error.InvalidDataSegmentOffset,
                    };

                    const mem_idx_usize = @as(usize, active_mode.mem_idx);
                    if (mem_idx_usize >= module_inst.mem_addrs.len) {
                        return error.InvalidMemIndex;
                    }

                    const mem_addr = module_inst.mem_addrs[mem_idx_usize];
                    const mem_inst = self.mems.items[mem_addr];
                    if (offset + data.init.len > mem_inst.data.len) {
                        return error.DataSegmentOutOfBounds;
                    }

                    @memcpy(mem_inst.data[offset .. offset + data.init.len], data.init);
                },
            }
        }

        return module_inst;
    }
};

pub const Addr = usize;
pub const FuncAddr = Addr;
pub const TableAddr = Addr;
pub const MemAddr = Addr;
pub const DataAddr = Addr;
pub const GlobalAddr = Addr;
pub const ElemAddr = Addr;

pub const ModuleInstance = struct {
    types: []types.FuncType,
    func_addrs: []FuncAddr,
    table_addrs: []TableAddr,
    mem_addrs: []MemAddr,
    data_addrs: []DataAddr,
    global_addrs: []GlobalAddr,
    elem_addrs: []ElemAddr,
    exports: []ExportInstance,
    exports_by_name: std.StringHashMap(ExternVal),
    start_addr: ?FuncAddr,

    pub fn deinit(self: *ModuleInstance, allocator: Allocator) void {
        for (self.types) |*ft| ft.deinit(allocator);
        allocator.free(self.types);
        allocator.free(self.func_addrs);
        allocator.free(self.table_addrs);
        allocator.free(self.mem_addrs);
        allocator.free(self.data_addrs);
        allocator.free(self.global_addrs);
        allocator.free(self.elem_addrs);

        for (self.exports) |exp| {
            allocator.free(exp.name);
        }

        allocator.free(self.exports);
        self.exports_by_name.deinit();
    }
};

const WasmFunc = struct {
    type: types.FuncType,
    module: *ModuleInstance,
    code: types.Func,
};

// use anyopaque to avoid dependency loops
pub const HostFuncPtr = *const fn (*anyopaque) anyerror!void;

pub const HostFunc = struct {
    type: types.FuncType,
    code: HostFuncPtr,
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
    type: types.RefType,
    elem: []u64, // encoded FuncRef or ExternRef
    max: ?u32,

    fn getElem(self: *const TableInstance, idx: usize) !Value {
        if (idx >= self.elem.len) {
            return error.TableIndexOutOfBounds;
        }

        const encoded_ref = self.elem[idx];
        return switch (self.type) {
            .funcref => .{ .funcref = Value.staticDecode(.funcref, encoded_ref) },
            .externref => .{ .externref = Value.staticDecode(.externref, encoded_ref) },
        };
    }

    fn setElem(self: *TableInstance, idx: usize, val: Value) !void {
        if (idx >= self.elem.len) {
            return error.TableIndexOutOfBounds;
        }

        if (@intFromEnum(val.getType()) != @intFromEnum(self.type)) {
            return error.InvalidTableElementType;
        }

        const encoded_ref: u64 = switch (self.type) {
            .funcref => Value.staticEncode(.funcref, val.funcref),
            .externref => Value.staticEncode(.externref, val.externref),
        };

        self.elem[idx] = encoded_ref;
    }
};

const page_size: usize = 65_536;

const MemoryInstance = struct {
    data: []types.Byte,
    max: ?u32,

    pub fn read(self: *const MemoryInstance, comptime VT: ValType, offset: usize) !Value.matchingType(VT) {
        const byte_offset = offset + @sizeOf(Value.matchingType(VT));
        if (byte_offset > self.data.len) {
            return error.MemoryAccessOutOfBounds;
        }

        const bytes = self.data[offset..byte_offset];
        return Value.fromBytes(VT, bytes);
    }

    pub fn write(self: *MemoryInstance, comptime VT: ValType, offset: usize, val: Value.matchingType(VT)) !void {
        const bytes = Value.toBytes(VT, val);
        try self.writeBytes(offset, &bytes);
    }

    pub fn writeBytes(self: *MemoryInstance, offset: usize, bytes: []const u8) !void {
        const end = offset + bytes.len;
        if (end > self.data.len) {
            return error.MemoryAccessOutOfBounds;
        }

        @memcpy(self.data[offset..end], bytes);
    }
};

const GlobalInstance = struct {
    value: Value,
    mutable: bool,
};

const DataInstance = struct {
    data: []types.Byte,
};

const ExportInstance = struct {
    name: types.Name,
    value: ExternVal,
};

const ElemInstance = struct {
    refs: []u64, // encoded FuncRef or ExternRef

    fn init(allocator: Allocator, length: usize) !ElemInstance {
        const refs = try allocator.alloc(u64, length);
        @memset(refs, Value.NullRefSentinel);

        return ElemInstance{
            .refs = refs,
        };
    }

    fn deinit(self: *ElemInstance, allocator: Allocator) void {
        allocator.free(self.refs);
    }
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

pub const ValueStack = struct {
    const Size = 65536;
    const Self = @This();
    values: [Size]u64,
    types: [Size]ValType,
    top: usize,

    fn init() Self {
        return Self{
            .values = undefined,
            .types = undefined,
            .top = 0,
        };
    }

    pub fn push(self: *Self, comptime VT: ValType, val: Value.matchingType(VT)) !void {
        if (self.top >= Size) {
            return error.StackOverflow;
        }

        self.values[self.top] = Value.staticEncode(VT, val);
        self.types[self.top] = VT;
        self.top += 1;
    }

    pub fn pushValue(self: *Self, val: Value) !void {
        if (self.top >= Size) {
            return error.StackOverflow;
        }

        self.setValue(self.top, val);

        self.top += 1;
    }

    pub fn pop(self: *Self, comptime VT: ValType) !Value.matchingType(VT) {
        if (self.top == 0) {
            return error.StackUnderflow;
        }

        self.top -= 1;

        std.debug.assert(self.types[self.top] == VT);

        return Value.staticDecode(VT, self.values[self.top]);
    }

    pub fn popValue(self: *Self) !Value {
        if (self.top == 0) {
            return error.StackUnderflow;
        }

        self.top -= 1;
        const val_type = self.types[self.top];
        const val = self.values[self.top];
        return Value.decode(val_type, val);
    }

    pub fn popValues(self: *Self, allocator: Allocator, count: usize) ![]Value {
        if (self.top < count) {
            return error.StackUnderflow;
        }

        self.top -= count;

        const vals = try allocator.alloc(Value, count);
        errdefer allocator.free(vals);

        for (vals, 0..) |*val, i| {
            val.* = self.getValue(self.top + i);
        }

        return vals;
    }

    pub fn staticPopValues(self: *Self, comptime VT: ValType, comptime N: comptime_int) [N]Value.matchingType(VT) {
        var vals: [N]Value.matchingType(VT) = undefined;

        inline for (0..N) |i| {
            vals[i] = Value.staticDecode(VT, self.values[self.top - N + i]);
        }

        self.top -= N;
        return vals;
    }

    fn getValue(self: *const Self, idx: usize) Value {
        const val = self.values[idx];
        return Value.decode(self.types[idx], val);
    }

    fn setValue(self: *Self, idx: usize, val: Value) void {
        self.types[idx] = val.getType();
        self.values[idx] = val.encode();
    }
};

pub const Runtime = struct {
    allocator: Allocator,
    store: *Store,
    bytecode: Bytecode,
    stack: ValueStack,
    call_stack: FixedSizedStack(Frame, 16384),
    module: *ModuleInstance,

    pub fn init(allocator: Allocator, store: *Store, module: *ModuleInstance) !Runtime {
        var lowering = try BytecodeLowering.init(allocator, store);
        defer lowering.deinit();

        return Runtime{
            .allocator = allocator,
            .store = store,
            .bytecode = try lowering.lower(),
            .stack = .init(),
            .call_stack = .init(),
            .module = module,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.bytecode.deinit(self.allocator);
        self.module.deinit(self.store.allocator);
        self.store.allocator.destroy(self.module);
    }

    /// Invokes the start function of the module, if it has one.
    /// Returns true if a start function was invoked, false if the module has no start function.
    pub fn invokeStartFunc(self: *Runtime) !bool {
        if (self.module.start_addr) |addr| {
            _ = try self.invokeFunc(addr);
            return true;
        }

        return false;
    }

    pub fn getExportByName(self: *Runtime, name: types.Name) !ExternVal {
        if (self.module.exports_by_name.get(name)) |exp| {
            return exp;
        } else {
            return error.ExportNotFound;
        }
    }

    pub fn getExportedFuncType(self: *Runtime, export_name: types.Name) !types.FuncType {
        const exp = try self.getExportByName(export_name);
        return switch (exp) {
            .func => |func_addr| self.store.funcs.items[func_addr].getType(),
            else => return error.ExportNotAFunction,
        };
    }

    pub fn invokeExportedFunc(self: *Runtime, allocator: Allocator, export_name: types.Name, args: []const Value) ![]Value {
        const exp = try self.getExportByName(export_name);
        return switch (exp) {
            .func => |func_addr| self.invokeFuncWithArgs(allocator, func_addr, args),
            else => return error.ExportNotAFunction,
        };
    }

    pub fn invokeFuncWithArgs(self: *Runtime, allocator: Allocator, func_addr: FuncAddr, args: []const Value) ![]Value {
        const old_stack_top = self.stack.top;
        errdefer self.stack.top = old_stack_top;

        for (args) |arg| {
            try self.pushValue(arg);
        }

        const results_count = try self.invokeFunc(func_addr);

        return try self.stack.popValues(allocator, results_count);
    }

    /// Invokes the function at `func_addr`, assuming its arguments are already on the stack.
    /// Returns the number of results specified by the function type, which will be on top of the stack after invocation.
    pub fn invokeFunc(self: *Runtime, func_addr: FuncAddr) !usize {
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

        var results_count: usize = 0;

        switch (func_inst) {
            .wasm => |*wasm_func| {
                results_count = wasm_func.type.results.len;
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
                } else {
                    return error.FunctionNotFound;
                }
            },
            .host => |host_func| {
                results_count = host_func.type.results.len;
                try host_func.code(@ptrCast(self));
            },
        }

        return results_count;
    }

    inline fn push(self: *Runtime, comptime VT: ValType, val: Value.matchingType(VT)) !void {
        try self.stack.push(VT, val);
    }

    inline fn pushValue(self: *Runtime, val: Value) !void {
        try self.stack.pushValue(val);
    }

    inline fn pushBool(self: *Runtime, b: bool) !void {
        try self.push(.i32, if (b) 1 else 0);
    }

    inline fn pop(self: *Runtime, comptime VT: ValType) Value.matchingType(VT) {
        return self.stack.pop(VT) catch unreachable;
    }

    inline fn popValue(self: *Runtime) Value {
        return self.stack.popValue() catch unreachable;
    }

    fn popValues(self: *Runtime, comptime VT: ValType, comptime N: comptime_int) [N]Value.matchingType(VT) {
        return self.stack.staticPopValues(VT, N);
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

    fn superConstReturn(self: *Runtime, comptime VT: ValType, imm: Value.matchingType(VT), pc: *usize) !bool {
        try self.push(VT, imm);
        const frame = try self.getCurrentFrame();

        if (frame.return_pc) |return_pc| {
            const len = self.stack.top;
            const results_start = len - 1;
            @memmove(self.stack.values[frame.base_ptr .. frame.base_ptr + 1], self.stack.values[results_start..len]);
            @memmove(self.stack.types[frame.base_ptr .. frame.base_ptr + 1], self.stack.types[results_start..len]);
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
        const i = self.pop(.i32);
        const N = @divExact(@typeInfo(T).int.bits, 8);
        const effective_addr = @as(usize, @intCast(@as(u32, @bitCast(i)))) + @as(usize, memarg.offset);
        const mem_inst = &self.store.mems.items[memarg.mem_addr];

        if (effective_addr + N > mem_inst.data.len) {
            return error.MemoryLoadOutOfBounds;
        }

        const bytes = mem_inst.data[effective_addr .. effective_addr + N];
        return std.mem.readInt(T, bytes[0..N], .little);
    }

    fn memStore(self: *Runtime, comptime T: type, memarg: MemArg, val: T) !void {
        const i = self.pop(.i32);
        const N = @divExact(@typeInfo(T).int.bits, 8);
        const effective_addr = @as(usize, @intCast(@as(u32, @bitCast(i)))) + @as(usize, memarg.offset);
        const mem_inst = &self.store.mems.items[memarg.mem_addr];

        if (effective_addr + N > mem_inst.data.len) {
            return error.MemoryStoreOutOfBounds;
        }

        const bytes = mem_inst.data[effective_addr .. effective_addr + N];
        std.mem.writeInt(T, bytes[0..N], val, .little);
    }

    fn truncSat(comptime Dst: type, comptime Src: type, val: Src) Dst {
        if (std.math.isNan(val)) return 0;
        return std.math.clamp(@as(Dst, @intFromFloat(val)), std.math.minInt(Dst), std.math.maxInt(Dst));
    }

    /// Unwind the value stack using pre-computed unwind info,
    /// preserving `arg.arity` result values on top, then jump to `arg.target_pc`.
    fn branchToUnwind(self: *Runtime, pc: *PC, arg: BranchUnwindArg) !void {
        const frame = try self.getCurrentFrame();
        const abs_height = frame.base_ptr + arg.stack_height;
        if (arg.arity > 0) {
            const src_start = self.stack.top - arg.arity;
            @memmove(
                self.stack.values[abs_height .. abs_height + arg.arity],
                self.stack.values[src_start..self.stack.top],
            );
            @memmove(
                self.stack.types[abs_height .. abs_height + arg.arity],
                self.stack.types[src_start..self.stack.top],
            );
        }
        self.stack.top = abs_height + arg.arity;
        pc.* = arg.target_pc;
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
                .br_unwind => |arg| {
                    try self.branchToUnwind(&pc, arg);
                },
                .br_if => |target_pc| {
                    const condition = self.pop(.i32);
                    if (condition != 0) {
                        pc = target_pc;
                    }
                },
                .br_if_unwind => |arg| {
                    const condition = self.pop(.i32);
                    if (condition != 0) {
                        try self.branchToUnwind(&pc, arg);
                    }
                },
                .br_table => |table| {
                    const i: usize = @intCast(@as(u32, @bitCast(self.pop(.i32))));
                    // Last entry is the default; indexed entries are [0..len-2]
                    const indexed_len = if (table.targets.len > 0) table.targets.len - 1 else 0;
                    const entry = if (i < indexed_len) table.targets[i] else table.targets[table.targets.len - 1];
                    try self.branchToUnwind(&pc, .{ .target_pc = entry.target_pc, .stack_height = entry.stack_height, .arity = entry.arity });
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
                            @memmove(self.stack.types[frame.base_ptr .. frame.base_ptr + arity], self.stack.types[results_start..len]);
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
                .call_host => |host_func_addr| {
                    if (host_func_addr >= self.store.funcs.items.len) {
                        return error.InvalidFuncIndex;
                    }

                    const host_func = &self.store.funcs.items[host_func_addr].host;
                    const stack_size_before = self.stack.top;
                    const func_type = host_func.type;
                    const expected_stack_size_after = stack_size_before + func_type.results.len - func_type.params.len;

                    try host_func.code(@ptrCast(self));

                    if (builtin.mode == .Debug) {
                        // validate that host func returned the expected number of results and that they are of the expected types
                        if (self.stack.top != expected_stack_size_after) {
                            return error.InvalidHostFuncReturnCount;
                        }

                        for (func_type.results, 0..) |result_type, i| {
                            if (self.stack.types[stack_size_before + i] != result_type) {
                                return error.InvalidHostFuncReturnType;
                            }
                        }
                    }
                },
                .call_indirect => |call| {
                    const i: usize = @intCast(@as(u32, @bitCast(self.pop(.i32))));
                    const table_inst = &self.store.tables.items[call.table_addr];

                    if (i >= table_inst.elem.len) {
                        return error.InvalidIndirectCallIndex;
                    }

                    if (Value.staticDecode(.funcref, table_inst.elem[i])) |func_addr| {
                        const func_inst = self.store.funcs.items[func_addr];

                        if (!func_inst.getType().eql(call.func_type.*)) {
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
                .super_i32_eqz_br_if => |target| {
                    const condition = self.pop(.i32);
                    if (condition == 0) {
                        pc = target;
                    }
                },
                .super_i32_eq_br_if => |target| {
                    const args = self.popValues(.i32, 2);
                    if (args[0] == args[1]) {
                        pc = target;
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
                    try self.push(.i32, lhs +% rhs);
                },
                .super_local_get_local_get_i32_mul => |arg| {
                    const lhs = (try self.getLocal(arg.lhs)).i32;
                    const rhs = (try self.getLocal(arg.rhs)).i32;
                    try self.push(.i32, lhs *% rhs);
                },
                .super_local_get_i32_const_i32_add => |arg| {
                    const lhs = (try self.getLocal(arg.local)).i32;
                    try self.push(.i32, lhs +% arg.imm);
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
                    if (try self.superConstReturn(.i32, imm, &pc)) return;
                },
                .super_i64_const_return => |imm| {
                    if (try self.superConstReturn(.i64, imm, &pc)) return;
                },
                .super_f32_const_return => |imm| {
                    if (try self.superConstReturn(.f32, imm, &pc)) return;
                },
                .super_f64_const_return => |imm| {
                    if (try self.superConstReturn(.f64, imm, &pc)) return;
                },
                .super_duplicate => |count| {
                    const last_val_idx = self.stack.top - 1;
                    const val = self.stack.values[last_val_idx];
                    const val_ty = self.stack.types[last_val_idx];
                    @memset(self.stack.values[self.stack.top..][0..count], val);
                    @memset(self.stack.types[self.stack.top..][0..count], val_ty);
                    self.stack.top += count;
                },
                .drop => {
                    self.stack.top -= 1;
                },
                .select => {
                    const condition = self.pop(.i32);
                    const val2 = try self.stack.popValue();
                    const val1 = try self.stack.popValue();
                    try self.stack.pushValue(if (condition != 0) val1 else val2);
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
                .global_get => |global_addr| {
                    const global_inst = &self.store.globals.items[global_addr];
                    try self.stack.pushValue(global_inst.value);
                },
                .global_set => |global_addr| {
                    const val = self.popValue();
                    const global_inst = &self.store.globals.items[global_addr];
                    std.debug.assert(global_inst.mutable);
                    global_inst.value = val;
                },
                .i32_load => |memarg| {
                    const val = try self.memLoad(i32, memarg);
                    try self.push(.i32, val);
                },
                .i64_load => |memarg| {
                    const val = try self.memLoad(i64, memarg);
                    try self.push(.i64, val);
                },
                .i32_store => |memarg| {
                    const val = self.pop(.i32);
                    try self.memStore(i32, memarg, val);
                },
                .i64_store => |memarg| {
                    const val = self.pop(.i64);
                    try self.memStore(i64, memarg, val);
                },
                .i32_const => |n| {
                    try self.push(.i32, n);
                },
                .i64_const => |n| {
                    try self.push(.i64, n);
                },
                .f32_const => |x| {
                    try self.push(.f32, x);
                },
                .f64_const => |x| {
                    try self.push(.f64, x);
                },
                .i32_eqz => {
                    const val = self.pop(.i32);
                    try self.pushBool(val == 0);
                },
                .i32_eq => {
                    const args = self.popValues(.i32, 2);
                    try self.pushBool(args[0] == args[1]);
                },
                .i32_ne => {
                    const args = self.popValues(.i32, 2);
                    try self.pushBool(args[0] != args[1]);
                },
                .i32_lt_s => {
                    const args = self.popValues(.i32, 2);
                    try self.pushBool(args[0] < args[1]);
                },
                .i32_lt_u => {
                    const args = self.popValues(.i32, 2);
                    const lhs: u32 = @bitCast(args[0]);
                    const rhs: u32 = @bitCast(args[1]);
                    try self.pushBool(lhs < rhs);
                },
                .i32_gt_s => {
                    const args = self.popValues(.i32, 2);
                    try self.pushBool(args[0] > args[1]);
                },
                .i32_gt_u => {
                    const args = self.popValues(.i32, 2);
                    const lhs: u32 = @bitCast(args[0]);
                    const rhs: u32 = @bitCast(args[1]);
                    try self.pushBool(lhs > rhs);
                },
                .i32_le_s => {
                    const args = self.popValues(.i32, 2);
                    try self.pushBool(args[0] <= args[1]);
                },
                .i32_le_u => {
                    const args = self.popValues(.i32, 2);
                    const lhs: u32 = @bitCast(args[0]);
                    const rhs: u32 = @bitCast(args[1]);
                    try self.pushBool(lhs <= rhs);
                },
                .i32_ge_s => {
                    const args = self.popValues(.i32, 2);
                    try self.pushBool(args[0] >= args[1]);
                },
                .i32_ge_u => {
                    const args = self.popValues(.i32, 2);
                    const lhs: u32 = @bitCast(args[0]);
                    const rhs: u32 = @bitCast(args[1]);
                    try self.pushBool(lhs >= rhs);
                },
                .i32_clz => {
                    const val = self.pop(.i32);
                    try self.push(.i32, @clz(val));
                },
                .i32_ctz => {
                    const val = self.pop(.i32);
                    try self.push(.i32, @ctz(val));
                },
                .i32_popcnt => {
                    const val = self.pop(.i32);
                    try self.push(.i32, @popCount(val));
                },
                .i32_add => {
                    const args = self.popValues(.i32, 2);
                    try self.push(.i32, args[0] +% args[1]);
                },
                .i32_sub => {
                    const args = self.popValues(.i32, 2);
                    try self.push(.i32, args[0] -% args[1]);
                },
                .i32_mul => {
                    const args = self.popValues(.i32, 2);
                    try self.push(.i32, args[0] *% args[1]);
                },
                .i32_div_s => {
                    const args = self.popValues(.i32, 2);
                    try self.push(.i32, try intDiv(i32, args[0], args[1]));
                },
                .i32_div_u => {
                    const args = self.popValues(.i32, 2);
                    const lhs: u32 = @bitCast(args[0]);
                    const rhs: u32 = @bitCast(args[1]);
                    try self.push(.i32, @bitCast(try intDiv(u32, lhs, rhs)));
                },
                .i32_rem_s => {
                    const args = self.popValues(.i32, 2);
                    try self.push(.i32, try intRem(i32, args[0], args[1]));
                },
                .i32_rem_u => {
                    const args = self.popValues(.i32, 2);
                    const lhs: u32 = @bitCast(args[0]);
                    const rhs: u32 = @bitCast(args[1]);
                    try self.push(.i32, @bitCast(try intRem(u32, lhs, rhs)));
                },
                .i32_and => {
                    const args = self.popValues(.i32, 2);
                    try self.push(.i32, args[0] & args[1]);
                },
                .i32_or => {
                    const args = self.popValues(.i32, 2);
                    try self.push(.i32, args[0] | args[1]);
                },
                .i32_xor => {
                    const args = self.popValues(.i32, 2);
                    try self.push(.i32, args[0] ^ args[1]);
                },
                .i32_shl => {
                    const args = self.popValues(.i32, 2);
                    try self.push(.i32, intShl(i32, args[0], args[1]));
                },
                .i32_shr_s => {
                    const args = self.popValues(.i32, 2);
                    try self.push(.i32, intShr(i32, args[0], args[1]));
                },
                .i32_shr_u => {
                    const args = self.popValues(.i32, 2);
                    try self.push(.i32, @bitCast(intShr(u32, @as(u32, @bitCast(args[0])), @as(u32, @bitCast(args[1])))));
                },
                .i32_rotl => {
                    const args = self.popValues(.i32, 2);
                    const val: u32 = @bitCast(args[0]);
                    const shift = @as(u32, @bitCast(args[1])) & 31;
                    try self.push(.i32, @bitCast(std.math.rotl(u32, val, shift)));
                },
                .i32_rotr => {
                    const args = self.popValues(.i32, 2);
                    const val: u32 = @bitCast(args[0]);
                    const shift = @as(u32, @bitCast(args[1])) & 31;
                    try self.push(.i32, @bitCast(std.math.rotr(u32, val, shift)));
                },
                .i32_wrap_i64 => {
                    const val = self.pop(.i64);
                    try self.push(.i32, @truncate(val));
                },
                .f32_load => |memarg| {
                    const bits = try self.memLoad(u32, memarg);
                    try self.push(.f32, @bitCast(bits));
                },
                .f64_load => |memarg| {
                    const bits = try self.memLoad(u64, memarg);
                    try self.push(.f64, @bitCast(bits));
                },
                .i32_load8_s => |memarg| {
                    const val = try self.memLoad(i8, memarg);
                    try self.push(.i32, @intCast(val));
                },
                .i32_load8_u => |memarg| {
                    const val = try self.memLoad(u8, memarg);
                    try self.push(.i32, @intCast(val));
                },
                .i32_load16_s => |memarg| {
                    const val = try self.memLoad(i16, memarg);
                    try self.push(.i32, @intCast(val));
                },
                .i32_load16_u => |memarg| {
                    const val = try self.memLoad(u16, memarg);
                    try self.push(.i32, @intCast(val));
                },
                .i64_load8_s => |memarg| {
                    const val = try self.memLoad(i8, memarg);
                    try self.push(.i64, @intCast(val));
                },
                .i64_load8_u => |memarg| {
                    const val = try self.memLoad(u8, memarg);
                    try self.push(.i64, @intCast(val));
                },
                .i64_load16_s => |memarg| {
                    const val = try self.memLoad(i16, memarg);
                    try self.push(.i64, @intCast(val));
                },
                .i64_load16_u => |memarg| {
                    const val = try self.memLoad(u16, memarg);
                    try self.push(.i64, @intCast(val));
                },
                .i64_load32_s => |memarg| {
                    const val = try self.memLoad(i32, memarg);
                    try self.push(.i64, @intCast(val));
                },
                .i64_load32_u => |memarg| {
                    const val = try self.memLoad(u32, memarg);
                    try self.push(.i64, @intCast(val));
                },
                .f32_store => |memarg| {
                    const val = self.pop(.f32);
                    try self.memStore(u32, memarg, @bitCast(val));
                },
                .f64_store => |memarg| {
                    const val = self.pop(.f64);
                    try self.memStore(u64, memarg, @bitCast(val));
                },
                .i32_store8 => |memarg| {
                    const val = self.pop(.i32);
                    try self.memStore(u8, memarg, @truncate(@as(u32, @bitCast(val))));
                },
                .i32_store16 => |memarg| {
                    const val = self.pop(.i32);
                    try self.memStore(u16, memarg, @truncate(@as(u32, @bitCast(val))));
                },
                .i64_store8 => |memarg| {
                    const val = self.pop(.i64);
                    try self.memStore(u8, memarg, @truncate(@as(u64, @bitCast(val))));
                },
                .i64_store16 => |memarg| {
                    const val = self.pop(.i64);
                    try self.memStore(u16, memarg, @truncate(@as(u64, @bitCast(val))));
                },
                .i64_store32 => |memarg| {
                    const val = self.pop(.i64);
                    try self.memStore(u32, memarg, @truncate(@as(u64, @bitCast(val))));
                },
                .memory_size => |mem_addr| {
                    const mem_inst = &self.store.mems.items[mem_addr];
                    const size: i32 = @intCast(mem_inst.data.len / page_size);
                    try self.push(.i32, size);
                },
                .memory_grow => |mem_addr| {
                    const n: u32 = @bitCast(self.pop(.i32));
                    const mem_inst = &self.store.mems.items[mem_addr];
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
                        const new_data = self.store.allocator.realloc(mem_inst.data, new_byte_size) catch break :grow;
                        @memset(new_data[old_len..], 0);
                        mem_inst.data = new_data;
                        result = @bitCast(old_pages);
                    }

                    try self.push(.i32, result);
                },
                .memory_init => |_| {
                    return error.MemoryInitNotImplemented;
                },
                .data_drop => |_| {
                    return error.DataDropNotImplemented;
                },
                .memory_copy => |arg| {
                    const src_mem = &self.store.mems.items[arg.src_mem];
                    const dst_mem = &self.store.mems.items[arg.dst_mem];
                    const n: usize = @intCast(@as(u32, @bitCast(self.pop(.i32))));
                    const src_start: usize = @intCast(@as(u32, @bitCast(self.pop(.i32))));
                    const dst_start: usize = @intCast(@as(u32, @bitCast(self.pop(.i32))));
                    const src_end = src_start + n;
                    const dst_end = dst_start + n;

                    if (src_end > src_mem.data.len or
                        dst_end > dst_mem.data.len)
                    {
                        return error.MemoryCopyOutOfBounds;
                    }

                    if (n != 0) {
                        const dst_slice = dst_mem.data[dst_start..dst_end];
                        const src_slice = src_mem.data[src_start..src_end];

                        if (arg.src_mem == arg.dst_mem) {
                            @memmove(dst_slice, src_slice);
                        } else {
                            @memcpy(dst_slice, src_slice);
                        }
                    }
                },
                .memory_fill => |mem_addr| {
                    // Stack (bottom to top): d (dest), val (byte), n (count)
                    const n: usize = @intCast(@as(u32, @bitCast(self.pop(.i32))));
                    const val: u8 = @truncate(@as(u32, @bitCast(self.pop(.i32))));
                    const d: usize = @intCast(@as(u32, @bitCast(self.pop(.i32))));
                    const mem_inst = &self.store.mems.items[mem_addr];
                    if (n != 0) {
                        if (d + n > mem_inst.data.len) {
                            return error.MemoryFillOutOfBounds;
                        }
                        @memset(mem_inst.data[d .. d + n], val);
                    }
                },
                .i64_eqz => {
                    const val = self.pop(.i64);
                    try self.pushBool(val == 0);
                },
                .i64_eq => {
                    const args = self.popValues(.i64, 2);
                    try self.pushBool(args[0] == args[1]);
                },
                .i64_ne => {
                    const args = self.popValues(.i64, 2);
                    try self.pushBool(args[0] != args[1]);
                },
                .i64_lt_s => {
                    const args = self.popValues(.i64, 2);
                    try self.pushBool(args[0] < args[1]);
                },
                .i64_lt_u => {
                    const args = self.popValues(.i64, 2);
                    const lhs: u64 = @bitCast(args[0]);
                    const rhs: u64 = @bitCast(args[1]);
                    try self.pushBool(lhs < rhs);
                },
                .i64_gt_s => {
                    const args = self.popValues(.i64, 2);
                    try self.pushBool(args[0] > args[1]);
                },
                .i64_gt_u => {
                    const args = self.popValues(.i64, 2);
                    const lhs: u64 = @bitCast(args[0]);
                    const rhs: u64 = @bitCast(args[1]);
                    try self.pushBool(lhs > rhs);
                },
                .i64_le_s => {
                    const args = self.popValues(.i64, 2);
                    try self.pushBool(args[0] <= args[1]);
                },
                .i64_le_u => {
                    const args = self.popValues(.i64, 2);
                    const lhs: u64 = @bitCast(args[0]);
                    const rhs: u64 = @bitCast(args[1]);
                    try self.pushBool(lhs <= rhs);
                },
                .i64_ge_s => {
                    const args = self.popValues(.i64, 2);
                    try self.pushBool(args[0] >= args[1]);
                },
                .i64_ge_u => {
                    const args = self.popValues(.i64, 2);
                    const lhs: u64 = @bitCast(args[0]);
                    const rhs: u64 = @bitCast(args[1]);
                    try self.pushBool(lhs >= rhs);
                },
                .f32_eq => {
                    const args = self.popValues(.f32, 2);
                    try self.pushBool(args[0] == args[1]);
                },
                .f32_ne => {
                    const args = self.popValues(.f32, 2);
                    try self.pushBool(args[0] != args[1]);
                },
                .f32_lt => {
                    const args = self.popValues(.f32, 2);
                    try self.pushBool(args[0] < args[1]);
                },
                .f32_gt => {
                    const args = self.popValues(.f32, 2);
                    try self.pushBool(args[0] > args[1]);
                },
                .f32_le => {
                    const args = self.popValues(.f32, 2);
                    try self.pushBool(args[0] <= args[1]);
                },
                .f32_ge => {
                    const args = self.popValues(.f32, 2);
                    try self.pushBool(args[0] >= args[1]);
                },
                .f64_eq => {
                    const args = self.popValues(.f64, 2);
                    try self.pushBool(args[0] == args[1]);
                },
                .f64_ne => {
                    const args = self.popValues(.f64, 2);
                    try self.pushBool(args[0] != args[1]);
                },
                .f64_lt => {
                    const args = self.popValues(.f64, 2);
                    try self.pushBool(args[0] < args[1]);
                },
                .f64_gt => {
                    const args = self.popValues(.f64, 2);
                    try self.pushBool(args[0] > args[1]);
                },
                .f64_le => {
                    const args = self.popValues(.f64, 2);
                    try self.pushBool(args[0] <= args[1]);
                },
                .f64_ge => {
                    const args = self.popValues(.f64, 2);
                    try self.pushBool(args[0] >= args[1]);
                },
                .i64_clz => {
                    const val = self.pop(.i64);
                    try self.push(.i64, @clz(val));
                },
                .i64_ctz => {
                    const val = self.pop(.i64);
                    try self.push(.i64, @ctz(val));
                },
                .i64_popcnt => {
                    const val = self.pop(.i64);
                    try self.push(.i64, @popCount(val));
                },
                .i64_add => {
                    const args = self.popValues(.i64, 2);
                    try self.push(.i64, args[0] +% args[1]);
                },
                .i64_sub => {
                    const args = self.popValues(.i64, 2);
                    try self.push(.i64, args[0] -% args[1]);
                },
                .i64_mul => {
                    const args = self.popValues(.i64, 2);
                    try self.push(.i64, args[0] *% args[1]);
                },
                .i64_div_s => {
                    const args = self.popValues(.i64, 2);
                    try self.push(.i64, try intDiv(i64, args[0], args[1]));
                },
                .i64_div_u => {
                    const args = self.popValues(.i64, 2);
                    const lhs: u64 = @bitCast(args[0]);
                    const rhs: u64 = @bitCast(args[1]);
                    try self.push(.i64, @bitCast(try intDiv(u64, lhs, rhs)));
                },
                .i64_rem_s => {
                    const args = self.popValues(.i64, 2);
                    try self.push(.i64, try intRem(i64, args[0], args[1]));
                },
                .i64_rem_u => {
                    const args = self.popValues(.i64, 2);
                    const lhs: u64 = @bitCast(args[0]);
                    const rhs: u64 = @bitCast(args[1]);
                    try self.push(.i64, @bitCast(try intRem(u64, lhs, rhs)));
                },
                .i64_and => {
                    const args = self.popValues(.i64, 2);
                    try self.push(.i64, args[0] & args[1]);
                },
                .i64_or => {
                    const args = self.popValues(.i64, 2);
                    try self.push(.i64, args[0] | args[1]);
                },
                .i64_xor => {
                    const args = self.popValues(.i64, 2);
                    try self.push(.i64, args[0] ^ args[1]);
                },
                .i64_shl => {
                    const args = self.popValues(.i64, 2);
                    try self.push(.i64, intShl(i64, args[0], args[1]));
                },
                .i64_shr_s => {
                    const args = self.popValues(.i64, 2);
                    try self.push(.i64, intShr(i64, args[0], args[1]));
                },
                .i64_shr_u => {
                    const args = self.popValues(.i64, 2);
                    try self.push(.i64, @bitCast(intShr(u64, @as(u64, @bitCast(args[0])), @as(u64, @bitCast(args[1])))));
                },
                .i64_rotl => {
                    const args = self.popValues(.i64, 2);
                    const val: u64 = @bitCast(args[0]);
                    const shift = @as(u64, @bitCast(args[1])) & 63;
                    try self.push(.i64, @bitCast(std.math.rotl(u64, val, shift)));
                },
                .i64_rotr => {
                    const args = self.popValues(.i64, 2);
                    const val: u64 = @bitCast(args[0]);
                    const shift = @as(u64, @bitCast(args[1])) & 63;
                    try self.push(.i64, @bitCast(std.math.rotr(u64, val, shift)));
                },
                .f32_abs => {
                    const val = self.pop(.f32);
                    try self.push(.f32, @abs(val));
                },
                .f32_neg => {
                    const val = self.pop(.f32);
                    try self.push(.f32, -val);
                },
                .f32_ceil => {
                    const val = self.pop(.f32);
                    try self.push(.f32, @ceil(val));
                },
                .f32_floor => {
                    const val = self.pop(.f32);
                    try self.push(.f32, @floor(val));
                },
                .f32_trunc => {
                    const val = self.pop(.f32);
                    try self.push(.f32, @trunc(val));
                },
                .f32_nearest => {
                    const val = self.pop(.f32);
                    try self.push(.f32, @round(val));
                },
                .f32_sqrt => {
                    const val = self.pop(.f32);
                    try self.push(.f32, @sqrt(val));
                },
                .f32_add => {
                    const args = self.popValues(.f32, 2);
                    try self.push(.f32, args[0] + args[1]);
                },
                .f32_sub => {
                    const args = self.popValues(.f32, 2);
                    try self.push(.f32, args[0] - args[1]);
                },
                .f32_mul => {
                    const args = self.popValues(.f32, 2);
                    try self.push(.f32, args[0] * args[1]);
                },
                .f32_div => {
                    const args = self.popValues(.f32, 2);
                    try self.push(.f32, args[0] / args[1]);
                },
                .f32_min => {
                    const args = self.popValues(.f32, 2);
                    try self.push(.f32, @min(args[0], args[1]));
                },
                .f32_max => {
                    const args = self.popValues(.f32, 2);
                    try self.push(.f32, @max(args[0], args[1]));
                },
                .f32_copysign => {
                    const args = self.popValues(.f32, 2);
                    try self.push(.f32, floatCopysign(f32, args[0], args[1]));
                },
                .f64_abs => {
                    const val = self.pop(.f64);
                    try self.push(.f64, @abs(val));
                },
                .f64_neg => {
                    const val = self.pop(.f64);
                    try self.push(.f64, -val);
                },
                .f64_ceil => {
                    const val = self.pop(.f64);
                    try self.push(.f64, @ceil(val));
                },
                .f64_floor => {
                    const val = self.pop(.f64);
                    try self.push(.f64, @floor(val));
                },
                .f64_trunc => {
                    const val = self.pop(.f64);
                    try self.push(.f64, @trunc(val));
                },
                .f64_nearest => {
                    const val = self.pop(.f64);
                    try self.push(.f64, @round(val));
                },
                .f64_sqrt => {
                    const val = self.pop(.f64);
                    try self.push(.f64, @sqrt(val));
                },
                .f64_add => {
                    const args = self.popValues(.f64, 2);
                    try self.push(.f64, args[0] + args[1]);
                },
                .f64_sub => {
                    const args = self.popValues(.f64, 2);
                    try self.push(.f64, args[0] - args[1]);
                },
                .f64_mul => {
                    const args = self.popValues(.f64, 2);
                    try self.push(.f64, args[0] * args[1]);
                },
                .f64_div => {
                    const args = self.popValues(.f64, 2);
                    try self.push(.f64, args[0] / args[1]);
                },
                .f64_min => {
                    const args = self.popValues(.f64, 2);
                    try self.push(.f64, @min(args[0], args[1]));
                },
                .f64_max => {
                    const args = self.popValues(.f64, 2);
                    try self.push(.f64, @max(args[0], args[1]));
                },
                .f64_copysign => {
                    const args = self.popValues(.f64, 2);
                    try self.push(.f64, floatCopysign(f64, args[0], args[1]));
                },
                .i32_trunc_f32_s => {
                    try self.push(.i32, try truncFloat(i32, f32, self.pop(.f32)));
                },
                .i32_trunc_f32_u => {
                    try self.push(.i32, @bitCast(try truncFloat(u32, f32, self.pop(.f32))));
                },
                .i32_trunc_f64_s => {
                    try self.push(.i32, try truncFloat(i32, f64, self.pop(.f64)));
                },
                .i32_trunc_f64_u => {
                    try self.push(.i32, @bitCast(try truncFloat(u32, f64, self.pop(.f64))));
                },
                .i64_extend_i32_s => {
                    try self.push(.i64, intExtend(i64, i32, self.pop(.i32)));
                },
                .i64_extend_i32_u => {
                    try self.push(.i64, intExtend(i64, u32, self.pop(.i32)));
                },
                .i64_trunc_f32_s => {
                    try self.push(.i64, try truncFloat(i64, f32, self.pop(.f32)));
                },
                .i64_trunc_f32_u => {
                    try self.push(.i64, @bitCast(try truncFloat(u64, f32, self.pop(.f32))));
                },
                .i64_trunc_f64_s => {
                    try self.push(.i64, try truncFloat(i64, f64, self.pop(.f64)));
                },
                .i64_trunc_f64_u => {
                    try self.push(.i64, @bitCast(try truncFloat(u64, f64, self.pop(.f64))));
                },
                .f32_convert_i32_s => {
                    const v = self.pop(.i32);
                    try self.push(.f32, @floatFromInt(v));
                },
                .f32_convert_i32_u => {
                    const v: u32 = @bitCast(self.pop(.i32));
                    try self.push(.f32, @floatFromInt(v));
                },
                .f32_convert_i64_s => {
                    const v = self.pop(.i64);
                    try self.push(.f32, @floatFromInt(v));
                },
                .f32_convert_i64_u => {
                    const v: u64 = @bitCast(self.pop(.i64));
                    try self.push(.f32, @floatFromInt(v));
                },
                .f64_convert_i32_s => {
                    const v = self.pop(.i32);
                    try self.push(.f64, @floatFromInt(v));
                },
                .f64_convert_i32_u => {
                    const v: u32 = @bitCast(self.pop(.i32));
                    try self.push(.f64, @floatFromInt(v));
                },
                .f64_convert_i64_s => {
                    const v = self.pop(.i64);
                    try self.push(.f64, @floatFromInt(v));
                },
                .f64_convert_i64_u => {
                    const v: u64 = @bitCast(self.pop(.i64));
                    try self.push(.f64, @floatFromInt(v));
                },
                .f32_demote_f64 => {
                    const v = self.pop(.f64);
                    try self.push(.f32, @floatCast(v));
                },
                .f64_promote_f32 => {
                    const v = self.pop(.f32);
                    try self.push(.f64, @floatCast(v));
                },
                .i32_reinterpret_f32 => {
                    const v = self.pop(.f32);
                    try self.push(.i32, @bitCast(v));
                },
                .i64_reinterpret_f64 => {
                    const v = self.pop(.f64);
                    try self.push(.i64, @bitCast(v));
                },
                .f32_reinterpret_i32 => {
                    const v = self.pop(.i32);
                    try self.push(.f32, @bitCast(v));
                },
                .f64_reinterpret_i64 => {
                    const v = self.pop(.i64);
                    try self.push(.f64, @bitCast(v));
                },
                .i32_extend8_s => {
                    try self.push(.i32, intExtend(i32, i8, self.pop(.i32)));
                },
                .i32_extend16_s => {
                    try self.push(.i32, intExtend(i32, i16, self.pop(.i32)));
                },
                .i64_extend8_s => {
                    try self.push(.i64, intExtend(i64, i8, self.pop(.i64)));
                },
                .i64_extend16_s => {
                    try self.push(.i64, intExtend(i64, i16, self.pop(.i64)));
                },
                .i64_extend32_s => {
                    try self.push(.i64, intExtend(i64, i32, self.pop(.i64)));
                },
                .i32_trunc_sat_f32_s => {
                    try self.push(.i32, truncSat(i32, f32, self.pop(.f32)));
                },
                .i32_trunc_sat_f32_u => {
                    try self.push(.i32, @bitCast(truncSat(u32, f32, self.pop(.f32))));
                },
                .i32_trunc_sat_f64_s => {
                    try self.push(.i32, truncSat(i32, f64, self.pop(.f64)));
                },
                .i32_trunc_sat_f64_u => {
                    try self.push(.i32, @bitCast(truncSat(u32, f64, self.pop(.f64))));
                },
                .i64_trunc_sat_f32_s => {
                    try self.push(.i64, truncSat(i64, f32, self.pop(.f32)));
                },
                .i64_trunc_sat_f32_u => {
                    try self.push(.i64, @bitCast(truncSat(u64, f32, self.pop(.f32))));
                },
                .i64_trunc_sat_f64_s => {
                    try self.push(.i64, truncSat(i64, f64, self.pop(.f64)));
                },
                .i64_trunc_sat_f64_u => {
                    try self.push(.i64, @bitCast(truncSat(u64, f64, self.pop(.f64))));
                },
                .ref_null => |ref_type| {
                    switch (ref_type) {
                        .funcref => {
                            try self.push(.funcref, null);
                        },
                        .externref => {
                            try self.push(.externref, null);
                        },
                    }
                },
                .ref_is_null => {
                    const val = self.popValue();
                    const is_null: bool = switch (val) {
                        .funcref => |r| r == null,
                        .externref => |r| r == null,
                        else => false,
                    };

                    try self.pushBool(is_null);
                },
                .ref_func => |func_idx| {
                    try self.push(.funcref, func_idx);
                },
                .table_get => |table_idx| {
                    const table_inst = &self.store.tables.items[table_idx];
                    const elem_idx: usize = @as(u32, @bitCast(self.pop(.i32)));

                    if (elem_idx >= table_inst.elem.len) {
                        return error.TableGetOutOfBounds;
                    }

                    const ref = try table_inst.getElem(elem_idx);
                    try self.pushValue(ref);
                },
                .table_set => |table_idx| {
                    const table_inst = &self.store.tables.items[table_idx];
                    const ref = self.popValue();
                    const elem_idx: usize = @as(u32, @bitCast(self.pop(.i32)));

                    if (elem_idx >= table_inst.elem.len) {
                        return error.TableSetOutOfBounds;
                    }

                    try table_inst.setElem(elem_idx, ref);
                },
                .table_init => |arg| {
                    const args = self.popValues(.i32, 3);
                    const dst: usize = @as(u32, @bitCast(args[0]));
                    const src: usize = @as(u32, @bitCast(args[1]));
                    const count: usize = @as(u32, @bitCast(args[2]));
                    try self.store.initTable(arg.table_addr, arg.elem_addr, dst, src, count);
                },
                .elem_drop => |elem_addr| {
                    var elem_inst = &self.store.elems.items[elem_addr];
                    elem_inst.deinit(self.allocator);
                },
                .table_copy => |arg| {
                    const count: usize = @as(u32, @bitCast(self.pop(.i32)));
                    const src: usize = @as(u32, @bitCast(self.pop(.i32)));
                    const dst: usize = @as(u32, @bitCast(self.pop(.i32)));
                    if (count != 0) {
                        if (arg.src_table_addr == arg.dst_table_addr) {
                            const table_inst = &self.store.tables.items[arg.dst_table_addr];
                            if (src + count > table_inst.elem.len or dst + count > table_inst.elem.len) {
                                return error.TableCopyOutOfBounds;
                            }
                            @memmove(table_inst.elem[dst .. dst + count], table_inst.elem[src .. src + count]);
                        } else {
                            const src_table = &self.store.tables.items[arg.src_table_addr];
                            const dst_table = &self.store.tables.items[arg.dst_table_addr];
                            if (src + count > src_table.elem.len or dst + count > dst_table.elem.len) {
                                return error.TableCopyOutOfBounds;
                            }
                            @memcpy(dst_table.elem[dst .. dst + count], src_table.elem[src .. src + count]);
                        }
                    }
                },
                .table_grow => |table_addr| {
                    const n: u32 = @bitCast(self.pop(.i32));
                    const val = self.popValue();
                    const table_inst = &self.store.tables.items[table_addr];
                    const old_len = table_inst.elem.len;
                    const new_len = old_len + n;
                    const result: i32 = grow: {
                        if (table_inst.max) |max| {
                            if (new_len > max) break :grow -1;
                        }
                        const new_elem = self.store.allocator.realloc(table_inst.elem, new_len) catch break :grow -1;
                        @memset(new_elem[old_len..], val.encode());
                        table_inst.elem = new_elem;
                        break :grow @bitCast(@as(u32, @truncate(old_len)));
                    };
                    try self.push(.i32, result);
                },
                .table_size => |table_addr| {
                    const table_inst = &self.store.tables.items[table_addr];
                    try self.push(.i32, @bitCast(@as(u32, @truncate(table_inst.elem.len))));
                },
                .table_fill => |table_addr| {
                    const n: usize = @as(u32, @bitCast(self.pop(.i32)));
                    const val = self.popValue();
                    const dst: usize = @as(u32, @bitCast(self.pop(.i32)));
                    const table_inst = &self.store.tables.items[table_addr];
                    if (n != 0) {
                        if (dst + n > table_inst.elem.len) {
                            return error.TableFillOutOfBounds;
                        }
                        @memset(table_inst.elem[dst .. dst + n], val.encode());
                    }
                },
            }
        }
    }
};
