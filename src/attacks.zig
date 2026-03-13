const std = @import("std");
const bb = @import("bitboard.zig");
const Bitboard = bb.Bitboard;
const Square = @import("square.zig").Square;
const magics = @import("magics.zig");
const Color = @import("types.zig").Color;
const PieceType = @import("types.zig").PieceType;

// Precomputed attack tables
pub const knight_attacks: [64]Bitboard = blk: {
    var table: [64]Bitboard = undefined;
    for (0..64) |sq| {
        const b: Bitboard = @as(u64, 1) << @intCast(sq);
        table[sq] = ((b << 17) & bb.not_file_a) |
            ((b << 15) & bb.not_file_h) |
            ((b << 10) & bb.not_file_ab) |
            ((b << 6) & bb.not_file_gh) |
            ((b >> 6) & bb.not_file_ab) |
            ((b >> 10) & bb.not_file_gh) |
            ((b >> 15) & bb.not_file_a) |
            ((b >> 17) & bb.not_file_h);
    }
    break :blk table;
};

pub const king_attacks: [64]Bitboard = blk: {
    var table: [64]Bitboard = undefined;
    for (0..64) |sq| {
        const b: Bitboard = @as(u64, 1) << @intCast(sq);
        table[sq] = bb.northOne(b) | bb.southOne(b) |
            bb.eastOne(b) | bb.westOne(b) |
            bb.northEastOne(b) | bb.northWestOne(b) |
            bb.southEastOne(b) | bb.southWestOne(b);
    }
    break :blk table;
};

pub const pawn_attacks: [2][64]Bitboard = blk: {
    var table: [2][64]Bitboard = undefined;
    // White pawns attack northeast and northwest
    for (0..64) |sq| {
        const b: Bitboard = @as(u64, 1) << @intCast(sq);
        table[0][sq] = bb.northEastOne(b) | bb.northWestOne(b);
    }
    // Black pawns attack southeast and southwest
    for (0..64) |sq| {
        const b: Bitboard = @as(u64, 1) << @intCast(sq);
        table[1][sq] = bb.southEastOne(b) | bb.southWestOne(b);
    }
    break :blk table;
};

pub inline fn bishopAttacks(sq: u6, occupancy: Bitboard) Bitboard {
    return magics.getBishopAttacks(sq, occupancy);
}

pub inline fn rookAttacks(sq: u6, occupancy: Bitboard) Bitboard {
    return magics.getRookAttacks(sq, occupancy);
}

pub inline fn queenAttacks(sq: u6, occupancy: Bitboard) Bitboard {
    return bishopAttacks(sq, occupancy) | rookAttacks(sq, occupancy);
}

pub fn isSquareAttacked(sq: u6, by_color: Color, board_pieces: [2][6]Bitboard, occupancy: Bitboard) bool {
    const color_idx = @intFromEnum(by_color);

    // Knight attacks
    if (knight_attacks[sq] & board_pieces[color_idx][@intFromEnum(PieceType.knight)] != 0) return true;

    // King attacks
    if (king_attacks[sq] & board_pieces[color_idx][@intFromEnum(PieceType.king)] != 0) return true;

    // Pawn attacks (check from the perspective of the attacked square)
    const defender_color = by_color.opponent();
    if (pawn_attacks[@intFromEnum(defender_color)][sq] & board_pieces[color_idx][@intFromEnum(PieceType.pawn)] != 0) return true;

    // Bishop/Queen attacks
    const bishop_queen = board_pieces[color_idx][@intFromEnum(PieceType.bishop)] |
        board_pieces[color_idx][@intFromEnum(PieceType.queen)];
    if (bishopAttacks(sq, occupancy) & bishop_queen != 0) return true;

    // Rook/Queen attacks
    const rook_queen = board_pieces[color_idx][@intFromEnum(PieceType.rook)] |
        board_pieces[color_idx][@intFromEnum(PieceType.queen)];
    if (rookAttacks(sq, occupancy) & rook_queen != 0) return true;

    return false;
}

test "knight attacks" {
    // Knight on e4 should attack 8 squares
    const e4_attacks = knight_attacks[@intFromEnum(Square.e4)];
    try std.testing.expectEqual(@as(u7, 8), bb.popCount(e4_attacks));

    // Knight on a1 should attack 2 squares
    const a1_attacks = knight_attacks[@intFromEnum(Square.a1)];
    try std.testing.expectEqual(@as(u7, 2), bb.popCount(a1_attacks));
}

test "king attacks" {
    // King on e4 should attack 8 squares
    const e4_attacks = king_attacks[@intFromEnum(Square.e4)];
    try std.testing.expectEqual(@as(u7, 8), bb.popCount(e4_attacks));

    // King on a1 should attack 3 squares
    const a1_attacks = king_attacks[@intFromEnum(Square.a1)];
    try std.testing.expectEqual(@as(u7, 3), bb.popCount(a1_attacks));
}

test "pawn attacks" {
    // White pawn on e4 attacks d5 and f5
    const e4_white = pawn_attacks[0][@intFromEnum(Square.e4)];
    try std.testing.expect(e4_white & Square.d5.toBitboard() != 0);
    try std.testing.expect(e4_white & Square.f5.toBitboard() != 0);
    try std.testing.expectEqual(@as(u7, 2), bb.popCount(e4_white));

    // Black pawn on e5 attacks d4 and f4
    const e5_black = pawn_attacks[1][@intFromEnum(Square.e5)];
    try std.testing.expect(e5_black & Square.d4.toBitboard() != 0);
    try std.testing.expect(e5_black & Square.f4.toBitboard() != 0);
}
