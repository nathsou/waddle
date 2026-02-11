const std = @import("std");
const types = @import("types.zig");

pub const Token = union(enum) {
    @"(",
    @")",
    id: []const u8,
    keyword: []const u8,
    integer: IntegerLiteral,
    float: FloatLiteral,
    string: []const u8,

    pub fn format(self: Token, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .@"(" => try writer.writeAll("("),
            .@")" => try writer.writeAll(")"),
            .id => |s| try writer.print("${s}", .{s}),
            .keyword => |s| try writer.writeAll(s),
            .integer => |int| {
                if (int.is_hex) {
                    if (int.is_signed) {
                        try writer.print("0x{x}", .{int.value});
                    } else {
                        try writer.print("0x{x}", .{int.value});
                    }
                } else {
                    if (int.is_signed) {
                        try writer.print("{d}", .{@as(i64, @bitCast(int.value))});
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

/// A lexer for WebAssembly Text Format (WAT).
/// string slices stored in tokens point to the original source, so they are valid as long as the source is valid.
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

    fn matches(self: *Lexer, s: []const u8, offset: usize) bool {
        if (self.pos + offset + s.len > self.source.len) {
            return false;
        }

        for (s, 0..) |c, i| {
            if (self.source[self.pos + offset + i] != c) {
                return false;
            }
        }

        return true;
    }

    fn isIdChar(c: u8) bool {
        return switch (c) {
            '0'...'9', 'A'...'Z', 'a'...'z' => true,
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '/' => true,
            ':', '<', '=', '>', '?', '@', '\\', '^', '_', '`', '|', '~' => true,
            else => false,
        };
    }

    fn isStringChar(c: u8) bool {
        if (c >= 0x20 and c != 0x7F and c != '"' and c != '\\') {
            return true;
        }

        // TODO: Support unicode characters
        return switch (c) {
            '\t', '\n', '\r', '"', '\'', '\\' => true,
            else => false,
        };
    }

    fn isLineCommentChar(c: u8) bool {
        return c != '\n' and c != '\r';
    }

    fn skipWhitespacesAndComments(self: *Lexer) !void {
        while (self.pos < self.source.len) {
            const char = self.source[self.pos];

            switch (char) {
                ' ', '\n', '\r', '\t' => {
                    self.pos += 1;
                },
                ';' => {
                    if (self.matches(";", 1)) {
                        self.pos += 2; // Skip ";;"

                        // line comment
                        while (self.advance()) |c| {
                            if (!isLineCommentChar(c)) {
                                break;
                            }
                        }
                    } else {
                        break;
                    }
                },
                '(' => {
                    if (self.matches(";", 1)) {
                        // block comment
                        self.pos += 2; // Skip "(;"
                        var depth: usize = 1;

                        while (self.pos < self.source.len) {
                            const c = self.source[self.pos];

                            if (c == '(' and self.matches(";", 1)) {
                                depth += 1;
                                self.pos += 2;
                            } else if (c == ';' and self.matches(")", 1)) {
                                depth -= 1;
                                self.pos += 2;

                                if (depth == 0) {
                                    break;
                                }
                            } else {
                                _ = self.advance();
                            }
                        }
                    } else if (self.matches("@", 1)) {
                        // annotation
                        self.pos += 2; // Skip "(@"
                        var depth: usize = 1;

                        while (self.pos < self.source.len) {
                            const c = self.source[self.pos];

                            if (c == '(') {
                                depth += 1;
                                self.pos += 1;
                            } else if (c == ')') {
                                depth -= 1;
                                self.pos += 1;

                                if (depth == 0) {
                                    break;
                                }
                            } else {
                                _ = self.advance();
                            }
                        }
                    } else {
                        break;
                    }
                },
                else => break,
            }
        }
    }

    fn parseDigit(c: u8, is_hex: bool) ?u8 {
        if (is_hex) {
            return switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => null,
            };
        } else {
            if (c >= '0' and c <= '9') {
                return c - '0';
            } else {
                return null;
            }
        }
    }

    fn parseInteger(self: *Lexer, is_signed: bool, is_hex: bool) !IntegerLiteral {
        var value: u64 = 0;

        while (self.advance()) |c| {
            if (parseDigit(c, is_hex)) |digit| {
                const res1 = @mulWithOverflow(value, @as(u64, if (is_hex) 16 else 10));

                if (res1[1] == 1) {
                    return error.IntegerOverflow;
                }

                const res2 = @addWithOverflow(res1[0], digit);

                if (res2[1] == 1) {
                    return error.IntegerOverflow;
                }

                value = res2[0];
            } else {
                break;
            }
        }

        return IntegerLiteral{
            .value = value,
            .is_signed = is_signed,
            .is_hex = is_hex,
        };
    }

    fn span(self: *Lexer, start: usize, token: Token) TokenSpan {
        return TokenSpan{
            .span = Span{
                .start = start,
                .end = self.pos,
            },
            .token = token,
        };
    }

    pub fn next(self: *Lexer) !?TokenSpan {
        if (self.pos >= self.source.len) {
            return null;
        }

        try self.skipWhitespacesAndComments();

        if (self.pos >= self.source.len) {
            return null;
        }

        const char = self.source[self.pos];
        const start = self.pos;

        switch (char) {
            '(' => {
                self.pos += 1;
                return self.span(start, .@"(");
            },
            ')' => {
                self.pos += 1;
                return self.span(start, .@")");
            },
            '$', 'a'...'z' => {
                const is_id = char == '$';

                while (self.advance()) |c| {
                    if (!isIdChar(c)) {
                        break;
                    }
                }

                if (is_id) {
                    return self.span(start, .{ .id = self.source[start + 1 .. self.pos] });
                } else {
                    return self.span(start, .{ .keyword = self.source[start..self.pos] });
                }
            },
            '"' => {
                var escaped = false;

                while (self.advance()) |c| {
                    if (escaped) {
                        escaped = false;
                    } else if (c == '\\') {
                        escaped = true;
                    } else if (c == '"') {
                        self.pos += 1; // Skip closing quote
                        break;
                    }
                }

                return self.span(start, .{ .string = self.source[start + 1 .. self.pos - 1] });
            },
            '-', '+', '0'...'9' => {
                var is_signed = false;
                var is_hex = false;

                if (char == '-' or char == '+') {
                    is_signed = char == '-';
                    self.pos += 1; // Skip sign
                }

                if (self.matches("0x", 0)) {
                    self.pos += 2; // Skip "0x"
                    is_hex = true;
                }

                const int = try self.parseInteger(is_signed, is_hex);
                return self.span(start, .{ .integer = int });
            },
            else => {
                std.debug.print("Unexpected character: '{c}' (code {d}) \n", .{ char, char });
                return error.UnexpectedCharacter;
            },
        }
    }
};
