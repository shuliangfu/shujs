// 语法分析（若抽成独立模块）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1

const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;

/// 语法分析器占位，可消费 Lexer 产出 AST
pub const Parser = struct {
    lexer: Lexer,

    /// 用给定源码构造 Parser，不拷贝 source
    pub fn init(source: []const u8) Parser {
        return .{ .lexer = .{ .source = source } };
    }

    /// 执行语法分析（占位，后续产出 AST）
    pub fn parse(self: *Parser) !void {
        _ = self;
        // TODO: 产出 AST
    }
};
