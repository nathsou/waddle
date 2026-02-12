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

        return std.mem.eql(u8, self.source[self.pos .. self.pos + s.len], s);
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

const ModuleFieldType = enum {
    type,
    import,
    func,
    table,
    memory,
    global,
    @"export",
    start,
    elem,
    data,
};

pub const Index = union(enum) {
    x: u32,
    id: []const u8,
};

pub const Module = struct {
    name: ?[]const u8,
    ids: std.hash_map.StringHashMap(usize),
    types: ArrayList(types.FuncType),

    fn init(allocator: std.mem.Allocator, name: ?[]const u8) !Module {
        return Module{
            .name = name,
            .ids = .init(allocator),
            .types = .empty,
        };
    }

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        self.ids.deinit();

        for (self.types.items) |ty| {
            ty.deinit(allocator);
        }

        self.types.deinit(allocator);
    }
};

pub const Parser = struct {
    lexer: Lexer,
    current: ?Token,
    allocator: std.mem.Allocator,

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
            std.debug.print("advance: {any}\n", .{t.token});
            self.current = t.token;
        } else {
            self.current = null;
        }
    }

    fn peek(self: *Parser) !Token {
        return self.current orelse return error.UnexpectedEOF;
    }

    fn expect(self: *Parser, tt: TokenType) !Token {
        const token = try self.peek();

        if (std.meta.activeTag(token) != tt) {
            std.debug.print("Expected token type: {any}, found: {any}\n", .{ tt, token });
            return error.UnexpectedToken;
        }

        try self.advance();

        return token;
    }

    fn expectKeyword(self: *Parser, kw: []const u8) !void {
        const token = try self.peek();

        switch (token) {
            .keyword => |s| {
                if (!std.mem.eql(u8, s, kw)) {
                    std.debug.print("Expected keyword: {s}, found: {s}\n", .{ kw, s });
                    return error.UnexpectedKeyword;
                }
            },
            else => return error.ExpectedKeyword,
        }

        try self.advance();
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

    pub fn parseModule(self: *Parser) !Module {
        _ = try self.expect(.lparen);
        try self.expectKeyword("module");
        const name = try self.optionalId();
        var module = try Module.init(self.allocator, name);

        while (try self.visitModuleField(&module)) {}

        _ = try self.expect(.rparen);

        return module;
    }

    fn visitModuleField(self: *Parser, module: *Module) !bool {
        if (try self.optional(.lparen)) |_| {
            const field_type = try self.expect(.keyword);

            if (std.meta.stringToEnum(ModuleFieldType, field_type.keyword)) |ft| {
                switch (ft) {
                    .type => {
                        try self.visitTypeField(module);
                    },
                    else => {
                        return error.ModuleFieldNotSupportedYet;
                    },
                }
            } else {
                return error.UnknownModuleField;
            }

            _ = try self.expect(.rparen);

            return true;
        }

        return false;
    }

    fn parseValType(self: *Parser) !types.ValType {
        const token = try self.expect(.keyword);
        return std.meta.stringToEnum(types.ValType, token.keyword) orelse return error.UnknownValType;
    }

    fn parseFuncType(self: *Parser) !types.FuncType {
        _ = try self.expect(.lparen);
        try self.expectKeyword("func");

        var params: ArrayList(types.ValType) = .empty;
        var results: ArrayList(types.ValType) = .empty;

        while (try self.optional(.lparen)) |_| {
            const keyword = (try self.expect(.keyword)).keyword;

            if (std.mem.eql(u8, keyword, "param")) {
                if (results.items.len > 0) {
                    // all params must be defined before any results.
                    return error.InvalidFuncType;
                }

                _ = try self.optionalId();
                const ty = try self.parseValType();
                try params.append(self.allocator, ty);
            } else if (std.mem.eql(u8, keyword, "result")) {
                const ty = try self.parseValType();
                try results.append(self.allocator, ty);
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

    fn visitTypeField(self: *Parser, module: *Module) !void {
        const id = try self.optionalId();
        const func_ty = try self.parseFuncType();

        if (id) |name| {
            try module.ids.put(name, module.types.items.len);
        }

        try module.types.append(self.allocator, func_ty);
    }
};
