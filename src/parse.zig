const std = @import("std");
const types = @import("types.zig");

/// Parser for WASM binary format (Core 1.0).
///
/// The returned `types.Module` owns all allocated memory, including the input
/// `wasm_bytes` slice. Call `module.deinit(allocator)` to free everything.
pub const Parser = struct {
    bytes: []const u8,
    valtypes_buf: std.ArrayList(types.ValType),
    index: usize = 0,
    allocator: std.mem.Allocator,

    /// Initialize a new Parser.
    /// The allocator should typically be an ArenaAllocator for simple cleanup.
    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !Parser {
        return Parser{
            .bytes = bytes,
            .valtypes_buf = try .initCapacity(allocator, 64),
            .allocator = allocator,
        };
    }

    // Reader interface (used in readUleb128)
    pub fn readByte(self: *Parser) !types.Byte {
        if (self.index >= self.bytes.len) {
            return error.EndOfInput;
        }

        const byte = self.bytes[self.index];
        self.index += 1;

        return byte;
    }

    pub fn peekByte(self: *Parser) !u8 {
        if (self.index >= self.bytes.len) {
            return error.EndOfInput;
        }

        return self.bytes[self.index];
    }

    fn readUInt(self: *Parser, comptime T: type) !T {
        return std.leb.readUleb128(T, self);
    }

    fn readSInt(self: *Parser, comptime T: type) !T {
        return std.leb.readIleb128(T, self);
    }

    fn readU16(self: *Parser) !u16 {
        return self.readUInt(u16);
    }

    fn readU32(self: *Parser) !u32 {
        return self.readUInt(u32);
    }

    fn readFixedU32(self: *Parser) !u32 {
        if (self.index + 4 > self.bytes.len) {
            return error.EndOfInput;
        }
        const val = std.mem.readInt(u32, self.bytes[self.index..][0..4], .little);
        self.index += 4;
        return val;
    }

    fn readU64(self: *Parser) !u64 {
        return self.readUInt(u64);
    }

    fn readI8(self: *Parser) !i8 {
        return self.readSInt(i8);
    }

    fn readI16(self: *Parser) !i16 {
        return self.readSInt(i16);
    }

    fn readI32(self: *Parser) !i32 {
        return self.readSInt(i32);
    }

    fn readI64(self: *Parser) !i64 {
        return self.readSInt(i64);
    }

    fn readF32(self: *Parser) !f32 {
        const val = std.mem.readInt(u32, self.bytes[self.index..][0..4], .little);
        self.index += 4;
        return @bitCast(val);
    }

    fn readF64(self: *Parser) !f64 {
        const val = std.mem.readInt(u64, self.bytes[self.index..][0..8], .little);
        self.index += 8;
        return @bitCast(val);
    }

    fn readVector(self: *Parser, comptime T: type, decode_fn: *const fn (*Parser) anyerror!T) ![]T {
        const len = try self.readU32();
        const vec = try self.allocator.alloc(T, len);
        errdefer self.allocator.free(vec);

        for (vec) |*item| {
            item.* = try decode_fn(self);
        }

        return vec;
    }

    // reads a vector of ValTypes, but stores them in the parser's valtypes_buf to avoid extra allocations
    fn readValTypeVector(self: *Parser) !types.IndexedSlice(types.ValType) {
        const len = try self.readU32();
        const offset = self.valtypes_buf.items.len;

        for (0..len) |_| {
            try self.valtypes_buf.append(self.allocator, try self.readValType());
        }

        return .{
            .len = @intCast(len),
            .offset = @intCast(offset),
        };
    }

    fn readName(self: *Parser) !types.Name {
        const name_len = try self.readU32();

        if (self.index + name_len > self.bytes.len) {
            return error.EndOfInput;
        }

        const bytes = self.bytes[self.index .. self.index + name_len];
        self.index += name_len;
        return bytes;
    }

    fn readValType(self: *Parser) !types.ValType {
        const n = try self.readByte();

        return switch (n) {
            0x7F => .i32,
            0x7E => .i64,
            0x7D => .f32,
            0x7C => .f64,
            0x70 => .funcref,
            0x6F => .externref,
            else => return error.InvalidValType,
        };
    }

    fn readRefType(self: *Parser) !types.RefType {
        const n = try self.readByte();

        return switch (n) {
            0x70 => .funcref,
            0x6F => .externref,
            else => return error.InvalidRefType,
        };
    }

    fn readBlockType(self: *Parser) !types.BlockType {
        const n = try self.peekByte();

        if (n == 0x40) {
            self.index += 1; // consume the byte
            return .empty;
        }

        switch (n) {
            0x7F, 0x7E, 0x7D, 0x7C, 0x70, 0x6F => {
                const val_type = try self.readValType();
                return .{ .val_type = val_type };
            },
            else => {
                const type_idx = try self.readU32();
                return .{ .type_index = @intCast(type_idx) };
            },
        }
    }

    fn readFuncType(self: *Parser) !types.FuncType {
        const n = try self.readByte();

        if (n != 0x60) {
            return error.InvalidFuncType;
        }

        const params = try self.readValTypeVector();
        const results = try self.readValTypeVector();

        return .{ .params = params, .results = results };
    }

    fn readLimits(self: *Parser) !types.Limits {
        const flag = try self.readByte();
        const min = try self.readU32();

        switch (flag) {
            0x00 => return .{ .min = min, .max = null },
            0x01 => {
                const max = try self.readU32();

                if (max < min) {
                    return error.InvalidLimits;
                }

                return .{ .min = min, .max = max };
            },
            else => return error.InvalidLimits,
        }
    }

    fn readMemType(self: *Parser) !types.MemType {
        const limits = try self.readLimits();

        if (limits.max) |max| {
            if (max > 65536) {
                return error.InvalidMemoryLimits;
            }
        }

        return .{ .limits = limits };
    }

    fn readTableType(self: *Parser) !types.TableType {
        const elem_type = try self.readRefType();
        const limits = try self.readLimits();
        return .{ .elem_type = elem_type, .limits = limits };
    }

    fn readGlobalType(self: *Parser) !types.GlobalType {
        const val_type = try self.readValType();
        const mutable_n = try self.readByte();
        const mutable = switch (mutable_n) {
            0x00 => false,
            0x01 => true,
            else => return error.InvalidGlobalMutability,
        };

        return .{ .val_type = val_type, .mutable = mutable };
    }

    fn readGlobal(self: *Parser) !types.Global {
        const type_ = try self.readGlobalType();
        const init_expr = try self.readExpr();
        return .{ .type = type_, .init = init_expr };
    }

    fn readImport(self: *Parser) !types.Import {
        const module_name = try self.readName();
        const field_name = try self.readName();
        const desc_type = try self.readByte();
        const import_desc: types.ImportDesc = switch (desc_type) {
            0x00 => .{ .func = try self.readU32() },
            0x01 => .{ .table = try self.readTableType() },
            0x02 => .{ .mem = try self.readMemType() },
            0x03 => .{ .global = try self.readGlobalType() },
            else => return error.InvalidImportDesc,
        };

        return .{
            .module = module_name,
            .name = field_name,
            .desc = import_desc,
        };
    }

    fn readExport(self: *Parser) !types.Export {
        const name = try self.readName();
        const desc_type = try self.readByte();
        const export_desc: types.ExportDesc = switch (desc_type) {
            0x00 => .{ .func = try self.readU32() },
            0x01 => .{ .table = try self.readU32() },
            0x02 => .{ .mem = try self.readU32() },
            0x03 => .{ .global = try self.readU32() },
            else => return error.InvalidExportDesc,
        };

        return .{
            .name = name,
            .desc = export_desc,
        };
    }

    fn readElemKind(self: *Parser) !types.RefType {
        const elem_kind = try self.readU32();

        return switch (elem_kind) {
            0x00 => .funcref,
            else => return error.InvalidElemKind,
        };
    }

    fn readElem(self: *Parser) !types.Elem {
        const flags = try self.readU32();

        switch (flags) {
            0 => {
                const offset = try self.readExpr();
                const func_indices: []types.FuncIndex = try self.readVector(types.FuncIndex, readU32);
                return .{
                    .type = .funcref,
                    .init = .{ .func_indices = func_indices },
                    .mode = .{ .active = .{ .table_idx = 0, .offset = offset } },
                };
            },
            1 => {
                const ty = try self.readElemKind();
                const func_indices: []types.FuncIndex = try self.readVector(types.FuncIndex, readU32);
                return .{
                    .type = ty,
                    .init = .{ .func_indices = func_indices },
                    .mode = .passive,
                };
            },
            2 => {
                const table_idx = try self.readU32();
                const offset = try self.readExpr();
                const ty = try self.readElemKind();
                const func_indices: []types.FuncIndex = try self.readVector(types.FuncIndex, readU32);
                return .{
                    .type = ty,
                    .init = .{ .func_indices = func_indices },
                    .mode = .{ .active = .{ .table_idx = table_idx, .offset = offset } },
                };
            },
            3 => {
                const ty = try self.readElemKind();
                const init_func_indices: []types.FuncIndex = try self.readVector(types.FuncIndex, readU32);
                return .{
                    .type = ty,
                    .init = .{ .func_indices = init_func_indices },
                    .mode = .declarative,
                };
            },
            4 => {
                const offset = try self.readExpr();
                const init_exprs: []types.Expr = try self.readVector(types.Expr, readExpr);
                return .{
                    .type = .funcref,
                    .init = .{ .exprs = init_exprs },
                    .mode = .{ .active = .{ .table_idx = 0, .offset = offset } },
                };
            },
            5 => {
                const ty = try self.readRefType();
                const init_exprs: []types.Expr = try self.readVector(types.Expr, readExpr);
                return .{
                    .type = ty,
                    .init = .{ .exprs = init_exprs },
                    .mode = .passive,
                };
            },
            6 => {
                const table_idx = try self.readU32();
                const offset = try self.readExpr();
                const ty = try self.readRefType();
                const init_exprs: []types.Expr = try self.readVector(types.Expr, readExpr);
                return .{
                    .type = ty,
                    .init = .{ .exprs = init_exprs },
                    .mode = .{ .active = .{ .table_idx = table_idx, .offset = offset } },
                };
            },
            7 => {
                const ty = try self.readRefType();
                const init_exprs: []types.Expr = try self.readVector(types.Expr, readExpr);
                return .{
                    .type = ty,
                    .init = .{ .exprs = init_exprs },
                    .mode = .declarative,
                };
            },
            else => return error.InvalidElemFlags,
        }
    }

    fn readLocals(self: *Parser) !types.Locals {
        const count = try self.readU32();
        const val_type = try self.readValType();
        return .{ .count = count, .type = val_type };
    }

    fn readCode(self: *Parser) !types.Code {
        const body_size = try self.readU32();
        const body_end = self.index + @as(usize, body_size);
        const locals = try self.readVector(types.Locals, readLocals);
        const expr = try self.readExpr();

        if (self.index != body_end) {
            return error.InvalidCodeBodySize;
        }

        return .{
            .locals = locals,
            .body = expr,
        };
    }

    fn readData(self: *Parser) !types.Data {
        const mode_n = try self.readU32();

        switch (mode_n) {
            0, 2 => {
                const mem_idx = if (mode_n == 0) 0 else try self.readU32();
                const offset = try self.readExpr();
                const init_bytes = try self.readVector(types.Byte, readByte);
                return types.Data{
                    .init = init_bytes,
                    .mode = types.DataMode{
                        .active = .{
                            .mem_idx = mem_idx,
                            .offset = offset,
                        },
                    },
                };
            },
            1 => {
                const init_bytes = try self.readVector(types.Byte, readByte);
                return types.Data{
                    .init = init_bytes,
                    .mode = .passive,
                };
            },
            else => {
                std.debug.print("Invalid data segment mode: {d}\n", .{mode_n});
                return error.InvalidDataMode;
            },
        }
    }

    const SequenceResult = struct {
        instructions: []types.Instr,
        terminator: u8,
    };

    const else_op_code = 0x05;
    const end_op_code = 0x0B;

    fn readInstructionSequence(self: *Parser, terminators: []const u8) anyerror!SequenceResult {
        var instructions = try std.ArrayList(types.Instr).initCapacity(self.allocator, 32);
        errdefer instructions.deinit(self.allocator);

        while (true) {
            const next_byte = try self.peekByte();

            for (terminators) |t| {
                if (next_byte == t) {
                    self.index += 1; // Consume the terminator
                    return .{ .instructions = try instructions.toOwnedSlice(self.allocator), .terminator = t };
                }
            }

            // It's not a terminator, so it must be an instruction
            const instr = try self.readInstr();
            try instructions.append(self.allocator, instr);
        }
    }

    fn readMemArg(self: *Parser) !types.MemoryInstrArg {
        const alignment = try self.readU32();
        const offset = try self.readU32();
        return .{ .alignment = alignment, .offset = offset };
    }

    fn readInstr(self: *Parser) !types.Instr {
        const opcode = try self.readByte();

        return switch (opcode) {
            0x00 => .@"unreachable",
            0x01 => .nop,
            0x02, 0x03 => |op| {
                const block_type = try self.readBlockType();
                const res = try self.readInstructionSequence(&.{end_op_code});

                if (op == 0x02) {
                    return .{ .block = .{ .block_type = block_type, .instructions = res.instructions } };
                } else {
                    return .{ .loop = .{ .block_type = block_type, .instructions = res.instructions } };
                }
            },
            0x04 => {
                const block_type = try self.readBlockType();

                // Read the "then" block, which can end with 0x0B (end) or 0x05 (else)
                const then_res = try self.readInstructionSequence(&.{ else_op_code, end_op_code });
                const then_instructions = then_res.instructions;
                var else_instructions: []types.Instr = &.{};

                if (then_res.terminator == else_op_code) {
                    const else_res = try self.readInstructionSequence(&.{end_op_code});
                    else_instructions = else_res.instructions;
                }

                return .{
                    .@"if" = .{
                        .block_type = block_type,
                        .then_instructions = then_instructions,
                        .else_instructions = else_instructions,
                    },
                };
            },
            0x0C => {
                const label_idx = try self.readU32();
                return .{ .br = label_idx };
            },
            0x0D => {
                const label_idx = try self.readU32();
                return .{ .br_if = label_idx };
            },
            0x0E => {
                const labels = try self.readVector(types.LabelIndex, readU32);
                const default_idx = try self.readU32();
                return .{ .br_table = .{ .label_indices = labels, .default_idx = default_idx } };
            },
            0x0F => .@"return",
            0x10 => {
                const func_idx = try self.readU32();
                return .{ .call = func_idx };
            },
            0x11 => {
                const type_idx = try self.readU32();
                const table_idx = try self.readU32();
                return .{ .call_indirect = .{ .type_idx = type_idx, .table_idx = table_idx } };
            },
            0x1A => .drop,
            0x1B => .select,
            0x20 => .{ .local_get = try self.readU32() },
            0x21 => .{ .local_set = try self.readU32() },
            0x22 => .{ .local_tee = try self.readU32() },
            0x23 => .{ .global_get = try self.readU32() },
            0x24 => .{ .global_set = try self.readU32() },
            0x25 => .{ .table_get = try self.readU32() },
            0x26 => .{ .table_set = try self.readU32() },
            0x28 => .{ .i32_load = try self.readMemArg() },
            0x29 => .{ .i64_load = try self.readMemArg() },
            0x2A => .{ .f32_load = try self.readMemArg() },
            0x2B => .{ .f64_load = try self.readMemArg() },
            0x2C => .{ .i32_load8_s = try self.readMemArg() },
            0x2D => .{ .i32_load8_u = try self.readMemArg() },
            0x2E => .{ .i32_load16_s = try self.readMemArg() },
            0x2F => .{ .i32_load16_u = try self.readMemArg() },
            0x30 => .{ .i64_load8_s = try self.readMemArg() },
            0x31 => .{ .i64_load8_u = try self.readMemArg() },
            0x32 => .{ .i64_load16_s = try self.readMemArg() },
            0x33 => .{ .i64_load16_u = try self.readMemArg() },
            0x34 => .{ .i64_load32_s = try self.readMemArg() },
            0x35 => .{ .i64_load32_u = try self.readMemArg() },
            0x36 => .{ .i32_store = try self.readMemArg() },
            0x37 => .{ .i64_store = try self.readMemArg() },
            0x38 => .{ .f32_store = try self.readMemArg() },
            0x39 => .{ .f64_store = try self.readMemArg() },
            0x3A => .{ .i32_store8 = try self.readMemArg() },
            0x3B => .{ .i32_store16 = try self.readMemArg() },
            0x3C => .{ .i64_store8 = try self.readMemArg() },
            0x3D => .{ .i64_store16 = try self.readMemArg() },
            0x3E => .{ .i64_store32 = try self.readMemArg() },
            0x3F => {
                const reserved = try self.readByte();

                if (reserved != 0x00) {
                    return error.InvalidMemorySizeInstruction;
                }

                return .{ .memory_size = @intCast(reserved) };
            },
            0x40 => {
                const reserved = try self.readByte();

                if (reserved != 0x00) {
                    return error.InvalidMemoryGrowInstruction;
                }

                return .{ .memory_grow = @intCast(reserved) };
            },
            0x41 => .{ .i32_const = try self.readI32() },
            0x42 => .{ .i64_const = try self.readI64() },
            0x43 => .{ .f32_const = try self.readF32() },
            0x44 => .{ .f64_const = try self.readF64() },
            0x45 => .i32_eqz,
            0x46 => .i32_eq,
            0x47 => .i32_ne,
            0x48 => .i32_lt_s,
            0x49 => .i32_lt_u,
            0x4A => .i32_gt_s,
            0x4B => .i32_gt_u,
            0x4C => .i32_le_s,
            0x4D => .i32_le_u,
            0x4E => .i32_ge_s,
            0x4F => .i32_ge_u,
            0x50 => .i64_eqz,
            0x51 => .i64_eq,
            0x52 => .i64_ne,
            0x53 => .i64_lt_s,
            0x54 => .i64_lt_u,
            0x55 => .i64_gt_s,
            0x56 => .i64_gt_u,
            0x57 => .i64_le_s,
            0x58 => .i64_le_u,
            0x59 => .i64_ge_s,
            0x5A => .i64_ge_u,
            0x5B => .f32_eq,
            0x5C => .f32_ne,
            0x5D => .f32_lt,
            0x5E => .f32_gt,
            0x5F => .f32_le,
            0x60 => .f32_ge,
            0x61 => .f64_eq,
            0x62 => .f64_ne,
            0x63 => .f64_lt,
            0x64 => .f64_gt,
            0x65 => .f64_le,
            0x66 => .f64_ge,
            0x67 => .i32_clz,
            0x68 => .i32_ctz,
            0x69 => .i32_popcnt,
            0x6A => .i32_add,
            0x6B => .i32_sub,
            0x6C => .i32_mul,
            0x6D => .i32_div_s,
            0x6E => .i32_div_u,
            0x6F => .i32_rem_s,
            0x70 => .i32_rem_u,
            0x71 => .i32_and,
            0x72 => .i32_or,
            0x73 => .i32_xor,
            0x74 => .i32_shl,
            0x75 => .i32_shr_s,
            0x76 => .i32_shr_u,
            0x77 => .i32_rotl,
            0x78 => .i32_rotr,
            0x79 => .i64_clz,
            0x7A => .i64_ctz,
            0x7B => .i64_popcnt,
            0x7C => .i64_add,
            0x7D => .i64_sub,
            0x7E => .i64_mul,
            0x7F => .i64_div_s,
            0x80 => .i64_div_u,
            0x81 => .i64_rem_s,
            0x82 => .i64_rem_u,
            0x83 => .i64_and,
            0x84 => .i64_or,
            0x85 => .i64_xor,
            0x86 => .i64_shl,
            0x87 => .i64_shr_s,
            0x88 => .i64_shr_u,
            0x89 => .i64_rotl,
            0x8A => .i64_rotr,
            0x8B => .f32_abs,
            0x8C => .f32_neg,
            0x8D => .f32_ceil,
            0x8E => .f32_floor,
            0x8F => .f32_trunc,
            0x90 => .f32_nearest,
            0x91 => .f32_sqrt,
            0x92 => .f32_add,
            0x93 => .f32_sub,
            0x94 => .f32_mul,
            0x95 => .f32_div,
            0x96 => .f32_min,
            0x97 => .f32_max,
            0x98 => .f32_copysign,
            0x99 => .f64_abs,
            0x9A => .f64_neg,
            0x9B => .f64_ceil,
            0x9C => .f64_floor,
            0x9D => .f64_trunc,
            0x9E => .f64_nearest,
            0x9F => .f64_sqrt,
            0xA0 => .f64_add,
            0xA1 => .f64_sub,
            0xA2 => .f64_mul,
            0xA3 => .f64_div,
            0xA4 => .f64_min,
            0xA5 => .f64_max,
            0xA6 => .f64_copysign,
            0xA7 => .i32_wrap_i64,
            0xA8 => .i32_trunc_f32_s,
            0xA9 => .i32_trunc_f32_u,
            0xAA => .i32_trunc_f64_s,
            0xAB => .i32_trunc_f64_u,
            0xAC => .i64_extend_i32_s,
            0xAD => .i64_extend_i32_u,
            0xAE => .i64_trunc_f32_s,
            0xAF => .i64_trunc_f32_u,
            0xB0 => .i64_trunc_f64_s,
            0xB1 => .i64_trunc_f64_u,
            0xB2 => .f32_convert_i32_s,
            0xB3 => .f32_convert_i32_u,
            0xB4 => .f32_convert_i64_s,
            0xB5 => .f32_convert_i64_u,
            0xB6 => .f32_demote_f64,
            0xB7 => .f64_convert_i32_s,
            0xB8 => .f64_convert_i32_u,
            0xB9 => .f64_convert_i64_s,
            0xBA => .f64_convert_i64_u,
            0xBB => .f64_promote_f32,
            0xBC => .i32_reinterpret_f32,
            0xBD => .i64_reinterpret_f64,
            0xBE => .f32_reinterpret_i32,
            0xBF => .f64_reinterpret_i64,
            0xC0 => .i32_extend8_s,
            0xC1 => .i32_extend16_s,
            0xC2 => .i64_extend8_s,
            0xC3 => .i64_extend16_s,
            0xC4 => .i64_extend32_s,
            0xD0 => {
                const ref_type = try self.readRefType();
                return .{ .ref_null = ref_type };
            },
            0xD1 => {
                return .ref_is_null;
            },
            0xD2 => {
                const func_idx = try self.readU32();
                return .{ .ref_func = func_idx };
            },
            0xFC => {
                const op = try self.readU32();

                switch (op) {
                    0 => {
                        return .i32_trunc_sat_f32_s;
                    },
                    1 => {
                        return .i32_trunc_sat_f32_u;
                    },
                    2 => {
                        return .i32_trunc_sat_f64_s;
                    },
                    3 => {
                        return .i32_trunc_sat_f64_u;
                    },
                    4 => {
                        return .i64_trunc_sat_f32_s;
                    },
                    5 => {
                        return .i64_trunc_sat_f32_u;
                    },
                    6 => {
                        return .i64_trunc_sat_f64_s;
                    },
                    7 => {
                        return .i64_trunc_sat_f64_u;
                    },
                    8 => {
                        const data_idx = try self.readU32();
                        const mem_idx = try self.readU32();
                        return .{ .memory_init = .{ .data_idx = data_idx, .mem_idx = mem_idx } };
                    },
                    9 => {
                        const data_idx = try self.readU32();
                        return .{ .data_drop = data_idx };
                    },
                    10 => {
                        const src_mem_idx = try self.readU32();
                        const dst_mem_idx = try self.readU32();
                        return .{ .memory_copy = .{ .src_mem_idx = src_mem_idx, .dst_mem_idx = dst_mem_idx } };
                    },
                    11 => {
                        const mem_idx = try self.readU32();
                        return .{ .memory_fill = mem_idx };
                    },
                    12 => {
                        const elem_idx = try self.readU32();
                        const table_idx = try self.readU32();
                        return .{ .table_init = .{ .table_idx = table_idx, .elem_idx = elem_idx } };
                    },
                    13 => {
                        const elem_idx = try self.readU32();
                        return .{ .elem_drop = elem_idx };
                    },
                    14 => {
                        const src_table_idx = try self.readU32();
                        const dst_table_idx = try self.readU32();
                        return .{ .table_copy = .{ .src_table_idx = src_table_idx, .dst_table_idx = dst_table_idx } };
                    },
                    15 => {
                        const table_idx = try self.readU32();
                        return .{ .table_grow = table_idx };
                    },
                    16 => {
                        const table_idx = try self.readU32();
                        return .{ .table_size = table_idx };
                    },
                    17 => {
                        const table_idx = try self.readU32();
                        return .{ .table_fill = table_idx };
                    },
                    else => {
                        return error.UnsupportedMiscellaneousOpcode;
                    },
                }
            },
            else => {
                std.debug.print("Unknown opcode: {x}\n", .{opcode});
                return error.InvalidInstruction;
            },
        };
    }

    fn readExpr(self: *Parser) ![]types.Instr {
        return (try self.readInstructionSequence(&.{end_op_code})).instructions;
    }

    fn readSectionSize(self: *Parser, expected_id: u8) !?u32 {
        const next_byte = self.peekByte() catch |err| {
            if (err == error.EndOfInput) return null;
            return err;
        };

        if (next_byte == expected_id) {
            self.index += 1; // Consume ID
            return try self.readU32(); // Consume Size
        }

        return null;
    }

    fn readSectionHeader(self: *Parser, expected_id: u8) !?usize {
        const section_size = try self.readSectionSize(expected_id) orelse return null;
        const end = self.index + @as(usize, section_size);

        if (end > self.bytes.len) {
            return error.EndOfInput;
        }

        return end;
    }

    fn expectSectionEnd(self: *Parser, section_end: usize) !void {
        if (self.index != section_end) {
            return error.InvalidSectionSize;
        }
    }

    fn readCustomSection(self: *Parser, size: u32) !types.CustomSection {
        const section_start = self.index;
        const name = try self.readName();
        const header_size = self.index - section_start;

        if (header_size > size) {
            return error.InvalidSectionSize;
        }

        const content_size = @as(usize, size) - header_size;
        if (self.index + content_size > self.bytes.len) {
            return error.EndOfInput;
        }

        const content = self.bytes[self.index .. self.index + @as(usize, content_size)];
        self.index += @as(usize, content_size);
        return .{ .name = name, .data = content };
    }

    fn readCustomSections(self: *Parser, container: *std.ArrayList(types.CustomSection)) !void {
        while (true) {
            const saved_index = self.index;
            const next_byte = self.peekByte() catch |err| {
                if (err == error.EndOfInput) return;
                return err;
            };

            if (next_byte != 0) {
                // Not a custom section
                self.index = saved_index;
                return;
            }

            self.index += 1; // consume the section id
            const size = try self.readU32();
            const custom_section = try self.readCustomSection(size);
            try container.append(self.allocator, custom_section);
        }
    }

    fn readTypeSection(self: *Parser) ![]types.FuncType {
        const section_end = try self.readSectionHeader(1) orelse return &.{};
        const result = try self.readVector(types.FuncType, readFuncType);
        try self.expectSectionEnd(section_end);
        return result;
    }

    fn readImportSection(self: *Parser) ![]types.Import {
        const section_end = try self.readSectionHeader(2) orelse return &.{};
        const result = try self.readVector(types.Import, readImport);
        try self.expectSectionEnd(section_end);
        return result;
    }

    fn readFunctionSection(self: *Parser) ![]types.FuncIndex {
        const section_end = try self.readSectionHeader(3) orelse return &.{};
        const result = try self.readVector(types.FuncIndex, readU32);
        try self.expectSectionEnd(section_end);
        return result;
    }

    fn readTableSection(self: *Parser) ![]types.TableType {
        const section_end = try self.readSectionHeader(4) orelse return &.{};
        const result = try self.readVector(types.TableType, readTableType);
        try self.expectSectionEnd(section_end);
        return result;
    }

    fn readMemorySection(self: *Parser) ![]types.MemType {
        const section_end = try self.readSectionHeader(5) orelse return &.{};
        const result = try self.readVector(types.MemType, readMemType);
        try self.expectSectionEnd(section_end);
        return result;
    }

    fn readGlobalSection(self: *Parser) ![]types.Global {
        const section_end = try self.readSectionHeader(6) orelse return &.{};
        const result = try self.readVector(types.Global, readGlobal);
        try self.expectSectionEnd(section_end);
        return result;
    }

    fn readExportSection(self: *Parser) ![]types.Export {
        const section_end = try self.readSectionHeader(7) orelse return &.{};
        const result = try self.readVector(types.Export, readExport);
        try self.expectSectionEnd(section_end);
        return result;
    }

    fn readStartSection(self: *Parser) !?types.FuncIndex {
        const section_end = try self.readSectionHeader(8) orelse return null;
        const start = try self.readU32();
        try self.expectSectionEnd(section_end);
        return start;
    }

    fn readElementSection(self: *Parser) ![]types.Elem {
        const section_end = try self.readSectionHeader(9) orelse return &.{};
        const result = try self.readVector(types.Elem, readElem);
        try self.expectSectionEnd(section_end);
        return result;
    }

    fn readDataCountSection(self: *Parser) !?u32 {
        if (try self.readSectionHeader(12)) |section_end| {
            const count = try self.readU32();
            try self.expectSectionEnd(section_end);
            return count;
        }

        return null;
    }

    fn readCodeSection(self: *Parser) ![]types.Code {
        const section_end = try self.readSectionHeader(10) orelse return &.{};
        const result = try self.readVector(types.Code, readCode);
        try self.expectSectionEnd(section_end);
        return result;
    }

    fn readDataSection(self: *Parser) ![]types.Data {
        const section_end = try self.readSectionHeader(11) orelse return &.{};
        const result = try self.readVector(types.Data, readData);
        try self.expectSectionEnd(section_end);
        return result;
    }

    pub fn readModule(self: *Parser) !types.Module {
        var custom_sections = try std.ArrayList(types.CustomSection).initCapacity(self.allocator, 0);
        defer custom_sections.deinit(self.allocator);

        const magic_number = try self.readFixedU32();
        if (magic_number != 0x6d736100) {
            return error.InvalidMagicNumber;
        }

        const version = try self.readFixedU32();
        if (version != 0x1) {
            return error.UnsupportedVersion;
        }

        try self.readCustomSections(&custom_sections);
        const types_ = try self.readTypeSection();
        try self.readCustomSections(&custom_sections);
        const imports = try self.readImportSection();
        try self.readCustomSections(&custom_sections);
        const functions = try self.readFunctionSection();
        try self.readCustomSections(&custom_sections);
        const tables = try self.readTableSection();
        try self.readCustomSections(&custom_sections);
        const memories = try self.readMemorySection();
        try self.readCustomSections(&custom_sections);
        const globals = try self.readGlobalSection();
        try self.readCustomSections(&custom_sections);
        const exports = try self.readExportSection();
        try self.readCustomSections(&custom_sections);
        const start = try self.readStartSection();
        try self.readCustomSections(&custom_sections);
        const elements = try self.readElementSection();
        try self.readCustomSections(&custom_sections);
        const data_count = try self.readDataCountSection();
        try self.readCustomSections(&custom_sections);
        const codes = try self.readCodeSection();
        try self.readCustomSections(&custom_sections);
        const data = try self.readDataSection();
        try self.readCustomSections(&custom_sections);

        if (data_count) |count| {
            if (count != @as(u32, @intCast(data.len))) {
                std.debug.print("Data count mismatch: expected {d}, found {d}\n", .{ count, data.len });
                return error.DataCountMismatch;
            }
        }

        return types.Module{
            .bytes = self.bytes,
            .owns_type_bufs = true,
            .valtypes_buf = try self.valtypes_buf.toOwnedSlice(self.allocator),
            .custom = try custom_sections.toOwnedSlice(self.allocator),
            .types = types_,
            .imports = imports,
            .functions = functions,
            .tables = tables,
            .memories = memories,
            .globals = globals,
            .exports = exports,
            .start = start,
            .elements = elements,
            .codes = codes,
            .data = data,
        };
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqualSlices = std.testing.expectEqualSlices;

test "readByte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), &[_]u8{ 1, 2, 3 });
    try expectEqual(@as(u8, 1), try parser.readByte());
    try expectEqual(@as(u8, 2), try parser.readByte());
    try expectEqual(@as(u8, 3), try parser.readByte());
}

test "readU32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buffer: [2]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try std.leb.writeUleb128(fbs.writer(), @as(u32, 1998));
    var parser = Parser.init(arena.allocator(), buffer[0..]);
    try expectEqual(@as(u32, 1998), try parser.readU32());
}

