const std = @import("std");
const types = @import("types.zig");

pub const TokenType = enum {
    lparen,
    rparen,
    id,
    keyword,
    integer,
    float,
    string,
};

pub const Token = union(TokenType) {
    lparen,
    rparen,
    id: []const u8,
    keyword: []const u8,
    integer: IntegerLiteral,
    float: FloatLiteral,
    string: []const u8,

    pub fn format(self: Token, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .lparen => try writer.writeAll("("),
            .rparen => try writer.writeAll(")"),
            .id => |s| try writer.print("${s}", .{s}),
            .keyword => |s| try writer.writeAll(s),
            .integer => |int| {
                if (int.is_hex) {
                    try writer.print("0x{x}", .{int.value});
                } else {
                    if (int.is_signed) {
                        try writer.print("-{d}", .{int.value});
                    } else {
                        try writer.print("{d}", .{int.value});
                    }
                }
            },
            .float => |f| try writer.print("{d}", .{@as(f64, @bitCast(f.value))}),
            .string => |s| try writer.print("\"{s}\"", .{s}),
        }
    }
};

pub const Span = struct {
    start: usize,
    end: usize,
};

pub const TokenSpan = struct {
    span: Span,
    token: Token,
};

pub const IntegerLiteral = struct {
    value: u64,
    is_signed: bool,
    is_hex: bool,
};

pub const FloatLiteral = struct {
    value: u64,
};

