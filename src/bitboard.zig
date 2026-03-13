const std = @import("std");

pub const Bitboard = u64;

// File constants
pub const file_a: Bitboard = 0x0101010101010101;
pub const file_b: Bitboard = 0x0202020202020202;
pub const file_g: Bitboard = 0x4040404040404040;
pub const file_h: Bitboard = 0x8080808080808080;
pub const not_file_a: Bitboard = ~file_a;
pub const not_file_h: Bitboard = ~file_h;
pub const not_file_ab: Bitboard = ~(file_a | file_b);
pub const not_file_gh: Bitboard = ~(file_g | file_h);

// Rank constants
pub const rank_1: Bitboard = 0x00000000000000FF;
pub const rank_2: Bitboard = 0x000000000000FF00;
pub const rank_3: Bitboard = 0x0000000000FF0000;
pub const rank_4: Bitboard = 0x00000000FF000000;
pub const rank_5: Bitboard = 0x000000FF00000000;
pub const rank_6: Bitboard = 0x0000FF0000000000;
pub const rank_7: Bitboard = 0x00FF000000000000;
pub const rank_8: Bitboard = 0xFF00000000000000;

pub const files = [8]Bitboard{
    file_a,
    file_b,
    0x0404040404040404,
    0x0808080808080808,
    0x1010101010101010,
    0x2020202020202020,
    file_g,
    file_h,
};

pub const ranks = [8]Bitboard{
    rank_1, rank_2, rank_3, rank_4,
    rank_5, rank_6, rank_7, rank_8,
};

pub inline fn popCount(bb: Bitboard) u7 {
    return @popCount(bb);
}

pub inline fn lsb(bb: Bitboard) u6 {
    return @intCast(@ctz(bb));
}

pub inline fn popLsb(bb: *Bitboard) u6 {
    const sq = lsb(bb.*);
    bb.* &= bb.* - 1;
    return sq;
}

// Directional shifts
pub inline fn northOne(bb: Bitboard) Bitboard {
    return bb << 8;
}

pub inline fn southOne(bb: Bitboard) Bitboard {
    return bb >> 8;
}

pub inline fn eastOne(bb: Bitboard) Bitboard {
    return (bb << 1) & not_file_a;
}

pub inline fn westOne(bb: Bitboard) Bitboard {
    return (bb >> 1) & not_file_h;
}

pub inline fn northEastOne(bb: Bitboard) Bitboard {
    return (bb << 9) & not_file_a;
}

pub inline fn northWestOne(bb: Bitboard) Bitboard {
    return (bb << 7) & not_file_h;
}

pub inline fn southEastOne(bb: Bitboard) Bitboard {
    return (bb >> 7) & not_file_a;
}

pub inline fn southWestOne(bb: Bitboard) Bitboard {
    return (bb >> 9) & not_file_h;
}

pub const Iterator = struct {
    bb: Bitboard,

    pub fn next(self: *Iterator) ?u6 {
        if (self.bb == 0) return null;
        return popLsb(&self.bb);
    }
};

pub fn iterator(bb: Bitboard) Iterator {
    return .{ .bb = bb };
}

test "bitboard basics" {
    try std.testing.expectEqual(@as(u7, 0), popCount(@as(Bitboard, 0)));
    try std.testing.expectEqual(@as(u7, 1), popCount(@as(Bitboard, 1)));
    try std.testing.expectEqual(@as(u7, 64), popCount(~@as(Bitboard, 0)));

    try std.testing.expectEqual(@as(u6, 0), lsb(@as(Bitboard, 1)));
    try std.testing.expectEqual(@as(u6, 3), lsb(@as(Bitboard, 0b1000)));

    var bb: Bitboard = 0b1010;
    const first = popLsb(&bb);
    try std.testing.expectEqual(@as(u6, 1), first);
    try std.testing.expectEqual(@as(Bitboard, 0b1000), bb);
}

test "directional shifts" {
    const a1: Bitboard = 1;
    try std.testing.expectEqual(@as(Bitboard, 1) << 8, northOne(a1));
    try std.testing.expectEqual(@as(Bitboard, 0), southOne(a1));
    try std.testing.expectEqual(@as(Bitboard, 1) << 1, eastOne(a1));
    try std.testing.expectEqual(@as(Bitboard, 0), westOne(a1)); // a-file, wraps blocked

    const h1: Bitboard = @as(Bitboard, 1) << 7;
    try std.testing.expectEqual(@as(Bitboard, 0), eastOne(h1)); // h-file, wraps blocked
    try std.testing.expectEqual(@as(Bitboard, 1) << 6, westOne(h1));
}

test "iterator" {
    var bb: Bitboard = 0b10101;
    var iter = iterator(bb);
    _ = &bb;

    try std.testing.expectEqual(@as(u6, 0), iter.next().?);
    try std.testing.expectEqual(@as(u6, 2), iter.next().?);
    try std.testing.expectEqual(@as(u6, 4), iter.next().?);
    try std.testing.expect(iter.next() == null);
}