test "readF32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buffer: [4]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    var writer = fbs.writer();
    const val: f32 = 3.14;
    try writer.writeInt(u32, @bitCast(val), .little);
    var parser = Parser.init(arena.allocator(), buffer[0..]);
    try expectEqual(val, try parser.readF32());
}

test "readF64" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buffer: [8]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    var writer = fbs.writer();
    const val: f64 = 3.14;
    try writer.writeInt(u64, @bitCast(val), .little);
    var parser = Parser.init(arena.allocator(), buffer[0..]);
    try expectEqual(val, try parser.readF64());
}

test "readVector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buffer: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const writer = fbs.writer();
    try std.leb.writeUleb128(writer, @as(u32, 3)); // length
    try std.leb.writeUleb128(writer, @as(u16, 1));
    try std.leb.writeUleb128(writer, @as(u16, 2));
    try std.leb.writeUleb128(writer, @as(u16, 3));

    var parser = Parser.init(arena.allocator(), buffer[0..]);
    const vec = try parser.readVector(u16, Parser.readU16);
    try expectEqual(@as(u16, 1), vec[0]);
    try expectEqual(@as(u16, 2), vec[1]);
    try expectEqual(@as(u16, 3), vec[2]);
}

test "readFunc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buffer = [_]u8{ 0x60, 0x2, 0x7F, 0x7E, 0x1, 0x7D }; // (i32, i64) -> (f32)
    var parser = Parser.init(arena.allocator(), buffer[0..]);
    const func_type = try parser.readFuncType();

    try expectEqual(@as(usize, 2), func_type.params.len);
    try expectEqual(types.ValType.i32, func_type.params[0]);
    try expectEqual(types.ValType.i64, func_type.params[1]);
    try expectEqual(@as(usize, 1), func_type.results.len);
    try expectEqual(types.ValType.f32, func_type.results[0]);
}

