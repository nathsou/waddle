const std = @import("std");
const types = @import("types.zig");
const parse = @import("parse.zig");
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

const CallIndirectArg = struct {
    func_type: types.FuncType,
    table: *const TableInstance,
};

pub const FlatInstr = union(enum) {
    // Control instructions
    @"unreachable",
    nop,
    br: PC,
    br_if: PC,
    br_table: struct { label_indices: []PC, default_idx: PC },
    @"return": usize, // number of values to return
    call: struct { entry_pc: PC, arguments: usize },
    call_indirect: CallIndirectArg,
    call_host: *const HostFunc,

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
    memory_grow: *const MemoryInstance,

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
};

pub const BlockLabelKind = enum { block, loop, @"if" };
pub const BlockLabel = struct {
    kind: BlockLabelKind,
    start: PC,
    end: PC,
    branches_to_patch: ArrayList(usize),

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
        allocator.free(self.instrs);
        allocator.free(self.functions);
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
        for (label.branches_to_patch.items) |branch_idx| {
            switch (self.flat.items[branch_idx]) {
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
                try self.block_labels.items[exit_label_idx].branches_to_patch.append(self.allocator, self.flat.items.len);
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
                        try label.branches_to_patch.append(self.allocator, patch_idx);
                        try self.emit(switch (instr) {
                            .br => .{ .br = 0 },
                            .br_if => .{ .br_if = 0 },
                            else => unreachable,
                        });
                    },
                }
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
            else => {
                std.debug.print("{any}\n", .{instr});
                return error.UnhandledInstructionForLowering;
            },
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

const initial_stack_capacity: usize = 256;
const initial_call_stack_capacity: usize = 256;

pub const Runtime = struct {
    allocator: Allocator,
    store: Store,
    bytecode: Bytecode,
    stack: ArrayList(Value),
    call_stack: ArrayList(Frame),
    module: *ModuleInstance,
    start_func_addr: ?FuncAddr,

    pub fn init(allocator: Allocator, store: Store, module: *ModuleInstance, start_func_addr: ?FuncAddr) !Runtime {
        var lowering = try BytecodeLowering.init(allocator, &store);
        defer lowering.deinit();

        return Runtime{
            .allocator = allocator,
            .store = store,
            .bytecode = try lowering.lower(),
            .stack = try ArrayList(Value).initCapacity(allocator, initial_stack_capacity),
            .call_stack = try ArrayList(Frame).initCapacity(allocator, initial_call_stack_capacity),
            .start_func_addr = start_func_addr,
            .module = module,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.stack.deinit(self.allocator);
        self.bytecode.deinit(self.allocator);
        self.call_stack.deinit(self.allocator);
        self.module.deinit(self.allocator);
        self.allocator.destroy(self.module);
        self.store.deinit();
    }

    pub fn from(allocator: Allocator, module_path: []const u8) !Runtime {
        var store = Store.init(allocator);

        const file = try std.fs.cwd().openFile(module_path, .{});
        defer file.close();
        const bytes = try file.readToEndAlloc(allocator, 1024 * 1024);
        var parser = parse.Parser.init(allocator, bytes);
        const module = try parser.readModule();
        const module_inst = try store.instantiate(module, &.{});

        var start_func_addr: ?FuncAddr = null;
        if (module.start) |start_func_idx| {
            const start_func_idx_usize = @as(usize, start_func_idx);

            if (start_func_idx_usize >= module_inst.func_addrs.len) {
                return error.InvalidStartFuncIndex;
            }

            start_func_addr = module_inst.func_addrs[start_func_idx_usize];
        }

        return try Runtime.init(allocator, store, module_inst, start_func_addr);
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

        if (self.stack.items.len < func_type.params.len) {
            return error.InvalidArgumentCount;
        }

        const args_start = self.stack.items.len - func_type.params.len;

        for (func_type.params, 0..) |param_type, i| {
            if (self.stack.items[args_start + i].getType() != param_type) {
                return error.InvalidArgumentType;
            }
        }

        switch (func_inst) {
            .wasm => |*wasm_func| {
                const base_ptr = args_start;

                // Locals are initialized by bytecode instructions emitted during lowering
                // Parameters are already on the stack at base_ptr
                try self.call_stack.append(self.allocator, Frame{
                    .base_ptr = base_ptr,
                    .return_pc = null,
                });

                if (self.bytecode.functions[func_addr]) |entry_pc| {
                    try self.execute(entry_pc);
                    var result: []Value = &[_]Value{};
                    if (wasm_func.type.results.len > 0) {
                        result = self.popArgs(wasm_func.type.results.len);
                    }

                    self.stack.shrinkRetainingCapacity(base_ptr);
                    return result;
                } else {
                    return error.FunctionNotFound;
                }
            },
            .host => |host_func| {
                const args = self.stack.items[args_start..];
                const res = try host_func.code(args);
                self.stack.items.len = args_start;
                return res;
            },
        }
    }

    fn push(self: *Runtime, val: Value) !void {
        try self.stack.append(self.allocator, val);
    }

    fn pushBool(self: *Runtime, b: bool) !void {
        try self.push(.{ .i32 = if (b) 1 else 0 });
    }

    fn popArgs(self: *Runtime, n: usize) []Value {
        std.debug.assert(self.stack.items.len >= n);
        const len = self.stack.items.len;
        const slice = self.stack.items[len - n .. len];
        self.stack.items.len -= n;
        return slice;
    }

    fn pop(self: *Runtime) Value {
        std.debug.assert(self.stack.items.len > 0);
        const val = self.stack.items[self.stack.items.len - 1];
        self.stack.items.len -= 1;
        return val;
    }

    fn peek(self: *Runtime) !Value {
        if (self.stack.items.len > 0) {
            return self.stack.items[self.stack.items.len - 1];
        } else {
            return error.ValueStackUnderflow;
        }
    }

    fn getCurrentFrame(self: *Runtime) !*Frame {
        if (self.call_stack.items.len == 0) {
            return error.CallStackUnderflow;
        }

        return &self.call_stack.items[self.call_stack.items.len - 1];
    }

    fn getLocal(self: *Runtime, idx: usize) !Value {
        const frame = try self.getCurrentFrame();
        return self.stack.items[frame.base_ptr + idx];
    }

    fn setLocal(self: *Runtime, idx: usize, val: Value) !void {
        const frame = try self.getCurrentFrame();
        self.stack.items[frame.base_ptr + idx] = val;
    }

    fn memLoad(self: *Runtime, comptime T: type, memarg: MemArg) !T {
        const i = self.pop();
        const N = @divExact(@typeInfo(T).int.bits, 8);
        const effective_addr = @as(usize, @intCast(i.i32)) + @as(usize, memarg.offset);

        if (effective_addr + N >= memarg.mem.data.len) {
            return error.MemoryAccessOutOfBounds;
        }

        const bytes = memarg.mem.data[effective_addr .. effective_addr + N];
        return std.mem.readInt(T, bytes[0..N], .little);
    }

    fn memStore(self: *Runtime, comptime T: type, memarg: MemArg, val: T) !void {
        const i = self.pop();
        const N = @divExact(@typeInfo(T).int.bits, 8);
        const effective_addr = @as(usize, @intCast(i.i32)) + @as(usize, memarg.offset);

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
            // std.debug.print("{any} {any}\n", .{ instr, self.stack.items });

            switch (instr) {
                .@"unreachable" => {
                    return error.Unreachable;
                },
                .nop => {
                    pc += 1;
                },
                .call => |call| {
                    try self.call_stack.append(self.allocator, Frame{
                        .base_ptr = self.stack.items.len - call.arguments,
                        .return_pc = pc + 1,
                    });

                    pc = call.entry_pc;
                },
                .call_indirect => |call| {
                    const i: usize = @intCast(self.pop().i32);

                    if (i >= call.table.elem.len) {
                        return error.InvalidIndirectCallIndex;
                    }

                    if (call.table.elem[i]) |func_addr| {
                        const func_inst = self.store.funcs.items[func_addr];

                        if (!func_inst.getType().eql(call.func_type)) {
                            return error.IndirectCallTypeMismatch;
                        }

                        if (self.bytecode.functions[func_addr]) |entry_pc| {
                            try self.call_stack.append(self.allocator, Frame{
                                .base_ptr = self.stack.items.len - call.func_type.params.len,
                                .return_pc = pc + 1,
                            });

                            pc = entry_pc;
                        } else {
                            return error.FunctionNotFound;
                        }
                    } else {
                        return error.UninitializedTableElement;
                    }
                },
                .@"return" => |arity| {
                    const frame = try self.getCurrentFrame();

                    if (frame.return_pc) |return_pc| {
                        // Keep return values, drop locals for this frame
                        if (arity == 0) {
                            self.stack.items.len = frame.base_ptr;
                        } else {
                            const len = self.stack.items.len;
                            const results_start = len - arity;
                            @memmove(self.stack.items[frame.base_ptr .. frame.base_ptr + arity], self.stack.items[results_start..len]);
                            self.stack.items.len = frame.base_ptr + arity;
                        }

                        pc = return_pc;
                        self.call_stack.items.len -= 1;
                    } else {
                        return; // end execution
                    }
                },
                .br => |target_pc| {
                    pc = target_pc;
                },
                .br_if => |target_pc| {
                    const condition = self.pop();

                    if (condition.i32 != 0) {
                        pc = target_pc;
                    } else {
                        pc += 1;
                    }
                },
                .drop => {
                    self.stack.items.len -= 1;
                    pc += 1;
                },
                .select => {
                    const args = self.popArgs(3);
                    const condition = args[2];
                    try self.push(if (condition.i32 != 0) args[0] else args[1]);
                    pc += 1;
                },
                .local_get => |local_idx| {
                    const val = try self.getLocal(local_idx);
                    try self.push(val);
                    pc += 1;
                },
                .local_set => |local_idx| {
                    const val = self.pop();
                    try self.setLocal(local_idx, val);
                    pc += 1;
                },
                .local_tee => |local_idx| {
                    const val = try self.peek();
                    try self.setLocal(local_idx, val);
                    pc += 1;
                },
                .global_get => |global_inst| {
                    try self.push(global_inst.value);
                    pc += 1;
                },
                .global_set => |global_inst| {
                    const val = self.pop();
                    std.debug.assert(global_inst.mutable);
                    global_inst.value = val;
                    pc += 1;
                },
                .i32_load => |memarg| {
                    const val = try self.memLoad(i32, memarg);
                    try self.push(.{ .i32 = val });
                    pc += 1;
                },
                .i64_load => |memarg| {
                    const val = try self.memLoad(i64, memarg);
                    try self.push(.{ .i64 = val });
                    pc += 1;
                },
                .i32_store => |memarg| {
                    const val = self.pop();
                    try self.memStore(i32, memarg, val.i32);
                    pc += 1;
                },
                .i64_store => |memarg| {
                    const val = self.pop();
                    try self.memStore(i64, memarg, val.i64);
                    pc += 1;
                },
                .i32_const => |n| {
                    try self.push(.{ .i32 = n });
                    pc += 1;
                },
                .i32_eqz => {
                    const val = self.pop();
                    try self.pushBool(val.i32 == 0);
                    pc += 1;
                },
                .i32_eq => {
                    const args = self.popArgs(2);
                    try self.pushBool(args[0].i32 == args[1].i32);
                    pc += 1;
                },
                .i32_and => {
                    const args = self.popArgs(2);
                    try self.push(.{ .i32 = args[0].i32 & args[1].i32 });
                    pc += 1;
                },
                .i32_or => {
                    const args = self.popArgs(2);
                    try self.push(.{ .i32 = args[0].i32 | args[1].i32 });
                    pc += 1;
                },
                .i32_xor => {
                    const args = self.popArgs(2);
                    try self.push(.{ .i32 = args[0].i32 ^ args[1].i32 });
                    pc += 1;
                },
                .i32_add => {
                    const args = self.popArgs(2);
                    try self.push(.{ .i32 = args[0].i32 +% args[1].i32 });
                    pc += 1;
                },
                .i32_sub => {
                    const args = self.popArgs(2);
                    try self.push(.{ .i32 = args[0].i32 -% args[1].i32 });
                    pc += 1;
                },
                .i32_mul => {
                    const args = self.popArgs(2);
                    try self.push(.{ .i32 = args[0].i32 *% args[1].i32 });
                    pc += 1;
                },
                .i32_div_u => {
                    const args = self.popArgs(2);
                    const lhs: u32 = @bitCast(args[0].i32);
                    const rhs: u32 = @bitCast(args[1].i32);

                    if (rhs == 0) {
                        return error.IntegerDivideByZero;
                    }

                    try self.push(.{ .i32 = @bitCast(lhs / rhs) });
                    pc += 1;
                },
                .i32_div_s => {
                    const args = self.popArgs(2);
                    const lhs: i32 = args[0].i32;
                    const rhs: i32 = args[1].i32;

                    if (rhs == 0) {
                        return error.IntegerDivideByZero;
                    }

                    try self.push(.{ .i32 = @divExact(lhs, rhs) });
                    pc += 1;
                },
                .i32_rem_u => {
                    const args = self.popArgs(2);
                    const lhs: u32 = @bitCast(args[0].i32);
                    const rhs: u32 = @bitCast(args[1].i32);

                    if (rhs == 0) {
                        return error.IntegerDivideByZero;
                    }

                    try self.push(.{ .i32 = @bitCast(@rem(lhs, rhs)) });
                    pc += 1;
                },
                .i32_rem_s => {
                    const args = self.popArgs(2);
                    const lhs: i32 = args[0].i32;
                    const rhs: i32 = args[1].i32;

                    if (rhs == 0) {
                        return error.IntegerDivideByZero;
                    }

                    try self.push(.{ .i32 = @rem(lhs, rhs) });
                    pc += 1;
                },
                .i32_shr_u => {
                    const args = self.popArgs(2);
                    const lhs: u32 = @bitCast(args[0].i32);
                    const rhs: u32 = @bitCast(args[1].i32);
                    const shift_amount: u5 = @intCast(rhs);
                    try self.push(.{ .i32 = @bitCast(lhs >> shift_amount) });
                    pc += 1;
                },
                .i32_shr_s => {
                    const args = self.popArgs(2);
                    const lhs = args[0].i32;
                    const rhs: u32 = @bitCast(args[1].i32);
                    const shift_amount: u5 = @intCast(rhs);
                    try self.push(.{ .i32 = lhs >> shift_amount });
                    pc += 1;
                },
                .i32_le_u => {
                    const args = self.popArgs(2);
                    const lhs: u32 = @bitCast(args[0].i32);
                    const rhs: u32 = @bitCast(args[1].i32);
                    try self.pushBool(lhs <= rhs);
                    pc += 1;
                },
                .i32_le_s => {
                    const args = self.popArgs(2);
                    try self.pushBool(args[0].i32 <= args[1].i32);
                    pc += 1;
                },
                .i32_lt_u => {
                    const args = self.popArgs(2);
                    const lhs: u32 = @bitCast(args[0].i32);
                    const rhs: u32 = @bitCast(args[1].i32);
                    try self.pushBool(lhs < rhs);
                    pc += 1;
                },
                .i32_lt_s => {
                    const args = self.popArgs(2);
                    try self.pushBool(args[0].i32 < args[1].i32);
                    pc += 1;
                },
                .i32_gt_u => {
                    const args = self.popArgs(2);
                    const lhs: u32 = @bitCast(args[0].i32);
                    const rhs: u32 = @bitCast(args[1].i32);
                    try self.pushBool(lhs > rhs);
                    pc += 1;
                },
                .i32_gt_s => {
                    const args = self.popArgs(2);
                    try self.pushBool(args[0].i32 > args[1].i32);
                    pc += 1;
                },
                .i32_ge_u => {
                    const args = self.popArgs(2);
                    const lhs: u32 = @bitCast(args[0].i32);
                    const rhs: u32 = @bitCast(args[1].i32);
                    try self.pushBool(lhs >= rhs);
                    pc += 1;
                },
                .i32_ge_s => {
                    const args = self.popArgs(2);
                    try self.pushBool(args[0].i32 >= args[1].i32);
                    pc += 1;
                },
                .i64_const => |n| {
                    try self.push(.{ .i64 = n });
                    pc += 1;
                },
                .f32_const => |x| {
                    try self.push(.{ .f32 = x });
                    pc += 1;
                },
                .f64_const => |x| {
                    try self.push(.{ .f64 = x });
                    pc += 1;
                },
                else => {
                    std.debug.print("Unsupported instruction: {any}\n", .{instr});
                    return error.UnsupportedInstruction;
                },
            }
        }
    }
};
