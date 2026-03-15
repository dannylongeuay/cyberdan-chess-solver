const std = @import("std");
const types = @import("types.zig");
const bb = @import("bitboard.zig");
const board_mod = @import("board.zig");

const Color = types.Color;
const PieceType = types.PieceType;
const Bitboard = bb.Bitboard;
const Board = board_mod.Board;

pub const CHECKMATE_SCORE: i32 = 30_000;
pub const DRAW_SCORE: i32 = 0;

// Material values indexed by PieceType ordinal (pawn=0..king=5)
pub const piece_values = [6]i32{ 100, 320, 330, 500, 900, 20000 };

// Piece-square tables in LERF layout (a1=index 0, h8=index 63).
// White uses pst[pt][sq], black uses pst[pt][sq ^ 56] (vertical mirror).
// Values from the Simplified Evaluation Function (CPW).
pub const pst = [6][64]i32{
    // Pawn (rank 1 at index 0)
    .{
        0,   0,   0,   0,   0,   0,   0,   0,   // rank 1
        5,   10,  10,  -20, -20, 10,  10,  5,   // rank 2
        5,   -5,  -10, 0,   0,   -10, -5,  5,   // rank 3
        0,   0,   0,   20,  20,  0,   0,   0,   // rank 4
        5,   5,   10,  25,  25,  10,  5,   5,   // rank 5
        10,  10,  20,  30,  30,  20,  10,  10,  // rank 6
        50,  50,  50,  50,  50,  50,  50,  50,  // rank 7
        0,   0,   0,   0,   0,   0,   0,   0,   // rank 8
    },
    // Knight (rank 1 at index 0)
    .{
        -50, -40, -30, -30, -30, -30, -40, -50, // rank 1
        -40, -20, 0,   5,   5,   0,   -20, -40, // rank 2
        -30, 5,   10,  15,  15,  10,  5,   -30, // rank 3
        -30, 0,   15,  20,  20,  15,  0,   -30, // rank 4
        -30, 5,   15,  20,  20,  15,  5,   -30, // rank 5
        -30, 0,   10,  15,  15,  10,  0,   -30, // rank 6
        -40, -20, 0,   0,   0,   0,   -20, -40, // rank 7
        -50, -40, -30, -30, -30, -30, -40, -50, // rank 8
    },
    // Bishop (rank 1 at index 0)
    .{
        -20, -10, -10, -10, -10, -10, -10, -20, // rank 1
        -10, 5,   0,   0,   0,   0,   5,   -10, // rank 2
        -10, 10,  10,  10,  10,  10,  10,  -10, // rank 3
        -10, 0,   10,  10,  10,  10,  0,   -10, // rank 4
        -10, 5,   5,   10,  10,  5,   5,   -10, // rank 5
        -10, 0,   5,   10,  10,  5,   0,   -10, // rank 6
        -10, 0,   0,   0,   0,   0,   0,   -10, // rank 7
        -20, -10, -10, -10, -10, -10, -10, -20, // rank 8
    },
    // Rook (rank 1 at index 0)
    .{
        0,  0,  0,  5,  5,  0,  0,  0,  // rank 1
        -5, 0,  0,  0,  0,  0,  0,  -5, // rank 2
        -5, 0,  0,  0,  0,  0,  0,  -5, // rank 3
        -5, 0,  0,  0,  0,  0,  0,  -5, // rank 4
        -5, 0,  0,  0,  0,  0,  0,  -5, // rank 5
        -5, 0,  0,  0,  0,  0,  0,  -5, // rank 6
        5,  10, 10, 10, 10, 10, 10, 5,  // rank 7
        0,  0,  0,  0,  0,  0,  0,  0,  // rank 8
    },
    // Queen (rank 1 at index 0)
    .{
        -20, -10, -10, -5, -5, -10, -10, -20, // rank 1
        -10, 0,   5,   0,  0,  0,   0,   -10, // rank 2
        -10, 5,   5,   5,  5,  5,   0,   -10, // rank 3
        0,   0,   5,   5,  5,  5,   0,   -5,  // rank 4
        -5,  0,   5,   5,  5,  5,   0,   -5,  // rank 5
        -10, 0,   5,   5,  5,  5,   0,   -10, // rank 6
        -10, 0,   0,   0,  0,  0,   0,   -10, // rank 7
        -20, -10, -10, -5, -5, -10, -10, -20, // rank 8
    },
    // King middlegame (rank 1 at index 0)
    .{
        20,  30,  10,  0,   0,   10,  30,  20,  // rank 1
        20,  20,  0,   0,   0,   0,   20,  20,  // rank 2
        -10, -20, -20, -20, -20, -20, -20, -10, // rank 3
        -20, -30, -30, -40, -40, -30, -30, -20, // rank 4
        -30, -40, -40, -50, -50, -40, -40, -30, // rank 5
        -30, -40, -40, -50, -50, -40, -40, -30, // rank 6
        -30, -40, -40, -50, -50, -40, -40, -30, // rank 7
        -30, -40, -40, -50, -50, -40, -40, -30, // rank 8
    },
};

/// Evaluate the board from the side-to-move's perspective.
pub fn evaluate(board: *const Board) i32 {
    var score: i32 = 0;

    // White pieces
    inline for (0..6) |p| {
        var pieces = board.pieces[0][p];
        while (pieces != 0) {
            const sq = bb.popLsb(&pieces);
            score += piece_values[p] + pst[p][sq];
        }
    }

    // Black pieces
    inline for (0..6) |p| {
        var pieces = board.pieces[1][p];
        while (pieces != 0) {
            const sq = bb.popLsb(&pieces);
            score -= piece_values[p] + pst[p][sq ^ 56];
        }
    }

    // Return from side-to-move perspective
    return if (board.side_to_move == .white) score else -score;
}

test "starting position evaluates to 0" {
    const board = Board.init();
    const score = evaluate(&board);
    try std.testing.expectEqual(@as(i32, 0), score);
}

test "position missing black queen evaluates > 800" {
    // Starting position with black queen removed
    const board = Board.fromFen("rnb1kbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1") catch unreachable;
    const score = evaluate(&board);
    // White has a queen advantage (~900 material + PST)
    try std.testing.expect(score > 800);
}