test "readModule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const file = try std.fs.cwd().openFile("res/fact.wasm", .{});
    defer file.close();

    const bytes = try file.readToEndAlloc(arena.allocator(), 128);
    var parser = Parser.init(arena.allocator(), bytes);
    const module = try parser.readModule();

    // Types
    try expectEqual(module.types.len, 3);
    try expectEqualSlices(types.ValType, module.types[0].params, &[_]types.ValType{.i32});
    try expectEqualSlices(types.ValType, module.types[0].results, &[_]types.ValType{.i32});
    try expectEqualSlices(types.ValType, module.types[1].params, &[_]types.ValType{});
    try expectEqualSlices(types.ValType, module.types[1].results, &[_]types.ValType{.i32});
    try expectEqualSlices(types.ValType, module.types[2].params, &[_]types.ValType{});
    try expectEqualSlices(types.ValType, module.types[2].results, &[_]types.ValType{});

    // Functions
    try expectEqual(module.functions.len, 3);
    try expectEqual(@as(u32, 0), module.functions[0]);
    try expectEqual(@as(u32, 1), module.functions[1]);
    try expectEqual(@as(u32, 2), module.functions[2]);

    // Exports
    try expectEqual(module.exports.len, 3);
    try expectEqualStrings("memory", module.exports[0].name);
    try expectEqualStrings("fact", module.exports[1].name);
    try expectEqualStrings("main", module.exports[2].name);

    // Codes
    try expectEqual(module.codes.len, 3);
    const code = module.codes[0];
    const body = code.body;

    // Check body length: local.get, i32.eqz, if
    try expectEqual(@as(usize, 3), body.len);

    // 1. local.get 0
    try expectEqual(types.Instr{ .local_get = 0 }, body[0]);

    // 2. i32.eqz
    try expectEqual(types.Instr.i32_eqz, body[1]);

    // 3. if
    switch (body[2]) {
        .@"if" => |if_instr| {
            try expectEqual(types.BlockType{ .val_type = .i32 }, if_instr.block_type);

            // Check 'then' branch
            const then_instrs = if_instr.then_instructions;
            try expectEqual(@as(usize, 1), then_instrs.len);
            try expectEqual(types.Instr{ .i32_const = 1 }, then_instrs[0]);

            // Check 'else' branch
            const else_instrs = if_instr.else_instructions;
            try expectEqual(@as(usize, 6), else_instrs.len);

            try expectEqual(types.Instr{ .local_get = 0 }, else_instrs[0]);
            try expectEqual(types.Instr{ .local_get = 0 }, else_instrs[1]);
            try expectEqual(types.Instr{ .i32_const = 1 }, else_instrs[2]);
            try expectEqual(types.Instr.i32_sub, else_instrs[3]);
            try expectEqual(types.Instr{ .call = 0 }, else_instrs[4]);
            try expectEqual(types.Instr.i32_mul, else_instrs[5]);
        },
        else => try expect(false),
    }

    // Imports
    try expectEqual(module.imports.len, 0);

    // Tables
    try expectEqual(module.tables.len, 1);
    try expectEqual(types.ElemType.func_ref, module.tables[0].elem_type);
    try expectEqual(@as(u32, 2), module.tables[0].limits.min);
    try expectEqual(@as(?u32, 2), module.tables[0].limits.max);

    // Memories
    try expectEqual(module.memories.len, 1);
    try expectEqual(@as(u32, 16), module.memories[0].limits.min);
    try expectEqual(@as(?u32, null), module.memories[0].limits.max);

    // Globals
    try expectEqual(module.globals.len, 1);
    try expectEqual(types.ValType.i32, module.globals[0].type.val_type);
    try expectEqual(true, module.globals[0].type.mutable);
    try expectEqual(@as(usize, 1), module.globals[0].init.len);
    try expectEqual(types.Instr{ .i32_const = 0 }, module.globals[0].init[0]);

    // Start
    try expectEqual(@as(?u32, 2), module.start);

    // Elements
    try expectEqual(module.elements.len, 1);
    try expectEqual(@as(u32, 0), module.elements[0].table);
    try expectEqual(@as(usize, 1), module.elements[0].offset.len);
    try expectEqual(types.Instr{ .i32_const = 0 }, module.elements[0].offset[0]);
    try expectEqual(@as(usize, 2), module.elements[0].init.len);
    try expectEqual(@as(u32, 0), module.elements[0].init[0]);
    try expectEqual(@as(u32, 1), module.elements[0].init[1]);

    // Data
    try expectEqual(module.data.len, 0);

    // Custom sections
    try expectEqual(module.custom.len, 0);
}
