// 词法分析（若抽成独立模块）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1

const std = @import("std");

/// 词法分析器占位
pub const Lexer = struct {
    source: []const u8,
    pos: usize = 0,

    /// 取下一个字节，已到末尾返回 null
    pub fn next(self: *Lexer) ?u8 {
        if (self.pos >= self.source.len) return null;
        const c = self.source[self.pos];
        self.pos += 1;
        return c;
    }
};
