const std = @import("std");
const types = @import("types.zig");

const Parser = struct {
    const Self = @This();
    bytes: []const u8,
    index: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) Self {
        return Self{
            .bytes = bytes,
            .allocator = allocator,
        };
    }

    // Reader interface (used in readUleb128)
    pub fn readByte(self: *Self) !types.Byte {
        if (self.index >= self.bytes.len) {
            return error.EndOfInput;
        }

        const byte = self.bytes[self.index];
        self.index += 1;

        return byte;
    }

    pub fn peekByte(self: *Self) !u8 {
        if (self.index >= self.bytes.len) {
            return error.EndOfInput;
        }

        return self.bytes[self.index];
    }

    fn readUInt(self: *Self, comptime T: type) !T {
        return std.leb.readUleb128(T, self);
    }

    fn readSInt(self: *Self, comptime T: type) !T {
        return std.leb.readIleb128(T, self);
    }

    fn readU8(self: *Self) !u8 {
        return self.readUInt(u8);
    }

    fn readU16(self: *Self) !u16 {
        return self.readUInt(u16);
    }

    fn readU32(self: *Self) !u32 {
        return self.readUInt(u32);
    }

    fn readU64(self: *Self) !u64 {
        return self.readUInt(u64);
    }

    fn readI8(self: *Self) !i8 {
        return self.readSInt(i8);
    }

    fn readI16(self: *Self) !i16 {
        return self.readSInt(i16);
    }

    fn readI32(self: *Self) !i32 {
        return self.readSInt(i32);
    }

    fn readI64(self: *Self) !i64 {
        return self.readSInt(i64);
    }

    fn readF32(self: *Self) !f32 {
        const val = std.mem.readInt(u32, self.bytes[self.index..][0..4], .little);
        self.index += 4;
        return @bitCast(val);
    }

    fn readF64(self: *Self) !f64 {
        const val = std.mem.readInt(u64, self.bytes[self.index..][0..8], .little);
        self.index += 8;
        return @bitCast(val);
    }

    fn readVector(self: *Self, comptime T: type, decode_fn: *const fn (*Self) anyerror!T) ![]T {
        const len = try self.readU32();
        const vec = try self.allocator.alloc(T, len);
        errdefer self.allocator.free(vec);

        for (vec) |*item| {
            item.* = try decode_fn(self);
        }

        return vec;
    }

    fn readName(self: *Self) !types.Name {
        const len = try self.readU32();
        const bytes = self.bytes[self.index..][0..len];
        self.index += len;
        return bytes;
    }

    fn readValType(self: *Self) !types.ValType {
        const n = try self.readByte();

        return switch (n) {
            0x7F => .i32,
            0x7E => .i64,
            0x7D => .f32,
            0x7C => .f64,
            else => return error.InvalidValType,
        };
    }

    fn readBlockType(self: *Self) !types.BlockType {
        const n = try self.readByte();

        if (n == 0x40) {
            return .empty;
        } else {
            self.index -= 1; // unread the byte
            const val_type = try self.readValType();
            return .{ .val_type = val_type };
        }
    }

    fn readFuncType(self: *Self) !types.FuncType {
        const n = try self.readByte();

        if (n != 0x60) {
            return error.InvalidFuncType;
        }

        const params = try self.readVector(types.ValType, Self.readValType);
        const results = try self.readVector(types.ValType, Self.readValType);

        return .{ .params = params, .results = results };
    }

    fn readLimits(self: *Self) !types.Limits {
        const flag = try self.readByte();
        const min = try self.readU32();

        switch (flag) {
            0x00 => return .{ .min = min, .max = null },
            0x01 => {
                const max = try self.readU32();
                return .{ .min = min, .max = max };
            },
            else => return error.InvalidLimits,
        }
    }

    fn readMemType(self: *Self) !types.MemType {
        const limits = try self.readLimits();
        return .{ .limits = limits };
    }

    fn readTableType(self: *Self) !types.TableType {
        const elem_type_n = try self.readByte();
        const elem_type = switch (elem_type_n) {
            0x70 => .func_ref,
            else => return error.InvalidElemType,
        };

        const limits = try self.readLimits();

        return .{ .elem_type = elem_type, .limits = limits };
    }

    fn readGlobalType(self: *Self) !types.GlobalType {
        const val_type = try self.readValType();
        const mutable_n = try self.readByte();
        const mutable = switch (mutable_n) {
            0x00 => false,
            0x01 => true,
            else => return error.InvalidGlobalMutability,
        };

        return .{ .val_type = val_type, .mutable = mutable };
    }

    const SequenceResult = struct {
        instructions: std.ArrayList(types.Instr),
        terminator: u8,
    };

    fn readInstructionSequence(self: *Self, terminators: []const u8) !SequenceResult {
        var instructions = try std.ArrayList(types.Instr).initCapacity(self.allocator, 0);
        errdefer instructions.deinit();

        while (true) {
            const next_byte = try self.peekByte();

            for (terminators) |t| {
                if (next_byte == t) {
                    _ = try self.readByte(); // Consume the terminator
                    return .{ .instructions = instructions, .terminator = t };
                }
            }

            // It's not a terminator, so it must be an instruction
            const instr = try self.readInstr();
            try instructions.append(instr);
        }
    }

    fn readMemArg(self: *Self) !types.MemoryInstrArg {
        const alignment = try self.readU32();
        const offset = try self.readU32();
        return .{ .alignment = alignment, .offset = offset };
    }

    fn readInstr(self: *Self) !types.Instr {
        const opcode = try self.readByte();

        return switch (opcode) {
            0x00 => .unreachable_op,
            0x01 => .nop,
            0x02, 0x03 => |op| {
                const block_type = try self.readBlockType();
                const res = try self.readInstructionSequence(&.{0x0B});

                if (op == 0x02) {
                    return .{ .block = .{ .block_type = block_type, .instructions = res.instructions } };
                } else {
                    return .{ .loop = .{ .block_type = block_type, .instructions = res.instructions } };
                }
            },
            0x04 => {
                const block_type = try self.readBlockType();

                // Read the "then" block, which can end with 0x0B (end) or 0x05 (else)
                const then_res = try self.readInstructionSequence(&.{ 0x0B, 0x05 });
                var else_instructions: std.ArrayList(types.Instr) = undefined;

                if (then_res.terminator == 0x05) {
                    const else_res = try self.readInstructionSequence(&.{0x0B});
                    else_instructions = else_res.instructions;
                } else {
                    else_instructions = std.ArrayList(types.Instr).init(self.allocator);
                }

                return .{
                    .if_else = .{
                        .block_type = block_type,
                        .then_instructions = then_res.instructions,
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
                const labels = try self.readVector(types.LabelIndex, Self.readU32);
                const default_idx = try self.readU32();
                return .{ .label_indices = labels, .default_idx = default_idx };
            },
            0x0F => .return_op,
            0x10 => {
                const func_idx = try self.readU32();
                return .{ .call = func_idx };
            },
            0x11 => {
                const type_idx = try self.readU32();
                const table_idx = try self.readByte();

                if (table_idx != 0x00) {
                    return error.InvalidCallIndirectInstruction;
                }

                return .{ .call_indirect = .{ .type_idx = type_idx, .table_idx = table_idx } };
            },
            0x1A => .drop,
            0x1B => .select,
            0x20 => .{ .local_get = try self.readU32() },
            0x21 => .{ .local_set = try self.readU32() },
            0x22 => .{ .local_tee = try self.readU32() },
            0x23 => .{ .global_get = try self.readU32() },
            0x24 => .{ .global_set = try self.readU32() },
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
                const mem_idx: types.MemIndex = try self.readByte();

                if (mem_idx != 0x00) {
                    return error.InvalidMemoryInstruction;
                }

                return .{ .memory_size = mem_idx };
            },
            0x40 => {
                const mem_idx: types.MemIndex = try self.readByte();

                if (mem_idx != 0x00) {
                    return error.InvalidMemoryInstruction;
                }

                return .{ .memory_grow = mem_idx };
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

            else => return error.InvalidInstruction,
        };
    }
};

test "readByte" {
    var parser = Parser.init(std.testing.allocator, &[_]u8{ 1, 2, 3 });
    try std.testing.expectEqual(@as(u8, 1), try parser.readByte());
    try std.testing.expectEqual(@as(u8, 2), try parser.readByte());
    try std.testing.expectEqual(@as(u8, 3), try parser.readByte());
}

test "readU32" {
    var buffer: [2]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try std.leb.writeUleb128(fbs.writer(), @as(u32, 1998));
    var parser = Parser.init(std.testing.allocator, buffer[0..]);
    try std.testing.expectEqual(@as(u32, 1998), try parser.readU32());
}

test "readF32" {
    var buffer: [4]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    var writer = fbs.writer();
    const val: f32 = 3.14;
    try writer.writeInt(u32, @bitCast(val), .little);
    var parser = Parser.init(std.testing.allocator, buffer[0..]);
    try std.testing.expectEqual(val, try parser.readF32());
}

test "readF64" {
    var buffer: [8]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    var writer = fbs.writer();
    const val: f64 = 3.14;
    try writer.writeInt(u64, @bitCast(val), .little);
    var parser = Parser.init(std.testing.allocator, buffer[0..]);
    try std.testing.expectEqual(val, try parser.readF64());
}

test "readVector" {
    var buffer: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const writer = fbs.writer();
    try std.leb.writeUleb128(writer, @as(u32, 3)); // length
    try std.leb.writeUleb128(writer, @as(u16, 1));
    try std.leb.writeUleb128(writer, @as(u16, 2));
    try std.leb.writeUleb128(writer, @as(u16, 3));

    var parser = Parser.init(std.testing.allocator, buffer[0..]);
    const vec = try parser.readVector(u16, Parser.readU16);
    defer parser.allocator.free(vec);
    try std.testing.expectEqual(@as(u16, 1), vec[0]);
    try std.testing.expectEqual(@as(u16, 2), vec[1]);
    try std.testing.expectEqual(@as(u16, 3), vec[2]);
}

test "readFunc" {
    const buffer = [_]u8{ 0x60, 0x2, 0x7F, 0x7E, 0x1, 0x7D }; // (i32, i64) -> (f32)
    var parser = Parser.init(std.testing.allocator, buffer[0..]);
    const func_type = try parser.readFuncType();
    defer {
        parser.allocator.free(func_type.params);
        parser.allocator.free(func_type.results);
    }

    try std.testing.expectEqual(@as(usize, 2), func_type.params.len);
    try std.testing.expectEqual(types.ValType.i32, func_type.params[0]);
    try std.testing.expectEqual(types.ValType.i64, func_type.params[1]);
    try std.testing.expectEqual(@as(usize, 1), func_type.results.len);
    try std.testing.expectEqual(types.ValType.f32, func_type.results[0]);
}