pub const Lexer = struct {
    source: []const u8,
    pos: usize,

    pub fn init(source: []const u8) Lexer {
        return Lexer{
            .source = source,
            .pos = 0,
        };
    }

    fn advance(self: *Lexer) ?u8 {
        self.pos += 1;
        if (self.pos >= self.source.len) {
            return null;
        }

        return self.source[self.pos];
    }

    fn peek(self: *Lexer, offset: usize) ?u8 {
        const pos = self.pos + offset;
        if (pos >= self.source.len) {
            return null;
        }

        return self.source[pos];
    }

    fn match(self: *Lexer, c: u8) bool {
        if (self.pos >= self.source.len) return false;
        return self.source[self.pos] == c;
    }

    fn matches(self: *Lexer, s: []const u8) bool {
        if (self.pos + s.len > self.source.len) {
            return false;
        }

        return eql(self.source[self.pos .. self.pos + s.len], s);
    }

    fn isIdChar(c: u8) bool {
        return switch (c) {
            '0'...'9', 'A'...'Z', 'a'...'z' => true,
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '/' => true,
            ':', '<', '=', '>', '?', '@', '\\', '^', '_', '`', '|', '~' => true,
            else => false,
        };
    }

    fn isLineCommentChar(c: u8) bool {
        return c != '\n' and c != '\r';
    }

    fn skipWhitespacesAndComments(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const char = self.source[self.pos];
            switch (char) {
                ' ', '\n', '\r', '\t' => {
                    self.pos += 1;
                },
                ';' => {
                    if (self.matches(";;")) {
                        self.pos += 2;
                        while (self.pos < self.source.len) {
                            if (!isLineCommentChar(self.source[self.pos])) break;
                            self.pos += 1;
                        }
                    } else {
                        return;
                    }
                },
                '(' => {
                    if (self.matches("(;")) {
                        self.pos += 2;
                        var depth: usize = 1;
                        while (self.pos < self.source.len and depth > 0) {
                            if (self.matches("(;")) {
                                depth += 1;
                                self.pos += 2;
                            } else if (self.matches(";)")) {
                                depth -= 1;
                                self.pos += 2;
                            } else {
                                self.pos += 1;
                            }
                        }
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    fn tryParseInt(text: []const u8, is_hex: bool) ?u64 {
        // parseInt handles underscores
        return std.fmt.parseInt(u64, text, if (is_hex) 16 else 10) catch null;
    }

    fn tryParseFloat(text: []const u8) ?f64 {
        // parseFloat handles underscores
        return std.fmt.parseFloat(f64, text) catch null;
    }

    fn parseNumber(text: []const u8) ?Token {
        if (text.len == 0) return null;

        var start: usize = 0;
        var is_signed = false;

        if (text[0] == '+' or text[0] == '-') {
            is_signed = text[0] == '-';
            start = 1;
            if (text.len == 1) return null;
        }

        const remaining = text[start..];

        if (std.mem.eql(u8, remaining, "inf")) {
            const val = if (is_signed) -std.math.inf(f64) else std.math.inf(f64);
            return Token{ .float = .{ .value = @bitCast(val) } };
        }

        if (std.mem.startsWith(u8, remaining, "nan")) {
            // Standard IEEE 754 f64 Exponent Mask (Bits 52-62)
            const exponent_bits: u64 = 0x7FF0000000000000;
            // Standard IEEE 754 f64 Mantissa Mask (Bits 0-51)
            const mantissa_mask: u64 = 0x000FFFFFFFFFFFFF;
            // Canonical NaN has the MSB of the mantissa set (Quiet NaN)
            const canon_nan_bits: u64 = 0x7FF8000000000000;

            var bits: u64 = canon_nan_bits;

            if (remaining.len > 3 and remaining[3] == ':') {
                const payload_str = remaining[4..];
                const is_payload_hex = std.mem.startsWith(u8, payload_str, "0x");
                const num_part = if (is_payload_hex) payload_str[2..] else payload_str;

                // If the payload integer is invalid, this entire token is not a number.
                const payload = tryParseInt(num_part, is_payload_hex) orelse return null;

                // When an explicit payload is provided, we use the bare exponent bits.
                // The payload determines if it is Quiet (bit 51=1) or Signaling (bit 51=0).
                bits = exponent_bits | (payload & mantissa_mask);
            }

            // Apply the sign bit if necessary (Bit 63)
            if (is_signed) {
                bits |= 0x8000000000000000;
            }

            return Token{ .float = .{ .value = bits } };
        }

        const is_hex = std.mem.startsWith(u8, remaining, "0x");
        const num_start: usize = if (is_hex) 2 else 0;

        if (num_start >= remaining.len) return null;

        var is_float = false;
        for (remaining[num_start..]) |c| {
            if (c == '.' or c == 'p' or c == 'P' or c == 'e' or c == 'E') {
                is_float = true;
                break;
            }
        }

        if (is_float) {
            if (tryParseFloat(remaining)) |val| {
                const final = if (is_signed) -val else val;
                return Token{ .float = .{ .value = @bitCast(final) } };
            }
        } else {
            const num_part = remaining[num_start..];
            if (tryParseInt(num_part, is_hex)) |val| {
                return Token{ .integer = .{ .value = val, .is_signed = is_signed, .is_hex = is_hex } };
            }
        }

        return null;
    }

    fn span(self: *Lexer, start: usize, token: Token) TokenSpan {
        return TokenSpan{
            .span = Span{ .start = start, .end = self.pos },
            .token = token,
        };
    }

    pub fn next(self: *Lexer) !?TokenSpan {
        self.skipWhitespacesAndComments();

        if (self.pos >= self.source.len) {
            return null;
        }

        const start = self.pos;
        const char = self.source[self.pos];

        switch (char) {
            '(' => {
                self.pos += 1;
                return self.span(start, .lparen);
            },
            ')' => {
                self.pos += 1;
                return self.span(start, .rparen);
            },
            '"' => {
                self.pos += 1;

                while (self.pos < self.source.len) {
                    const c = self.source[self.pos];
                    if (c == '"') {
                        self.pos += 1;
                        break;
                    }
                    if (c == '\\') {
                        if (self.pos + 1 >= self.source.len) {
                            return error.UnexpectedEOF;
                        }

                        self.pos += 2;
                        continue;
                    }

                    if (c < 0x20) {
                        return error.IllegalControlCharacter;
                    }

                    self.pos += 1;
                }

                return self.span(start, .{ .string = self.source[start + 1 .. self.pos - 1] });
            },
            else => {
                if (isIdChar(char)) {
                    while (self.pos < self.source.len and isIdChar(self.source[self.pos])) {
                        self.pos += 1;
                    }

                    const text = self.source[start..self.pos];

                    if (text.len > 0 and text[0] == '$') {
                        return self.span(start, .{ .id = text[1..] });
                    }

                    if (parseNumber(text)) |token| {
                        return self.span(start, token);
                    }

                    return self.span(start, .{ .keyword = text });
                } else {
                    return error.UnexpectedCharacter;
                }
            },
        }
    }
};

const ArrayList = std.ArrayList;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, haystack, prefix);
}

pub const Parser = struct {
    lexer: Lexer,
    current: ?Token,
    allocator: std.mem.Allocator,

    // Name resolution maps (populated during pre-scan)
    type_names: std.StringHashMapUnmanaged(u32) = .{},
    func_names: std.StringHashMapUnmanaged(u32) = .{},
    table_names: std.StringHashMapUnmanaged(u32) = .{},
    mem_names: std.StringHashMapUnmanaged(u32) = .{},
    global_names: std.StringHashMapUnmanaged(u32) = .{},

    // Accumulated type definitions (for typeuse abbreviation resolution)
    module_types: ArrayList(types.FuncType) = .empty,

    // Per-function parsing state
    local_names: std.StringHashMapUnmanaged(u32) = .{},
    local_count: u32 = 0,
    label_stack: ArrayList(?[]const u8) = .empty,

    pub fn init(source: []const u8, allocator: std.mem.Allocator) !Parser {
        var parser = Parser{
            .lexer = Lexer.init(source),
            .current = null,
            .allocator = allocator,
        };

        if (try parser.lexer.next()) |t| {
            parser.current = t.token;
        }

        return parser;
    }

    fn advance(self: *Parser) !void {
        if (try self.lexer.next()) |t| {
            self.current = t.token;
        } else {
            self.current = null;
        }
    }

    fn peek(self: *Parser) !Token {
        return self.current orelse return error.UnexpectedEOF;
    }

    fn isAt(self: *Parser, tt: TokenType) bool {
        if (self.current) |token| {
            return std.meta.activeTag(token) == tt;
        }

        return false;
    }

    fn isKeyword(self: *Parser, kw: []const u8) bool {
        if (self.current) |token| {
            switch (token) {
                .keyword => |s| return eql(s, kw),
                else => {},
            }
        }

        return false;
    }

    fn expect(self: *Parser, tt: TokenType) !Token {
        const token = try self.peek();
        if (std.meta.activeTag(token) != tt) {
            return error.UnexpectedToken;
        }

        try self.advance();
        return token;
    }

    fn expectKeyword(self: *Parser) ![]const u8 {
        const token = try self.expect(.keyword);
        return token.keyword;
    }

    fn expectKeywordExact(self: *Parser, kw: []const u8) !void {
        const token = try self.peek();
        switch (token) {
            .keyword => |s| {
                if (!eql(s, kw)) return error.UnexpectedKeyword;
            },
            else => return error.ExpectedKeyword,
        }

        try self.advance();
    }

    fn expectString(self: *Parser) ![]const u8 {
        const token = try self.expect(.string);
        return token.string;
    }

    fn optional(self: *Parser, tt: TokenType) !?Token {
        if (self.current) |token| {
            if (std.meta.activeTag(token) == tt) {
                try self.advance();
                return token;
            }
        }

        return null;
    }

    fn optionalId(self: *Parser) !?[]const u8 {
        if (try self.optional(.id)) |id| {
            return id.id;
        }

        return null;
    }

    /// Skip balanced parentheses. `depth` = number of unclosed '(' already consumed.
    fn skipParens(self: *Parser, depth_init: u32) !void {
        var depth = depth_init;

        while (depth > 0) {
            const tok = try self.peek();
            try self.advance();
            switch (tok) {
                .lparen => depth += 1,
                .rparen => depth -= 1,
                else => {},
            }
        }
    }

    fn preScan(self: *Parser) !void {
        const saved_pos = self.lexer.pos;
        const saved_current = self.current;

        // Parse `(module id? ...`
        _ = try self.expect(.lparen);
        try self.expectKeywordExact("module");
        _ = try self.optionalId();

        var type_count: u32 = 0;
        var func_count: u32 = 0;
        var table_count: u32 = 0;
        var mem_count: u32 = 0;
        var global_count: u32 = 0;

        while (self.current != null and !self.isAt(.rparen)) {
            _ = try self.expect(.lparen);
            const keyword = try self.expectKeyword();

            if (eql(keyword, "type")) {
                if (try self.optionalId()) |name| {
                    try self.type_names.put(self.allocator, name, type_count);
                }
                // Parse the type definition now to collect the correct type index for func types (for typeuse resolution)
                const ft = try self.parseFuncType();
                try self.module_types.append(self.allocator, ft);
                _ = try self.expect(.rparen);
                type_count += 1;
            } else if (eql(keyword, "func")) {
                if (try self.optionalId()) |name| {
                    try self.func_names.put(self.allocator, name, func_count);
                }
                func_count += 1;
                try self.skipParens(1);
            } else if (eql(keyword, "table")) {
                if (try self.optionalId()) |name| {
                    try self.table_names.put(self.allocator, name, table_count);
                }
                table_count += 1;
                try self.skipParens(1);
            } else if (eql(keyword, "memory")) {
                if (try self.optionalId()) |name| {
                    try self.mem_names.put(self.allocator, name, mem_count);
                }
                mem_count += 1;
                try self.skipParens(1);
            } else if (eql(keyword, "global")) {
                if (try self.optionalId()) |name| {
                    try self.global_names.put(self.allocator, name, global_count);
                }
                global_count += 1;
                try self.skipParens(1);
            } else if (eql(keyword, "import")) {
                // (import "mod" "name" (desc_kw id? ...))
                _ = try self.expect(.string); // module name
                _ = try self.expect(.string); // import name
                _ = try self.expect(.lparen); // open desc
                const desc_kw = try self.expectKeyword();
                const opt_id = try self.optionalId();
                if (eql(desc_kw, "func")) {
                    if (opt_id) |name| try self.func_names.put(self.allocator, name, func_count);
                    func_count += 1;
                } else if (eql(desc_kw, "table")) {
                    if (opt_id) |name| try self.table_names.put(self.allocator, name, table_count);
                    table_count += 1;
                } else if (eql(desc_kw, "memory")) {
                    if (opt_id) |name| try self.mem_names.put(self.allocator, name, mem_count);
                    mem_count += 1;
                } else if (eql(desc_kw, "global")) {
                    if (opt_id) |name| try self.global_names.put(self.allocator, name, global_count);
                    global_count += 1;
                }
                try self.skipParens(2); // close desc + import
            } else {
                try self.skipParens(1);
            }
        }

        // Restore parser state
        self.lexer.pos = saved_pos;
        self.current = saved_current;
    }

    fn resolveType(self: *Parser) !u32 {
        const token = try self.peek();
        switch (token) {
            .integer => |int| {
                try self.advance();
                return @intCast(int.value);
            },
            .id => |name| {
                try self.advance();
                return self.type_names.get(name) orelse return error.UndefinedType;
            },
            else => return error.ExpectedIndex,
        }
    }

    fn resolveFunc(self: *Parser) !u32 {
        const token = try self.peek();
        switch (token) {
            .integer => |int| {
                try self.advance();
                return @intCast(int.value);
            },
            .id => |name| {
                try self.advance();
                return self.func_names.get(name) orelse return error.UndefinedFunc;
            },
            else => return error.ExpectedIndex,
        }
    }

    fn resolveTable(self: *Parser) !u32 {
        const token = try self.peek();
        switch (token) {
            .integer => |int| {
                try self.advance();
                return @intCast(int.value);
            },
            .id => |name| {
                try self.advance();
                return self.table_names.get(name) orelse return error.UndefinedTable;
            },
            else => return error.ExpectedIndex,
        }
    }

    fn resolveMem(self: *Parser) !u32 {
        const token = try self.peek();
        switch (token) {
            .integer => |int| {
                try self.advance();
                return @intCast(int.value);
            },
            .id => |name| {
                try self.advance();
                return self.mem_names.get(name) orelse return error.UndefinedMemory;
            },
            else => return error.ExpectedIndex,
        }
    }

    fn resolveGlobal(self: *Parser) !u32 {
        const token = try self.peek();
        switch (token) {
            .integer => |int| {
                try self.advance();
                return @intCast(int.value);
            },
            .id => |name| {
                try self.advance();
                return self.global_names.get(name) orelse return error.UndefinedGlobal;
            },
            else => return error.ExpectedIndex,
        }
    }

    fn resolveLocal(self: *Parser) !u32 {
        const token = try self.peek();
        switch (token) {
            .integer => |int| {
                try self.advance();
                return @intCast(int.value);
            },
            .id => |name| {
                try self.advance();
                return self.local_names.get(name) orelse return error.UndefinedLocal;
            },
            else => return error.ExpectedIndex,
        }
    }

    fn resolveLabel(self: *Parser) !u32 {
        const token = try self.peek();
        switch (token) {
            .integer => |int| {
                try self.advance();
                return @intCast(int.value);
            },
            .id => |name| {
                try self.advance();
                // Labels use reverse indexing: 0 = innermost
                const items = self.label_stack.items;
                var i: u32 = 0;
                while (i < items.len) : (i += 1) {
                    const idx = items.len - 1 - i;
                    if (items[idx]) |label_name| {
                        if (eql(label_name, name)) return i;
                    }
                }
                return error.UndefinedLabel;
            },
            else => return error.ExpectedIndex,
        }
    }

    fn parseValType(self: *Parser) !types.ValType {
        const keyword = try self.expectKeyword();
        return std.meta.stringToEnum(types.ValType, keyword) orelse return error.UnknownValType;
    }

    fn parseFuncType(self: *Parser) !types.FuncType {
        _ = try self.expect(.lparen);
        try self.expectKeywordExact("func");

        var params: ArrayList(types.ValType) = .empty;
        var results: ArrayList(types.ValType) = .empty;

        while (self.isAt(.lparen)) {
            _ = try self.expect(.lparen);
            const keyword = try self.expectKeyword();

            if (eql(keyword, "param")) {
                if (results.items.len > 0) return error.InvalidFuncType;

                if (self.isAt(.id)) {
                    // Named param: (param $name valtype)
                    _ = try self.optionalId();
                    const ty = try self.parseValType();
                    try params.append(self.allocator, ty);
                } else {
                    // Unnamed: (param valtype*)
                    while (!self.isAt(.rparen)) {
                        const ty = try self.parseValType();
                        try params.append(self.allocator, ty);
                    }
                }
            } else if (eql(keyword, "result")) {
                while (!self.isAt(.rparen)) {
                    const ty = try self.parseValType();
                    try results.append(self.allocator, ty);
                }
            } else {
                return error.InvalidFuncType;
            }

            _ = try self.expect(.rparen);
        }

        _ = try self.expect(.rparen);

        return types.FuncType{
            .params = try params.toOwnedSlice(self.allocator),
            .results = try results.toOwnedSlice(self.allocator),
        };
    }

    fn parseLimits(self: *Parser) !types.Limits {
        const token = try self.expect(.integer);
        const min: u32 = @intCast(token.integer.value);
        var max: ?u32 = null;

        if (self.isAt(.integer)) {
            const max_tok = try self.expect(.integer);
            max = @intCast(max_tok.integer.value);
        }

        return .{ .min = min, .max = max };
    }

    fn parseTableType(self: *Parser) !types.TableType {
        const limits = try self.parseLimits();
        try self.expectKeywordExact("funcref");
        return .{ .elem_type = .func_ref, .limits = limits };
    }

    fn parseMemType(self: *Parser) !types.MemType {
        const limits = try self.parseLimits();
        return .{ .limits = limits };
    }

    fn parseGlobalType(self: *Parser) !types.GlobalType {
        if (self.isAt(.lparen)) {
            // (mut valtype)
            _ = try self.expect(.lparen);
            try self.expectKeywordExact("mut");
            const vt = try self.parseValType();
            _ = try self.expect(.rparen);
            return .{ .val_type = vt, .mutable = true };
        } else {
            const vt = try self.parseValType();
            return .{ .val_type = vt, .mutable = false };
        }
    }

    fn parseBlockType(self: *Parser) !types.BlockType {
        if (self.isAt(.lparen)) {
            // Check for (result valtype)
            const saved_pos = self.lexer.pos;
            const saved_current = self.current;
            _ = try self.expect(.lparen);

            if (self.isKeyword("result")) {
                try self.advance(); // consume "result"
                const vt = try self.parseValType();
                _ = try self.expect(.rparen);
                return .{ .val_type = vt };
            } else {
                // Not a result block type, restore
                self.lexer.pos = saved_pos;
                self.current = saved_current;
                return .empty;
            }
        }

        return .empty;
    }

    /// Parse a typeuse: `(type idx) param* result*` or just `param* result*`
    /// Returns the type index. If no explicit (type ...) is given,
    /// finds or creates a matching type definition.
    fn parseTypeUse(self: *Parser) !u32 {
        var explicit_idx: ?u32 = null;

        // Check for (type idx)
        if (self.isAt(.lparen)) {
            const saved_pos = self.lexer.pos;
            const saved_current = self.current;
            _ = try self.expect(.lparen);
            if (self.isKeyword("type")) {
                try self.advance();
                explicit_idx = try self.resolveType();
                _ = try self.expect(.rparen);
            } else {
                // Not a type clause, restore
                self.lexer.pos = saved_pos;
                self.current = saved_current;
            }
        }

        // Parse inline param/result annotations
        var params: ArrayList(types.ValType) = .empty;
        var results: ArrayList(types.ValType) = .empty;
        var has_inline = false;

        while (self.isAt(.lparen)) {
            const saved_pos = self.lexer.pos;
            const saved_current = self.current;
            _ = try self.expect(.lparen);

            if (self.current) |tok| {
                switch (tok) {
                    .keyword => |kw| {
                        if (eql(kw, "param")) {
                            has_inline = true;
                            try self.advance();
                            if (self.isAt(.id)) {
                                const id_name = (try self.optionalId()).?;
                                const vt = try self.parseValType();
                                try params.append(self.allocator, vt);
                                try self.local_names.put(self.allocator, id_name, self.local_count);
                                self.local_count += 1;
                            } else {
                                while (!self.isAt(.rparen)) {
                                    const vt = try self.parseValType();
                                    try params.append(self.allocator, vt);
                                    self.local_count += 1;
                                }
                            }
                            _ = try self.expect(.rparen);
                            continue;
                        } else if (eql(kw, "result")) {
                            has_inline = true;
                            try self.advance();
                            while (!self.isAt(.rparen)) {
                                const vt = try self.parseValType();
                                try results.append(self.allocator, vt);
                            }
                            _ = try self.expect(.rparen);
                            continue;
                        }
                    },
                    else => {},
                }
            }

            // Not param/result - restore and break
            self.lexer.pos = saved_pos;
            self.current = saved_current;
            break;
        }

        if (explicit_idx) |idx| {
            if (!has_inline) {
                // Initialize local_count from the type definition params
                if (idx < self.module_types.items.len) {
                    self.local_count = @intCast(self.module_types.items[idx].params.len);
                }
            }
            return idx;
        }

        // No explicit type index - find or create matching type
        const ft = types.FuncType{
            .params = try params.toOwnedSlice(self.allocator),
            .results = try results.toOwnedSlice(self.allocator),
        };

        // Search for existing matching type
        for (self.module_types.items, 0..) |existing, i| {
            if (existing.eql(ft)) {
                return @intCast(i);
            }
        }

        // Create new type
        const idx: u32 = @intCast(self.module_types.items.len);
        try self.module_types.append(self.allocator, ft);
        return idx;
    }

    pub fn parseModule(self: *Parser) !types.Module {
        // Pre-scan to collect all names
        try self.preScan();

        _ = try self.expect(.lparen);
        try self.expectKeywordExact("module");
        _ = try self.optionalId();

        // Types already parsed during preScan
        var mod_imports: ArrayList(types.Import) = .empty;
        var mod_functions: ArrayList(types.TypeIndex) = .empty;
        var mod_tables: ArrayList(types.TableType) = .empty;
        var mod_memories: ArrayList(types.MemType) = .empty;
        var mod_globals: ArrayList(types.Global) = .empty;
        var mod_exports: ArrayList(types.Export) = .empty;
        var mod_start: ?types.FuncIndex = null;
        var mod_elems: ArrayList(types.Elem) = .empty;
        var mod_codes: ArrayList(types.Code) = .empty;
        var mod_datas: ArrayList(types.Data) = .empty;

        while (self.current != null and !self.isAt(.rparen)) {
            _ = try self.expect(.lparen);
            const field_kw = try self.expectKeyword();

            if (eql(field_kw, "type")) {
                // Already processed in preScan; just skip past the (func ...) typeexpr.
                _ = try self.optionalId();
                _ = try self.parseFuncType(); // Discard; already in module_types
            } else if (eql(field_kw, "import")) {
                const imp = try self.visitImportField();
                try mod_imports.append(self.allocator, imp);
            } else if (eql(field_kw, "func")) {
                const result = try self.visitFuncField();
                try mod_functions.append(self.allocator, result.type_idx);
                try mod_codes.append(self.allocator, result.code);
            } else if (eql(field_kw, "table")) {
                const tt = try self.visitTableField();
                try mod_tables.append(self.allocator, tt);
            } else if (eql(field_kw, "memory")) {
                const mt = try self.visitMemField();
                try mod_memories.append(self.allocator, mt);
            } else if (eql(field_kw, "global")) {
                const g = try self.visitGlobalField();
                try mod_globals.append(self.allocator, g);
            } else if (eql(field_kw, "export")) {
                const ex = try self.visitExportField();
                try mod_exports.append(self.allocator, ex);
            } else if (eql(field_kw, "start")) {
                mod_start = try self.resolveFunc();
            } else if (eql(field_kw, "elem")) {
                const el = try self.visitElemField();
                try mod_elems.append(self.allocator, el);
            } else if (eql(field_kw, "data")) {
                const d = try self.visitDataField();
                try mod_datas.append(self.allocator, d);
            } else {
                return error.UnknownModuleField;
            }

            _ = try self.expect(.rparen);
        }

        _ = try self.expect(.rparen);

        return types.Module{
            .custom = &.{},
            .types = try self.module_types.toOwnedSlice(self.allocator),
            .imports = try mod_imports.toOwnedSlice(self.allocator),
            .functions = try mod_functions.toOwnedSlice(self.allocator),
            .tables = try mod_tables.toOwnedSlice(self.allocator),
            .memories = try mod_memories.toOwnedSlice(self.allocator),
            .globals = try mod_globals.toOwnedSlice(self.allocator),
            .exports = try mod_exports.toOwnedSlice(self.allocator),
            .start = mod_start,
            .elements = try mod_elems.toOwnedSlice(self.allocator),
            .codes = try mod_codes.toOwnedSlice(self.allocator),
            .data = try mod_datas.toOwnedSlice(self.allocator),
        };
    }

    fn visitTypeField(self: *Parser) !types.FuncType {
        _ = try self.optionalId(); // optional type name (already collected in pre-scan)
        return try self.parseFuncType();
    }

    fn visitImportField(self: *Parser) !types.Import {
        const mod = try self.expectString();
        const name = try self.expectString();
        const desc = try self.parseImportDesc();
        return .{ .module = mod, .name = name, .desc = desc };
    }

    fn parseImportDesc(self: *Parser) !types.ImportDesc {
        _ = try self.expect(.lparen);
        const keyword = try self.expectKeyword();
        _ = try self.optionalId(); // optional name (already collected)

        var result: types.ImportDesc = undefined;
        if (eql(keyword, "func")) {
            const type_idx = try self.parseTypeUse();
            result = .{ .func = type_idx };
        } else if (eql(keyword, "table")) {
            result = .{ .table = try self.parseTableType() };
        } else if (eql(keyword, "memory")) {
            result = .{ .mem = try self.parseMemType() };
        } else if (eql(keyword, "global")) {
            result = .{ .global = try self.parseGlobalType() };
        } else {
            return error.InvalidImportDesc;
        }

        // Reset local state (typeuse may have set it)
        self.local_names = .{};
        self.local_count = 0;

        _ = try self.expect(.rparen);
        return result;
    }

    const FuncResult = struct {
        type_idx: types.TypeIndex,
        code: types.Code,
    };

    fn visitFuncField(self: *Parser) !FuncResult {
        _ = try self.optionalId(); // func name (already collected)

        // Reset per-function state
        self.local_names = .{};
        self.local_count = 0;

        // Parse typeuse (sets up param local names)
        const type_idx = try self.parseTypeUse();

        // Parse locals
        var locals_list: ArrayList(types.Locals) = .empty;
        while (self.isAt(.lparen)) {
            const saved_pos = self.lexer.pos;
            const saved_current = self.current;
            _ = try self.expect(.lparen);
            if (self.isKeyword("local")) {
                try self.advance();
                if (self.isAt(.id)) {
                    // (local $name valtype)
                    const local_name = (try self.optionalId()).?;
                    const vt = try self.parseValType();
                    try self.local_names.put(self.allocator, local_name, self.local_count);
                    self.local_count += 1;
                    try locals_list.append(self.allocator, .{ .count = 1, .type = vt });
                } else {
                    // (local valtype*) - multiple anonymous locals
                    while (!self.isAt(.rparen)) {
                        const vt = try self.parseValType();
                        self.local_count += 1;
                        try locals_list.append(self.allocator, .{ .count = 1, .type = vt });
                    }
                }
                _ = try self.expect(.rparen);
            } else {
                // Not a local declaration; restore and break to parse instructions
                self.lexer.pos = saved_pos;
                self.current = saved_current;
                break;
            }
        }

        // Parse instruction body
        const body = try self.parseExpr();

        return .{
            .type_idx = type_idx,
            .code = .{
                .locals = try locals_list.toOwnedSlice(self.allocator),
                .body = body,
            },
        };
    }

    fn visitTableField(self: *Parser) !types.TableType {
        _ = try self.optionalId();
        return try self.parseTableType();
    }

    fn visitMemField(self: *Parser) !types.MemType {
        _ = try self.optionalId();
        return try self.parseMemType();
    }

    fn visitGlobalField(self: *Parser) !types.Global {
        _ = try self.optionalId();
        const gt = try self.parseGlobalType();
        const init_expr = try self.parseExpr();
        return .{ .type = gt, .init = init_expr };
    }

    fn visitExportField(self: *Parser) !types.Export {
        const name = try self.expectString();
        _ = try self.expect(.lparen);
        const desc_kw = try self.expectKeyword();

        var desc: types.ExportDesc = undefined;
        if (eql(desc_kw, "func")) {
            desc = .{ .func = try self.resolveFunc() };
        } else if (eql(desc_kw, "table")) {
            desc = .{ .table = try self.resolveTable() };
        } else if (eql(desc_kw, "memory")) {
            desc = .{ .mem = try self.resolveMem() };
        } else if (eql(desc_kw, "global")) {
            desc = .{ .global = try self.resolveGlobal() };
        } else {
            return error.InvalidExportDesc;
        }

        _ = try self.expect(.rparen);
        return .{ .name = name, .desc = desc };
    }

    fn visitElemField(self: *Parser) !types.Elem {
        // (elem tableidx? (offset expr) funcidx*)
        // tableidx is optional, defaults to 0
        var table_idx: u32 = 0;

        // Try to parse optional table index (number or $id before (offset ...))
        if (!self.isAt(.lparen)) {
            table_idx = try self.resolveTable();
        }

        // Parse offset expression
        _ = try self.expect(.lparen);

        var offset: []types.Instr = undefined;
        if (self.isKeyword("offset")) {
            try self.advance();
            offset = try self.parseExpr();
        } else {
            // Abbreviation: bare instruction instead of (offset ...)
            var instrs: ArrayList(types.Instr) = .empty;
            try self.parseOneInstr(&instrs);
            offset = try instrs.toOwnedSlice(self.allocator);
        }
        _ = try self.expect(.rparen);

        // Parse optional 'func' keyword (used in some WAT files)
        if (self.isKeyword("func")) {
            try self.advance();
        }

        // Parse function indices
        var init_list: ArrayList(types.FuncIndex) = .empty;
        while (!self.isAt(.rparen)) {
            const idx = try self.resolveFunc();
            try init_list.append(self.allocator, idx);
        }

        return .{
            .table = table_idx,
            .offset = offset,
            .init = try init_list.toOwnedSlice(self.allocator),
        };
    }

    fn visitDataField(self: *Parser) !types.Data {
        // (data memidx? (offset expr) datastring)
        var mem_idx: u32 = 0;

        // Try optional memory index
        if (!self.isAt(.lparen) and !self.isAt(.string)) {
            if (self.isAt(.integer) or self.isAt(.id)) {
                mem_idx = try self.resolveMem();
            }
        }

        // Parse offset expression
        _ = try self.expect(.lparen);

        var offset: []types.Instr = undefined;
        if (self.isKeyword("offset")) {
            try self.advance();
            offset = try self.parseExpr();
        } else {
            var instrs: ArrayList(types.Instr) = .empty;
            try self.parseOneInstr(&instrs);
            offset = try instrs.toOwnedSlice(self.allocator);
        }
        _ = try self.expect(.rparen);

        // Parse data string(s)
        var data_bytes: ArrayList(u8) = .empty;
        while (self.isAt(.string)) {
            const raw = try self.expectString();
            try self.decodeString(raw, &data_bytes);
        }

        return .{
            .mem = mem_idx,
            .offset = offset,
            .init = try data_bytes.toOwnedSlice(self.allocator),
        };
    }

    fn decodeString(self: *Parser, raw: []const u8, out: *ArrayList(u8)) !void {
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\') {
                i += 1;
                if (i >= raw.len) return error.InvalidEscape;
                switch (raw[i]) {
                    'n' => {
                        try out.append(self.allocator, '\n');
                        i += 1;
                    },
                    't' => {
                        try out.append(self.allocator, '\t');
                        i += 1;
                    },
                    'r' => {
                        try out.append(self.allocator, '\r');
                        i += 1;
                    },
                    '\\' => {
                        try out.append(self.allocator, '\\');
                        i += 1;
                    },
                    '\'' => {
                        try out.append(self.allocator, '\'');
                        i += 1;
                    },
                    '"' => {
                        try out.append(self.allocator, '"');
                        i += 1;
                    },
                    '0'...'9', 'a'...'f', 'A'...'F' => {
                        // Hex byte: \xx
                        if (i + 1 >= raw.len) return error.InvalidEscape;
                        const hi = std.fmt.charToDigit(raw[i], 16) catch return error.InvalidEscape;
                        const lo = std.fmt.charToDigit(raw[i + 1], 16) catch return error.InvalidEscape;
                        try out.append(self.allocator, (hi << 4) | lo);
                        i += 2;
                    },
                    else => return error.InvalidEscape,
                }
            } else {
                try out.append(self.allocator, raw[i]);
                i += 1;
            }
        }
    }

    /// Parse a sequence of instructions until ')' or block-end keyword.
    fn parseExpr(self: *Parser) anyerror![]types.Instr {
        var instrs: ArrayList(types.Instr) = .empty;
        while (self.current != null) {
            if (self.isAt(.rparen)) break;
            if (self.current) |tok| {
                switch (tok) {
                    .keyword => |kw| {
                        if (eql(kw, "end") or eql(kw, "else") or eql(kw, "then")) break;
                    },
                    else => {},
                }
            }

            try self.parseOneInstr(&instrs);
        }

        return instrs.toOwnedSlice(self.allocator);
    }

    fn parseOneInstr(self: *Parser, instrs: *ArrayList(types.Instr)) anyerror!void {
        if (self.isAt(.lparen)) {
            try self.parseFoldedInstr(instrs);
        } else {
            try self.parsePlainInstr(instrs);
        }
    }

    fn parsePlainInstr(self: *Parser, instrs: *ArrayList(types.Instr)) anyerror!void {
        const keyword = try self.expectKeyword();
        if (eql(keyword, "block")) {
            try self.parseBlock(instrs);
        } else if (eql(keyword, "loop")) {
            try self.parseLoop(instrs);
        } else if (eql(keyword, "if")) {
            try self.parseIf(instrs);
        } else {
            const instr = try self.parseInstr(keyword);
            try instrs.append(self.allocator, instr);
        }
    }

    fn parseFoldedInstr(self: *Parser, instrs: *ArrayList(types.Instr)) anyerror!void {
        _ = try self.expect(.lparen);
        const keyword = try self.expectKeyword();

        if (eql(keyword, "block")) {
            try self.parseFoldedBlock(instrs);
        } else if (eql(keyword, "loop")) {
            try self.parseFoldedLoop(instrs);
        } else if (eql(keyword, "if")) {
            try self.parseFoldedIf(instrs);
        } else {
            // Parse instruction immediate operands
            const instr = try self.parseInstr(keyword);

            // Parse sub-expressions (stack operands in parens)
            while (self.isAt(.lparen)) {
                try self.parseFoldedInstr(instrs);
            }

            try instrs.append(self.allocator, instr);
        }

        _ = try self.expect(.rparen);
    }

    // Block instructions (flat format)
    fn parseBlock(self: *Parser, instrs: *ArrayList(types.Instr)) anyerror!void {
        const label = try self.optionalId();
        const bt = try self.parseBlockType();
        try self.label_stack.append(self.allocator, label);
        const body = try self.parseBlockBody();
        _ = self.label_stack.pop();
        try self.expectKeywordExact("end");
        _ = try self.optionalId(); // optional end label
        try instrs.append(self.allocator, .{ .block = .{ .block_type = bt, .instructions = body } });
    }

    fn parseLoop(self: *Parser, instrs: *ArrayList(types.Instr)) anyerror!void {
        const label = try self.optionalId();
        const bt = try self.parseBlockType();
        try self.label_stack.append(self.allocator, label);
        const body = try self.parseBlockBody();
        _ = self.label_stack.pop();
        try self.expectKeywordExact("end");
        _ = try self.optionalId();
        try instrs.append(self.allocator, .{ .loop = .{ .block_type = bt, .instructions = body } });
    }

    fn parseIf(self: *Parser, instrs: *ArrayList(types.Instr)) anyerror!void {
        const label = try self.optionalId();
        const bt = try self.parseBlockType();
        try self.label_stack.append(self.allocator, label);

        // Parse then branch (instructions until else or end)
        const then_body = try self.parseBlockBodyUntilElse();

        var else_body: []types.Instr = &.{};
        if (self.isKeyword("else")) {
            try self.advance();
            _ = try self.optionalId(); // optional else label
            else_body = try self.parseBlockBody();
        }

        _ = self.label_stack.pop();
        try self.expectKeywordExact("end");
        _ = try self.optionalId();

        try instrs.append(self.allocator, .{ .@"if" = .{
            .block_type = bt,
            .then_instructions = then_body,
            .else_instructions = else_body,
        } });
    }

    // Block instructions (folded format)
    fn parseFoldedBlock(self: *Parser, instrs: *ArrayList(types.Instr)) anyerror!void {
        const label = try self.optionalId();
        const bt = try self.parseBlockType();
        try self.label_stack.append(self.allocator, label);
        const body = try self.parseExpr();
        _ = self.label_stack.pop();
        try instrs.append(self.allocator, .{ .block = .{ .block_type = bt, .instructions = body } });
    }

    fn parseFoldedLoop(self: *Parser, instrs: *ArrayList(types.Instr)) anyerror!void {
        const label = try self.optionalId();
        const bt = try self.parseBlockType();
        try self.label_stack.append(self.allocator, label);
        const body = try self.parseExpr();
        _ = self.label_stack.pop();
        try instrs.append(self.allocator, .{ .loop = .{ .block_type = bt, .instructions = body } });
    }

    fn parseFoldedIf(self: *Parser, instrs: *ArrayList(types.Instr)) anyerror!void {
        const label = try self.optionalId();
        const bt = try self.parseBlockType();
        try self.label_stack.append(self.allocator, label);

        // In folded if: condition expressions come first (folded)
        while (self.isAt(.lparen)) {
            // Peek to see if it's (then ...) or (else ...)
            const saved_pos = self.lexer.pos;
            const saved_current = self.current;
            _ = try self.expect(.lparen);
            const is_then = self.isKeyword("then");
            const is_else = self.isKeyword("else");
            self.lexer.pos = saved_pos;
            self.current = saved_current;
            if (is_then or is_else) break;
            try self.parseFoldedInstr(instrs);
        }

        var then_body: []types.Instr = &.{};
        var else_body: []types.Instr = &.{};

        if (self.isAt(.lparen)) {
            _ = try self.expect(.lparen);
            if (self.isKeyword("then")) {
                try self.advance();
                then_body = try self.parseExpr();
                _ = try self.expect(.rparen);
            }
        }

        if (self.isAt(.lparen)) {
            _ = try self.expect(.lparen);
            if (self.isKeyword("else")) {
                try self.advance();
                else_body = try self.parseExpr();
                _ = try self.expect(.rparen);
            }
        }

        _ = self.label_stack.pop();

        try instrs.append(self.allocator, .{ .@"if" = .{
            .block_type = bt,
            .then_instructions = then_body,
            .else_instructions = else_body,
        } });
    }

    fn parseBlockBody(self: *Parser) anyerror![]types.Instr {
        var instrs: ArrayList(types.Instr) = .empty;
        while (self.current != null) {
            if (self.isAt(.rparen)) break;
            if (self.isKeyword("end")) break;
            try self.parseOneInstr(&instrs);
        }
        return instrs.toOwnedSlice(self.allocator);
    }

    fn parseBlockBodyUntilElse(self: *Parser) anyerror![]types.Instr {
        var instrs: ArrayList(types.Instr) = .empty;
        while (self.current != null) {
            if (self.isAt(.rparen)) break;
            if (self.isKeyword("end")) break;
            if (self.isKeyword("else")) break;
            try self.parseOneInstr(&instrs);
        }
        return instrs.toOwnedSlice(self.allocator);
    }

    fn parseMemArg(self: *Parser, natural_align: u32) !types.MemoryInstrArg {
        var offset: u32 = 0;
        var alignment: u32 = natural_align;

        // Parse offset=N and align=N (as keyword tokens like "offset=4")
        while (self.current != null) {
            if (self.current) |tok| {
                switch (tok) {
                    .keyword => |kw| {
                        if (startsWith(kw, "offset=")) {
                            const val_str = kw[7..];
                            if (startsWith(val_str, "0x")) {
                                offset = std.fmt.parseInt(u32, val_str[2..], 16) catch return error.InvalidMemArg;
                            } else {
                                offset = std.fmt.parseInt(u32, val_str, 10) catch return error.InvalidMemArg;
                            }
                            try self.advance();
                            continue;
                        } else if (startsWith(kw, "align=")) {
                            const val_str = kw[6..];
                            if (startsWith(val_str, "0x")) {
                                alignment = std.fmt.parseInt(u32, val_str[2..], 16) catch return error.InvalidMemArg;
                            } else {
                                alignment = std.fmt.parseInt(u32, val_str, 10) catch return error.InvalidMemArg;
                            }
                            try self.advance();
                            continue;
                        }
                    },
                    else => {},
                }
            }
            break;
        }

        // Convert alignment to log2 (binary format uses log2)
        const align_log2 = std.math.log2_int(u32, alignment);

        return .{ .alignment = align_log2, .offset = offset };
    }

    fn parseI32(self: *Parser) !i32 {
        const tok = try self.peek();
        switch (tok) {
            .integer => |int| {
                try self.advance();
                if (int.is_signed) {
                    return @intCast(-@as(i64, @intCast(int.value)));
                }
                return @bitCast(@as(u32, @intCast(int.value)));
            },
            else => return error.ExpectedInteger,
        }
    }

    fn parseI64(self: *Parser) !i64 {
        const tok = try self.peek();
        switch (tok) {
            .integer => |int| {
                try self.advance();
                if (int.is_signed) {
                    return -@as(i64, @intCast(int.value));
                }
                return @bitCast(int.value);
            },
            else => return error.ExpectedInteger,
        }
    }

    fn parseF32(self: *Parser) !f32 {
        const tok = try self.peek();
        switch (tok) {
            .float => |f| {
                try self.advance();
                const f64_val: f64 = @bitCast(f.value);
                return @floatCast(f64_val);
            },
            .integer => |int| {
                try self.advance();
                const val: f32 = @floatFromInt(int.value);
                if (int.is_signed) return -val;
                return val;
            },
            else => return error.ExpectedNumber,
        }
    }

    fn parseF64(self: *Parser) !f64 {
        const tok = try self.peek();
        switch (tok) {
            .float => |f| {
                try self.advance();
                return @bitCast(f.value);
            },
            .integer => |int| {
                try self.advance();
                const val: f64 = @floatFromInt(int.value);
                if (int.is_signed) return -val;
                return val;
            },
            else => return error.ExpectedNumber,
        }
    }

    const InstrTag = enum {
        // Control
        call,
        // Branches
        br,
        br_if,
        // Locals
        local_get,
        local_set,
        local_tee,
        // Globals
        global_get,
        global_set,
        // Memory loads
        i32_load,
        i64_load,
        f32_load,
        f64_load,
        i32_load8_s,
        i32_load8_u,
        i32_load16_s,
        i32_load16_u,
        i64_load8_s,
        i64_load8_u,
        i64_load16_s,
        i64_load16_u,
        i64_load32_s,
        i64_load32_u,
        // Memory stores
        i32_store,
        i64_store,
        f32_store,
        f64_store,
        i32_store8,
        i32_store16,
        i64_store8,
        i64_store16,
        i64_store32,
        // Memory ops
        memory_size,
        memory_grow,

        fn toInstrWithFuncIdx(self: InstrTag, idx: u32) types.Instr {
            return switch (self) {
                .call => .{ .call = idx },
                else => unreachable,
            };
        }

        fn toInstrWithLabelIdx(self: InstrTag, idx: u32) types.Instr {
            return switch (self) {
                .br => .{ .br = idx },
                .br_if => .{ .br_if = idx },
                else => unreachable,
            };
        }

        fn toInstrWithLocalIdx(self: InstrTag, idx: u32) types.Instr {
            return switch (self) {
                .local_get => .{ .local_get = idx },
                .local_set => .{ .local_set = idx },
                .local_tee => .{ .local_tee = idx },
                else => unreachable,
            };
        }

        fn toInstrWithGlobalIdx(self: InstrTag, idx: u32) types.Instr {
            return switch (self) {
                .global_get => .{ .global_get = idx },
                .global_set => .{ .global_set = idx },
                else => unreachable,
            };
        }

        fn toInstrWithMemArg(self: InstrTag, arg: types.MemoryInstrArg) types.Instr {
            return switch (self) {
                .i32_load => .{ .i32_load = arg },
                .i64_load => .{ .i64_load = arg },
                .f32_load => .{ .f32_load = arg },
                .f64_load => .{ .f64_load = arg },
                .i32_load8_s => .{ .i32_load8_s = arg },
                .i32_load8_u => .{ .i32_load8_u = arg },
                .i32_load16_s => .{ .i32_load16_s = arg },
                .i32_load16_u => .{ .i32_load16_u = arg },
                .i64_load8_s => .{ .i64_load8_s = arg },
                .i64_load8_u => .{ .i64_load8_u = arg },
                .i64_load16_s => .{ .i64_load16_s = arg },
                .i64_load16_u => .{ .i64_load16_u = arg },
                .i64_load32_s => .{ .i64_load32_s = arg },
                .i64_load32_u => .{ .i64_load32_u = arg },
                .i32_store => .{ .i32_store = arg },
                .i64_store => .{ .i64_store = arg },
                .f32_store => .{ .f32_store = arg },
                .f64_store => .{ .f64_store = arg },
                .i32_store8 => .{ .i32_store8 = arg },
                .i32_store16 => .{ .i32_store16 = arg },
                .i64_store8 => .{ .i64_store8 = arg },
                .i64_store16 => .{ .i64_store16 = arg },
                .i64_store32 => .{ .i64_store32 = arg },
                else => unreachable,
            };
        }

        fn toInstrWithMemIdx(self: InstrTag, idx: u32) types.Instr {
            return switch (self) {
                .memory_size => .{ .memory_size = idx },
                .memory_grow => .{ .memory_grow = idx },
                else => unreachable,
            };
        }
    };

    const InstrHandler = union(enum) {
        simple: types.Instr,
        func_idx: InstrTag,
        label_idx: InstrTag,
        local_idx: InstrTag,
        global_idx: InstrTag,
        i32_value,
        i64_value,
        f32_value,
        f64_value,
        mem_arg_1: InstrTag, // 1-byte natural alignment
        mem_arg_2: InstrTag, // 2-byte natural alignment
        mem_arg_4: InstrTag, // 4-byte natural alignment
        mem_arg_8: InstrTag, // 8-byte natural alignment
        mem_idx: InstrTag,
        call_indirect,
        br_table,
    };

    const instr_map = std.StaticStringMap(InstrHandler).initComptime(.{
        // Control instructions
        .{ "call", InstrHandler{ .func_idx = .call } },
        .{ "call_indirect", InstrHandler.call_indirect },
        .{ "br", InstrHandler{ .label_idx = .br } },
        .{ "br_if", InstrHandler{ .label_idx = .br_if } },
        .{ "br_table", InstrHandler.br_table },
        // Variable instructions
        .{ "local.get", InstrHandler{ .local_idx = .local_get } },
        .{ "local.set", InstrHandler{ .local_idx = .local_set } },
        .{ "local.tee", InstrHandler{ .local_idx = .local_tee } },
        .{ "global.get", InstrHandler{ .global_idx = .global_get } },
        .{ "global.set", InstrHandler{ .global_idx = .global_set } },
        // Const instructions
        .{ "i32.const", InstrHandler.i32_value },
        .{ "i64.const", InstrHandler.i64_value },
        .{ "f32.const", InstrHandler.f32_value },
        .{ "f64.const", InstrHandler.f64_value },
        // Memory load instructions
        .{ "i32.load", InstrHandler{ .mem_arg_4 = .i32_load } },
        .{ "i64.load", InstrHandler{ .mem_arg_8 = .i64_load } },
        .{ "f32.load", InstrHandler{ .mem_arg_4 = .f32_load } },
        .{ "f64.load", InstrHandler{ .mem_arg_8 = .f64_load } },
        .{ "i32.load8_s", InstrHandler{ .mem_arg_1 = .i32_load8_s } },
        .{ "i32.load8_u", InstrHandler{ .mem_arg_1 = .i32_load8_u } },
        .{ "i32.load16_s", InstrHandler{ .mem_arg_2 = .i32_load16_s } },
        .{ "i32.load16_u", InstrHandler{ .mem_arg_2 = .i32_load16_u } },
        .{ "i64.load8_s", InstrHandler{ .mem_arg_1 = .i64_load8_s } },
        .{ "i64.load8_u", InstrHandler{ .mem_arg_1 = .i64_load8_u } },
        .{ "i64.load16_s", InstrHandler{ .mem_arg_2 = .i64_load16_s } },
        .{ "i64.load16_u", InstrHandler{ .mem_arg_2 = .i64_load16_u } },
        .{ "i64.load32_s", InstrHandler{ .mem_arg_4 = .i64_load32_s } },
        .{ "i64.load32_u", InstrHandler{ .mem_arg_4 = .i64_load32_u } },
        // Memory store instructions
        .{ "i32.store", InstrHandler{ .mem_arg_4 = .i32_store } },
        .{ "i64.store", InstrHandler{ .mem_arg_8 = .i64_store } },
        .{ "f32.store", InstrHandler{ .mem_arg_4 = .f32_store } },
        .{ "f64.store", InstrHandler{ .mem_arg_8 = .f64_store } },
        .{ "i32.store8", InstrHandler{ .mem_arg_1 = .i32_store8 } },
        .{ "i32.store16", InstrHandler{ .mem_arg_2 = .i32_store16 } },
        .{ "i64.store8", InstrHandler{ .mem_arg_1 = .i64_store8 } },
        .{ "i64.store16", InstrHandler{ .mem_arg_2 = .i64_store16 } },
        .{ "i64.store32", InstrHandler{ .mem_arg_4 = .i64_store32 } },
        // Memory size/grow
        .{ "memory.size", InstrHandler{ .mem_idx = .memory_size } },
        .{ "memory.grow", InstrHandler{ .mem_idx = .memory_grow } },
        // Simple instructions (no immediates)
        .{ "unreachable", InstrHandler{ .simple = .@"unreachable" } },
        .{ "return", InstrHandler{ .simple = .@"return" } },
        .{ "nop", InstrHandler{ .simple = .nop } },
        .{ "drop", InstrHandler{ .simple = .drop } },
        .{ "select", InstrHandler{ .simple = .select } },
        // Comparison - i32
        .{ "i32.eqz", InstrHandler{ .simple = .i32_eqz } },
        .{ "i32.eq", InstrHandler{ .simple = .i32_eq } },
        .{ "i32.ne", InstrHandler{ .simple = .i32_ne } },
        .{ "i32.lt_s", InstrHandler{ .simple = .i32_lt_s } },
        .{ "i32.lt_u", InstrHandler{ .simple = .i32_lt_u } },
        .{ "i32.gt_s", InstrHandler{ .simple = .i32_gt_s } },
        .{ "i32.gt_u", InstrHandler{ .simple = .i32_gt_u } },
        .{ "i32.le_s", InstrHandler{ .simple = .i32_le_s } },
        .{ "i32.le_u", InstrHandler{ .simple = .i32_le_u } },
        .{ "i32.ge_s", InstrHandler{ .simple = .i32_ge_s } },
        .{ "i32.ge_u", InstrHandler{ .simple = .i32_ge_u } },
        // Comparison - i64
        .{ "i64.eqz", InstrHandler{ .simple = .i64_eqz } },
        .{ "i64.eq", InstrHandler{ .simple = .i64_eq } },
        .{ "i64.ne", InstrHandler{ .simple = .i64_ne } },
        .{ "i64.lt_s", InstrHandler{ .simple = .i64_lt_s } },
        .{ "i64.lt_u", InstrHandler{ .simple = .i64_lt_u } },
        .{ "i64.gt_s", InstrHandler{ .simple = .i64_gt_s } },
        .{ "i64.gt_u", InstrHandler{ .simple = .i64_gt_u } },
        .{ "i64.le_s", InstrHandler{ .simple = .i64_le_s } },
        .{ "i64.le_u", InstrHandler{ .simple = .i64_le_u } },
        .{ "i64.ge_s", InstrHandler{ .simple = .i64_ge_s } },
        .{ "i64.ge_u", InstrHandler{ .simple = .i64_ge_u } },
        // Comparison - f32
        .{ "f32.eq", InstrHandler{ .simple = .f32_eq } },
        .{ "f32.ne", InstrHandler{ .simple = .f32_ne } },
        .{ "f32.lt", InstrHandler{ .simple = .f32_lt } },
        .{ "f32.gt", InstrHandler{ .simple = .f32_gt } },
        .{ "f32.le", InstrHandler{ .simple = .f32_le } },
        .{ "f32.ge", InstrHandler{ .simple = .f32_ge } },
        // Comparison - f64
        .{ "f64.eq", InstrHandler{ .simple = .f64_eq } },
        .{ "f64.ne", InstrHandler{ .simple = .f64_ne } },
        .{ "f64.lt", InstrHandler{ .simple = .f64_lt } },
        .{ "f64.gt", InstrHandler{ .simple = .f64_gt } },
        .{ "f64.le", InstrHandler{ .simple = .f64_le } },
        .{ "f64.ge", InstrHandler{ .simple = .f64_ge } },
        // Arithmetic - i32
        .{ "i32.clz", InstrHandler{ .simple = .i32_clz } },
        .{ "i32.ctz", InstrHandler{ .simple = .i32_ctz } },
        .{ "i32.popcnt", InstrHandler{ .simple = .i32_popcnt } },
        .{ "i32.add", InstrHandler{ .simple = .i32_add } },
        .{ "i32.sub", InstrHandler{ .simple = .i32_sub } },
        .{ "i32.mul", InstrHandler{ .simple = .i32_mul } },
        .{ "i32.div_s", InstrHandler{ .simple = .i32_div_s } },
        .{ "i32.div_u", InstrHandler{ .simple = .i32_div_u } },
        .{ "i32.rem_s", InstrHandler{ .simple = .i32_rem_s } },
        .{ "i32.rem_u", InstrHandler{ .simple = .i32_rem_u } },
        .{ "i32.and", InstrHandler{ .simple = .i32_and } },
        .{ "i32.or", InstrHandler{ .simple = .i32_or } },
        .{ "i32.xor", InstrHandler{ .simple = .i32_xor } },
        .{ "i32.shl", InstrHandler{ .simple = .i32_shl } },
        .{ "i32.shr_s", InstrHandler{ .simple = .i32_shr_s } },
        .{ "i32.shr_u", InstrHandler{ .simple = .i32_shr_u } },
        .{ "i32.rotl", InstrHandler{ .simple = .i32_rotl } },
        .{ "i32.rotr", InstrHandler{ .simple = .i32_rotr } },
        // Arithmetic - i64
        .{ "i64.clz", InstrHandler{ .simple = .i64_clz } },
        .{ "i64.ctz", InstrHandler{ .simple = .i64_ctz } },
        .{ "i64.popcnt", InstrHandler{ .simple = .i64_popcnt } },
        .{ "i64.add", InstrHandler{ .simple = .i64_add } },
        .{ "i64.sub", InstrHandler{ .simple = .i64_sub } },
        .{ "i64.mul", InstrHandler{ .simple = .i64_mul } },
        .{ "i64.div_s", InstrHandler{ .simple = .i64_div_s } },
        .{ "i64.div_u", InstrHandler{ .simple = .i64_div_u } },
        .{ "i64.rem_s", InstrHandler{ .simple = .i64_rem_s } },
        .{ "i64.rem_u", InstrHandler{ .simple = .i64_rem_u } },
        .{ "i64.and", InstrHandler{ .simple = .i64_and } },
        .{ "i64.or", InstrHandler{ .simple = .i64_or } },
        .{ "i64.xor", InstrHandler{ .simple = .i64_xor } },
        .{ "i64.shl", InstrHandler{ .simple = .i64_shl } },
        .{ "i64.shr_s", InstrHandler{ .simple = .i64_shr_s } },
        .{ "i64.shr_u", InstrHandler{ .simple = .i64_shr_u } },
        .{ "i64.rotl", InstrHandler{ .simple = .i64_rotl } },
        .{ "i64.rotr", InstrHandler{ .simple = .i64_rotr } },
        // Arithmetic - f32
        .{ "f32.abs", InstrHandler{ .simple = .f32_abs } },
        .{ "f32.neg", InstrHandler{ .simple = .f32_neg } },
        .{ "f32.ceil", InstrHandler{ .simple = .f32_ceil } },
        .{ "f32.floor", InstrHandler{ .simple = .f32_floor } },
        .{ "f32.trunc", InstrHandler{ .simple = .f32_trunc } },
        .{ "f32.nearest", InstrHandler{ .simple = .f32_nearest } },
        .{ "f32.sqrt", InstrHandler{ .simple = .f32_sqrt } },
        .{ "f32.add", InstrHandler{ .simple = .f32_add } },
        .{ "f32.sub", InstrHandler{ .simple = .f32_sub } },
        .{ "f32.mul", InstrHandler{ .simple = .f32_mul } },
        .{ "f32.div", InstrHandler{ .simple = .f32_div } },
        .{ "f32.min", InstrHandler{ .simple = .f32_min } },
        .{ "f32.max", InstrHandler{ .simple = .f32_max } },
        .{ "f32.copysign", InstrHandler{ .simple = .f32_copysign } },
        // Arithmetic - f64
        .{ "f64.abs", InstrHandler{ .simple = .f64_abs } },
        .{ "f64.neg", InstrHandler{ .simple = .f64_neg } },
        .{ "f64.ceil", InstrHandler{ .simple = .f64_ceil } },
        .{ "f64.floor", InstrHandler{ .simple = .f64_floor } },
        .{ "f64.trunc", InstrHandler{ .simple = .f64_trunc } },
        .{ "f64.nearest", InstrHandler{ .simple = .f64_nearest } },
        .{ "f64.sqrt", InstrHandler{ .simple = .f64_sqrt } },
        .{ "f64.add", InstrHandler{ .simple = .f64_add } },
        .{ "f64.sub", InstrHandler{ .simple = .f64_sub } },
        .{ "f64.mul", InstrHandler{ .simple = .f64_mul } },
        .{ "f64.div", InstrHandler{ .simple = .f64_div } },
        .{ "f64.min", InstrHandler{ .simple = .f64_min } },
        .{ "f64.max", InstrHandler{ .simple = .f64_max } },
        .{ "f64.copysign", InstrHandler{ .simple = .f64_copysign } },
        // Conversions
        .{ "i32.wrap_i64", InstrHandler{ .simple = .i32_wrap_i64 } },
        .{ "i32.trunc_f32_s", InstrHandler{ .simple = .i32_trunc_f32_s } },
        .{ "i32.trunc_f32_u", InstrHandler{ .simple = .i32_trunc_f32_u } },
        .{ "i32.trunc_f64_s", InstrHandler{ .simple = .i32_trunc_f64_s } },
        .{ "i32.trunc_f64_u", InstrHandler{ .simple = .i32_trunc_f64_u } },
        .{ "i64.extend_i32_s", InstrHandler{ .simple = .i64_extend_i32_s } },
        .{ "i64.extend_i32_u", InstrHandler{ .simple = .i64_extend_i32_u } },
        .{ "i64.trunc_f32_s", InstrHandler{ .simple = .i64_trunc_f32_s } },
        .{ "i64.trunc_f32_u", InstrHandler{ .simple = .i64_trunc_f32_u } },
        .{ "i64.trunc_f64_s", InstrHandler{ .simple = .i64_trunc_f64_s } },
        .{ "i64.trunc_f64_u", InstrHandler{ .simple = .i64_trunc_f64_u } },
        .{ "f32.convert_i32_s", InstrHandler{ .simple = .f32_convert_i32_s } },
        .{ "f32.convert_i32_u", InstrHandler{ .simple = .f32_convert_i32_u } },
        .{ "f32.convert_i64_s", InstrHandler{ .simple = .f32_convert_i64_s } },
        .{ "f32.convert_i64_u", InstrHandler{ .simple = .f32_convert_i64_u } },
        .{ "f32.demote_f64", InstrHandler{ .simple = .f32_demote_f64 } },
        .{ "f64.convert_i32_s", InstrHandler{ .simple = .f64_convert_i32_s } },
        .{ "f64.convert_i32_u", InstrHandler{ .simple = .f64_convert_i32_u } },
        .{ "f64.convert_i64_s", InstrHandler{ .simple = .f64_convert_i64_s } },
        .{ "f64.convert_i64_u", InstrHandler{ .simple = .f64_convert_i64_u } },
        .{ "f64.promote_f32", InstrHandler{ .simple = .f64_promote_f32 } },
        .{ "i32.reinterpret_f32", InstrHandler{ .simple = .i32_reinterpret_f32 } },
        .{ "i64.reinterpret_f64", InstrHandler{ .simple = .i64_reinterpret_f64 } },
        .{ "f32.reinterpret_i32", InstrHandler{ .simple = .f32_reinterpret_i32 } },
        .{ "f64.reinterpret_i64", InstrHandler{ .simple = .f64_reinterpret_i64 } },
    });

    fn parseInstr(self: *Parser, keyword: []const u8) !types.Instr {
        const handler = instr_map.get(keyword) orelse return error.UnknownInstruction;

        return switch (handler) {
            .simple => |instr| instr,
            .func_idx => |tag| tag.toInstrWithFuncIdx(try self.resolveFunc()),
            .label_idx => |tag| tag.toInstrWithLabelIdx(try self.resolveLabel()),
            .local_idx => |tag| tag.toInstrWithLocalIdx(try self.resolveLocal()),
            .global_idx => |tag| tag.toInstrWithGlobalIdx(try self.resolveGlobal()),
            .i32_value => .{ .i32_const = try self.parseI32() },
            .i64_value => .{ .i64_const = try self.parseI64() },
            .f32_value => .{ .f32_const = try self.parseF32() },
            .f64_value => .{ .f64_const = try self.parseF64() },
            .mem_arg_1 => |tag| tag.toInstrWithMemArg(try self.parseMemArg(1)),
            .mem_arg_2 => |tag| tag.toInstrWithMemArg(try self.parseMemArg(2)),
            .mem_arg_4 => |tag| tag.toInstrWithMemArg(try self.parseMemArg(4)),
            .mem_arg_8 => |tag| tag.toInstrWithMemArg(try self.parseMemArg(8)),
            .mem_idx => |tag| tag.toInstrWithMemIdx(0),
            .call_indirect => try self.parseCallIndirect(),
            .br_table => try self.parseBrTable(),
        };
    }

    fn parseCallIndirect(self: *Parser) !types.Instr {
        // call_indirect (type idx) or call_indirect idx
        var type_idx: u32 = 0;
        if (self.isAt(.lparen)) {
            _ = try self.expect(.lparen);
            try self.expectKeywordExact("type");
            type_idx = try self.resolveType();
            _ = try self.expect(.rparen);
        } else {
            type_idx = try self.resolveType();
        }
        return .{ .call_indirect = .{ .type_idx = type_idx, .table_idx = 0 } };
    }

    fn parseBrTable(self: *Parser) !types.Instr {
        var labels: ArrayList(types.LabelIndex) = .empty;

        // Parse all label indices
        while (self.isAt(.integer) or self.isAt(.id)) {
            const idx = try self.resolveLabel();
            try labels.append(self.allocator, idx);
        }

        if (labels.items.len == 0) return error.InvalidBrTable;

        // Last one is the default
        const default_idx = labels.pop().?;
        return .{ .br_table = .{
            .label_indices = try labels.toOwnedSlice(self.allocator),
            .default_idx = default_idx,
        } };
    }
};
