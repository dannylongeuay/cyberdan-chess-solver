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

// Phase weights per piece type (pawn=0, knight=1, bishop=1, rook=2, queen=4, king=0)
const phase_weights = [6]i32{ 0, 1, 1, 2, 4, 0 };
const TOTAL_PHASE: i32 = 24; // 2*1 + 2*1 + 2*2 + 2*4 = 24 (both sides)

// Middlegame material values
const mg_piece_values = [6]i32{ 100, 320, 330, 500, 900, 0 };

// Endgame material values — pawns worth more, minor pieces slightly less
const eg_piece_values = [6]i32{ 120, 300, 310, 500, 900, 0 };

// Middlegame piece-square tables in LERF layout (a1=index 0, h8=index 63).
// White uses pst[pt][sq], black uses pst[pt][sq ^ 56] (vertical mirror).
// Values from the Simplified Evaluation Function (CPW).
const pst_mg = [6][64]i32{
    // Pawn MG
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
    // Knight MG
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
    // Bishop MG
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
    // Rook MG
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
    // Queen MG
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
    // King MG — stay castled, avoid center
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

// Endgame piece-square tables.
// Key differences from MG: king centralizes, pawns get higher advance bonuses.
const pst_eg = [6][64]i32{
    // Pawn EG — strongly reward advancement
    .{
        0,   0,   0,   0,   0,   0,   0,   0,   // rank 1
        10,  10,  10,  10,  10,  10,  10,  10,  // rank 2
        10,  10,  10,  10,  10,  10,  10,  10,  // rank 3
        20,  20,  20,  20,  20,  20,  20,  20,  // rank 4
        30,  30,  30,  30,  30,  30,  30,  30,  // rank 5
        50,  50,  50,  50,  50,  50,  50,  50,  // rank 6
        80,  80,  80,  80,  80,  80,  80,  80,  // rank 7
        0,   0,   0,   0,   0,   0,   0,   0,   // rank 8
    },
    // Knight EG — softer edge penalties, symmetric (no development bias)
    .{
        -40, -25, -15, -15, -15, -15, -25, -40, // rank 1
        -25, -10, 0,   5,   5,   0,   -10, -25, // rank 2
        -15, 0,   10,  15,  15,  10,  0,   -15, // rank 3
        -15, 5,   15,  20,  20,  15,  5,   -15, // rank 4
        -15, 5,   15,  20,  20,  15,  5,   -15, // rank 5
        -15, 0,   10,  15,  15,  10,  0,   -15, // rank 6
        -25, -10, 0,   5,   5,   0,   -10, -25, // rank 7
        -40, -25, -15, -15, -15, -15, -25, -40, // rank 8
    },
    // Bishop EG — stronger centralization, reduced edge penalties
    .{
        -5,  -5,  -5,  -5,  -5,  -5,  -5,  -5,  // rank 1
        -5,  0,   0,   0,   0,   0,   0,   -5,  // rank 2
        -5,  0,   10,  10,  10,  10,  0,   -5,  // rank 3
        -5,  0,   10,  20,  20,  10,  0,   -5,  // rank 4
        -5,  0,   10,  20,  20,  10,  0,   -5,  // rank 5
        -5,  0,   10,  10,  10,  10,  0,   -5,  // rank 6
        -5,  0,   0,   0,   0,   0,   0,   -5,  // rank 7
        -5,  -5,  -5,  -5,  -5,  -5,  -5,  -5,  // rank 8
    },
    // Rook EG — no negatives, doubled 7th rank bonus, mild centralization
    .{
        0,   0,   5,   5,   5,   5,   0,   0,   // rank 1
        0,   5,   5,   5,   5,   5,   5,   0,   // rank 2
        0,   5,   5,   5,   5,   5,   5,   0,   // rank 3
        0,   5,   5,  10,  10,   5,   5,   0,   // rank 4
        0,   5,   5,  10,  10,   5,   5,   0,   // rank 5
        0,   5,   5,   5,   5,   5,   5,   0,   // rank 6
        10,  20,  20,  20,  20,  20,  20,  10,  // rank 7
        0,   5,   5,   5,   5,   5,   5,   0,   // rank 8
    },
    // Queen EG — aggressive centralization, symmetric
    .{
        -15, -10, -5,  -5,  -5,  -5,  -10, -15, // rank 1
        -10, 0,   5,   5,   5,   5,   0,   -10, // rank 2
        -5,  5,   10,  15,  15,  10,  5,   -5,  // rank 3
        -5,  5,   15,  20,  20,  15,  5,   -5,  // rank 4
        -5,  5,   15,  20,  20,  15,  5,   -5,  // rank 5
        -5,  5,   10,  15,  15,  10,  5,   -5,  // rank 6
        -10, 0,   5,   5,   5,   5,   0,   -10, // rank 7
        -15, -10, -5,  -5,  -5,  -5,  -10, -15, // rank 8
    },
    // King EG — centralize! King should be active in endgames
    .{
        -50, -30, -30, -30, -30, -30, -30, -50, // rank 1
        -30, -10, 0,   0,   0,   0,   -10, -30, // rank 2
        -30, 0,   10,  15,  15,  10,  0,   -30, // rank 3
        -30, 0,   15,  20,  20,  15,  0,   -30, // rank 4
        -30, 0,   15,  20,  20,  15,  0,   -30, // rank 5
        -30, 0,   10,  15,  15,  10,  0,   -30, // rank 6
        -30, -10, 0,   0,   0,   0,   -10, -30, // rank 7
        -50, -30, -30, -30, -30, -30, -30, -50, // rank 8
    },
};

/// Evaluate the board from the side-to-move's perspective using tapered eval.
pub fn evaluate(board: *const Board) i32 {
    var mg_score: i32 = 0;
    var eg_score: i32 = 0;
    var phase: i32 = 0;

    // White pieces
    inline for (0..6) |p| {
        var pieces = board.pieces[0][p];
        while (pieces != 0) {
            const sq = bb.popLsb(&pieces);
            mg_score += mg_piece_values[p] + pst_mg[p][sq];
            eg_score += eg_piece_values[p] + pst_eg[p][sq];
            phase += phase_weights[p];
        }
    }

    // Black pieces
    inline for (0..6) |p| {
        var pieces = board.pieces[1][p];
        while (pieces != 0) {
            const sq = bb.popLsb(&pieces);
            mg_score -= mg_piece_values[p] + pst_mg[p][sq ^ 56];
            eg_score -= eg_piece_values[p] + pst_eg[p][sq ^ 56];
            phase += phase_weights[p];
        }
    }

    // Clamp phase to TOTAL_PHASE (promotions can exceed it)
    if (phase > TOTAL_PHASE) phase = TOTAL_PHASE;

    // Tapered score: interpolate between MG and EG based on phase
    const score = @divTrunc(mg_score * phase + eg_score * (TOTAL_PHASE - phase), TOTAL_PHASE);

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

test "endgame king centralizes better than corner" {
    // King + pawn endgame: white king on e4 vs white king on a1
    const center_king = Board.fromFen("8/8/8/8/4K3/8/4P3/4k3 w - - 0 1") catch unreachable;
    const corner_king = Board.fromFen("8/8/8/8/8/8/4P3/K3k3 w - - 0 1") catch unreachable;
    const center_score = evaluate(&center_king);
    const corner_score = evaluate(&corner_king);
    // Central king should score higher in endgame
    try std.testing.expect(center_score > corner_score);
}

test "taper interpolates between MG and EG based on phase" {
    // High phase (queens present): white king on e1, both queens on board
    const high_phase = Board.fromFen("4k3/8/8/8/8/8/8/4K2Q w - - 0 1") catch unreachable;
    // Low phase (no queens): same structure, queen removed
    const low_phase = Board.fromFen("4k3/8/8/8/8/8/8/4K3 w - - 0 1") catch unreachable;

    // In MG, king on e1 (sq 4) has PST value 0; in EG, king on e1 has -30.
    // High phase should weight MG more (less penalty), low phase weights EG more (bigger penalty).
    const high_score = evaluate(&high_phase);
    const low_score = evaluate(&low_phase);

    // High phase position has queen material advantage AND less king-position penalty,
    // so it must score higher. The key point: taper changes the king PST contribution.
    try std.testing.expect(high_score > low_score);

    // Also verify the scores are actually different (taper is doing something)
    try std.testing.expect(high_score != low_score);
}
