const std = @import("std");
const Bitboard = @import("bitboard.zig").Bitboard;

pub const Square = enum(u6) {
    a1, b1, c1, d1, e1, f1, g1, h1,
    a2, b2, c2, d2, e2, f2, g2, h2,
    a3, b3, c3, d3, e3, f3, g3, h3,
    a4, b4, c4, d4, e4, f4, g4, h4,
    a5, b5, c5, d5, e5, f5, g5, h5,
    a6, b6, c6, d6, e6, f6, g6, h6,
    a7, b7, c7, d7, e7, f7, g7, h7,
    a8, b8, c8, d8, e8, f8, g8, h8,

    pub fn file(self: Square) u3 {
        return @truncate(@intFromEnum(self));
    }

    pub fn rank(self: Square) u3 {
        return @truncate(@intFromEnum(self) >> 3);
    }

    pub fn fromRankFile(r: u3, f: u3) Square {
        return @enumFromInt((@as(u6, r) << 3) | @as(u6, f));
    }

    pub fn toBitboard(self: Square) Bitboard {
        return @as(u64, 1) << @intFromEnum(self);
    }

    pub fn fromString(str: []const u8) ?Square {
        if (str.len < 2) return null;
        const f = str[0];
        const r = str[1];
        if (f < 'a' or f > 'h') return null;
        if (r < '1' or r > '8') return null;
        return fromRankFile(@intCast(r - '1'), @intCast(f - 'a'));
    }

    pub fn toString(self: Square) [2]u8 {
        return .{
            'a' + @as(u8, self.file()),
            '1' + @as(u8, self.rank()),
        };
    }
};

test "square basics" {
    const a1 = Square.a1;
    try std.testing.expectEqual(@as(u3, 0), a1.file());
    try std.testing.expectEqual(@as(u3, 0), a1.rank());

    const h8 = Square.h8;
    try std.testing.expectEqual(@as(u3, 7), h8.file());
    try std.testing.expectEqual(@as(u3, 7), h8.rank());

    try std.testing.expectEqual(Square.e4, Square.fromRankFile(3, 4));
    try std.testing.expectEqual(Square.e4, Square.fromString("e4").?);

    const str = Square.e4.toString();
    try std.testing.expectEqualStrings("e4", &str);
}
