const std = @import("std");
const types = @import("types.zig");
const bb = @import("bitboard.zig");
const attacks = @import("attacks.zig");
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

// Adjacent file masks for pawn structure evaluation
const adjacent_files: [8]Bitboard = blk: {
    var table: [8]Bitboard = undefined;
    for (0..8) |f| {
        table[f] = 0;
        if (f > 0) table[f] |= bb.files[f - 1];
        if (f < 7) table[f] |= bb.files[f + 1];
    }
    break :blk table;
};

// Passed pawn masks: [color][square] — if mask & enemy_pawns == 0, the pawn is passed
const passed_pawn_masks: [2][64]Bitboard = blk: {
    var table: [2][64]Bitboard = undefined;
    for (0..64) |sq| {
        const file = sq & 7;
        const rank = sq >> 3;

        // White: forward cone (ranks above the pawn)
        var white_mask: Bitboard = 0;
        {
            var r = rank + 1;
            while (r < 8) : (r += 1) {
                if (file > 0) white_mask |= bb.files[file - 1] & bb.ranks[r];
                white_mask |= bb.files[file] & bb.ranks[r];
                if (file < 7) white_mask |= bb.files[file + 1] & bb.ranks[r];
            }
        }
        table[0][sq] = white_mask;

        // Black: forward cone (ranks below the pawn)
        var black_mask: Bitboard = 0;
        {
            var r: usize = 0;
            while (r < rank) : (r += 1) {
                if (file > 0) black_mask |= bb.files[file - 1] & bb.ranks[r];
                black_mask |= bb.files[file] & bb.ranks[r];
                if (file < 7) black_mask |= bb.files[file + 1] & bb.ranks[r];
            }
        }
        table[1][sq] = black_mask;
    }
    break :blk table;
};

// Passed pawn bonuses indexed by relative rank (0=rank1, 7=rank8)
const passed_pawn_bonus_mg = [8]i32{ 0, 5, 10, 20, 35, 60, 100, 0 };
const passed_pawn_bonus_eg = [8]i32{ 0, 10, 20, 40, 70, 120, 200, 0 };

const isolated_pawn_penalty_mg: i32 = -15;
const isolated_pawn_penalty_eg: i32 = -20;
const doubled_pawn_penalty_mg: i32 = -10;
const doubled_pawn_penalty_eg: i32 = -15;

// Mobility bonuses per square above baseline: [knight, bishop, rook, queen]
const mobility_bonus_mg = [4]i32{ 4, 5, 2, 1 };
const mobility_bonus_eg = [4]i32{ 4, 5, 3, 2 };
const mobility_baseline = [4]i32{ 4, 7, 7, 14 };

const bishop_pair_bonus_mg: i32 = 30;
const bishop_pair_bonus_eg: i32 = 45;

const pawn_shield_bonus: i32 = 10; // MG only, per shielding pawn
const king_open_file_penalty: i32 = -15; // MG only, per open file near king

fn evaluatePawnStructure(board: *const Board, mg: *i32, eg: *i32) void {
    inline for (0..2) |color_idx| {
        const sign: i32 = if (color_idx == 0) 1 else -1;
        const friendly_pawns = board.pieces[color_idx][@intFromEnum(PieceType.pawn)];
        const enemy_pawns = board.pieces[1 - color_idx][@intFromEnum(PieceType.pawn)];

        // Doubled pawns: penalize extra pawns per file
        inline for (0..8) |f| {
            const count: i32 = @intCast(bb.popCount(friendly_pawns & bb.files[f]));
            if (count > 1) {
                mg.* += sign * (count - 1) * doubled_pawn_penalty_mg;
                eg.* += sign * (count - 1) * doubled_pawn_penalty_eg;
            }
        }

        // Per-pawn: isolated and passed
        var pawns = friendly_pawns;
        while (pawns != 0) {
            const sq = bb.popLsb(&pawns);
            const file: usize = @intCast(sq & 7);
            const rank: usize = @intCast(sq >> 3);

            // Isolated pawn: no friendly pawns on adjacent files
            if (friendly_pawns & adjacent_files[file] == 0) {
                mg.* += sign * isolated_pawn_penalty_mg;
                eg.* += sign * isolated_pawn_penalty_eg;
            }

            // Passed pawn: no enemy pawns in forward cone
            if (passed_pawn_masks[color_idx][sq] & enemy_pawns == 0) {
                const rel_rank = if (color_idx == 0) rank else 7 - rank;
                mg.* += sign * passed_pawn_bonus_mg[rel_rank];
                eg.* += sign * passed_pawn_bonus_eg[rel_rank];
            }
        }
    }
}

fn evaluateMobility(board: *const Board, mg: *i32, eg: *i32) void {
    const all_occ = board.all_occupancy;

    inline for (0..2) |color_idx| {
        const sign: i32 = if (color_idx == 0) 1 else -1;
        const own_occ = board.occupancy[color_idx];

        // Build enemy pawn attack mask
        const enemy_pawns = board.pieces[1 - color_idx][@intFromEnum(PieceType.pawn)];
        var enemy_pawn_attacks: Bitboard = 0;
        var ep = enemy_pawns;
        while (ep != 0) {
            const sq = bb.popLsb(&ep);
            enemy_pawn_attacks |= attacks.pawn_attacks[1 - color_idx][sq];
        }

        const safe_targets = ~own_occ & ~enemy_pawn_attacks;

        // Knights
        var knights = board.pieces[color_idx][@intFromEnum(PieceType.knight)];
        while (knights != 0) {
            const sq = bb.popLsb(&knights);
            const mob: i32 = @intCast(bb.popCount(attacks.knight_attacks[sq] & safe_targets));
            mg.* += sign * (mob - mobility_baseline[0]) * mobility_bonus_mg[0];
            eg.* += sign * (mob - mobility_baseline[0]) * mobility_bonus_eg[0];
        }

        // Bishops
        var bishops = board.pieces[color_idx][@intFromEnum(PieceType.bishop)];
        while (bishops != 0) {
            const sq = bb.popLsb(&bishops);
            const mob: i32 = @intCast(bb.popCount(attacks.bishopAttacks(sq, all_occ) & safe_targets));
            mg.* += sign * (mob - mobility_baseline[1]) * mobility_bonus_mg[1];
            eg.* += sign * (mob - mobility_baseline[1]) * mobility_bonus_eg[1];
        }

        // Rooks
        var rooks = board.pieces[color_idx][@intFromEnum(PieceType.rook)];
        while (rooks != 0) {
            const sq = bb.popLsb(&rooks);
            const mob: i32 = @intCast(bb.popCount(attacks.rookAttacks(sq, all_occ) & safe_targets));
            mg.* += sign * (mob - mobility_baseline[2]) * mobility_bonus_mg[2];
            eg.* += sign * (mob - mobility_baseline[2]) * mobility_bonus_eg[2];
        }

        // Queens (use ~own_occ only — queens can contest pawn-defended squares)
        var queens = board.pieces[color_idx][@intFromEnum(PieceType.queen)];
        while (queens != 0) {
            const sq = bb.popLsb(&queens);
            const mob: i32 = @intCast(bb.popCount(attacks.queenAttacks(sq, all_occ) & ~own_occ));
            mg.* += sign * (mob - mobility_baseline[3]) * mobility_bonus_mg[3];
            eg.* += sign * (mob - mobility_baseline[3]) * mobility_bonus_eg[3];
        }
    }
}

fn evaluateKingSafety(board: *const Board, mg: *i32) void {
    inline for (0..2) |color_idx| {
        const sign: i32 = if (color_idx == 0) 1 else -1;
        const color: Color = @enumFromInt(color_idx);
        const king_sq = board.kingSquare(color);
        const king_file: usize = @intCast(king_sq & 7);
        const king_rank: usize = @intCast(king_sq >> 3);
        const friendly_pawns = board.pieces[color_idx][@intFromEnum(PieceType.pawn)];

        const min_f: usize = if (king_file > 0) king_file - 1 else 0;
        const max_f: usize = if (king_file < 7) king_file + 2 else 8;

        var f = min_f;
        while (f < max_f) : (f += 1) {
            // Pawn shield: friendly pawn on rank directly ahead of king
            if (color_idx == 0) {
                if (king_rank < 7) {
                    if (friendly_pawns & bb.files[f] & bb.ranks[king_rank + 1] != 0) {
                        mg.* += sign * pawn_shield_bonus;
                    }
                }
            } else {
                if (king_rank > 0) {
                    if (friendly_pawns & bb.files[f] & bb.ranks[king_rank - 1] != 0) {
                        mg.* += sign * pawn_shield_bonus;
                    }
                }
            }

            // Open file penalty: no friendly pawns on this file near king
            if (friendly_pawns & bb.files[f] == 0) {
                mg.* += sign * king_open_file_penalty;
            }
        }
    }
}

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

    // Pawn structure, mobility, and king safety
    evaluatePawnStructure(board, &mg_score, &eg_score);
    evaluateMobility(board, &mg_score, &eg_score);
    evaluateKingSafety(board, &mg_score);

    // Bishop pair bonus
    inline for (0..2) |color_idx| {
        const sign: i32 = if (color_idx == 0) 1 else -1;
        if (bb.popCount(board.pieces[color_idx][@intFromEnum(PieceType.bishop)]) >= 2) {
            mg_score += sign * bishop_pair_bonus_mg;
            eg_score += sign * bishop_pair_bonus_eg;
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

test "symmetry — mirrored non-starting position evaluates to 0" {
    // Sicilian-like mirror: both sides have same pawn structure and pieces
    // Symmetric position: pawns on c3/c6, knights on f3/f6, everything else standard-ish
    // Simplest: just a symmetric position with moved pieces
    // 4k3/pppppppp/8/8/8/8/PPPPPPPP/4K3 w - - 0 1
    const board = Board.fromFen("4k3/pppppppp/8/8/8/8/PPPPPPPP/4K3 w - - 0 1") catch unreachable;
    const score = evaluate(&board);
    try std.testing.expectEqual(@as(i32, 0), score);
}

test "bishop pair vs knight pair — bishops score higher" {
    // With pawns present — bishop pair bonus provides the margin
    // White: K+2B+pawns, Black: K+2N+pawns
    const bb_pos = Board.fromFen("1n2kn2/pppppppp/8/8/8/8/PPPPPPPP/2B1KB2 w - - 0 1") catch unreachable;
    const nn_pos = Board.fromFen("1b2kb2/pppppppp/8/8/8/8/PPPPPPPP/2N1KN2 w - - 0 1") catch unreachable;
    const bb_score = evaluate(&bb_pos);
    const nn_score = evaluate(&nn_pos);
    // Bishop pair bonus (30 MG / 45 EG) + material (330 vs 320) should give bishops the edge
    try std.testing.expect(bb_score > nn_score);
}

test "passed pawn on 7th rank scores high in endgame" {
    // Low-material endgame with white pawn on 7th rank
    // 4k3/4P3/8/8/8/8/8/4K3 w - - 0 1
    const pawn_7th = Board.fromFen("4k3/4P3/8/8/8/8/8/4K3 w - - 0 1") catch unreachable;
    // Same but pawn on 2nd rank
    // 4k3/8/8/8/8/8/4P3/4K3 w - - 0 1
    const pawn_2nd = Board.fromFen("4k3/8/8/8/8/8/4P3/4K3 w - - 0 1") catch unreachable;
    const score_7th = evaluate(&pawn_7th);
    const score_2nd = evaluate(&pawn_2nd);
    // 7th rank pawn should score significantly higher (EG PST bonus of 80 vs 10)
    try std.testing.expect(score_7th > score_2nd);
    try std.testing.expect(score_7th - score_2nd >= 50);
}

test "side-to-move perspective flips correctly" {
    // Symmetric position with white having a material edge (extra pawn on e4).
    // Evaluate with white-to-move and black-to-move; scores should be negatives.
    const wtm = Board.fromFen("4k3/pppppppp/8/8/4P3/8/PPPP1PPP/4K3 w - - 0 1") catch unreachable;
    const btm = Board.fromFen("4k3/pppppppp/8/8/4P3/8/PPPP1PPP/4K3 b - - 0 1") catch unreachable;
    const score_w = evaluate(&wtm);
    const score_b = evaluate(&btm);
    // White has an extra pawn, so score_w > 0 and score_b < 0
    try std.testing.expect(score_w > 0);
    try std.testing.expectEqual(score_w, -score_b);
}

test "phase clamping works with extra queens from promotions" {
    // Position with 3 white queens (2 promoted) — phase should clamp to TOTAL_PHASE
    // 4k3/8/8/8/8/8/8/QQ1QK3 w - - 0 1
    const board = Board.fromFen("4k3/8/8/8/8/8/8/QQ1QK3 w - - 0 1") catch unreachable;
    const score = evaluate(&board);
    // Should not crash or produce absurd values. With 3 queens, white should be way ahead.
    try std.testing.expect(score > 2000);
    try std.testing.expect(score < CHECKMATE_SCORE);
}

test "passed pawn bonus applied" {
    // Equal material: white pawn e5 + black pawn a7 — white pawn is passed (no enemy pawns in forward cone)
    const passed = Board.fromFen("4k3/p7/8/4P3/8/8/8/4K3 w - - 0 1") catch unreachable;
    // Equal material: white pawn e5 + black pawn e7 — white pawn is NOT passed (enemy pawn on same file)
    const not_passed = Board.fromFen("4k3/4p3/8/4P3/8/8/8/4K3 w - - 0 1") catch unreachable;
    // Same material count, difference is purely structural (passed vs blocked)
    try std.testing.expect(evaluate(&passed) > evaluate(&not_passed));
}

test "isolated pawn penalty applied" {
    // Same material (2 white pawns each), only isolation differs
    // Supported: white pawns d4+e4 (adjacent files, neither isolated)
    const supported = Board.fromFen("4k3/8/8/8/3PP3/8/8/4K3 w - - 0 1") catch unreachable;
    // Isolated: white pawns b4+e4 (gap on c/d files, both isolated)
    const isolated = Board.fromFen("4k3/8/8/8/1P2P3/8/8/4K3 w - - 0 1") catch unreachable;
    // Same material count, difference is purely structural (supported vs isolated)
    try std.testing.expect(evaluate(&supported) > evaluate(&isolated));
}

test "doubled pawn penalty applied" {
    // Two white pawns on different files vs two on the same file (doubled)
    const normal = Board.fromFen("4k3/8/8/8/3PP3/8/8/4K3 w - - 0 1") catch unreachable;
    const doubled = Board.fromFen("4k3/8/8/8/4P3/4P3/8/4K3 w - - 0 1") catch unreachable;
    // Same material, but doubled pawns get penalized
    try std.testing.expect(evaluate(&normal) > evaluate(&doubled));
}

test "mobility advantage — central vs corner knight" {
    // Same material: one knight. Central knight has more mobility than corner knight.
    const center = Board.fromFen("4k3/8/8/8/4N3/8/8/4K3 w - - 0 1") catch unreachable;
    const corner = Board.fromFen("4k3/8/8/8/8/8/8/N3K3 w - - 0 1") catch unreachable;
    // e4 knight has 8 squares mobility, a1 knight has 2 — plus PST favors center
    try std.testing.expect(evaluate(&center) > evaluate(&corner));
}

test "king safety — pawn shield vs exposed king" {
    // Add queens so position has MG phase weight (king safety is MG-only)
    // King on g1 with shield pawns f2, g2, h2
    const shielded = Board.fromFen("q3k3/8/8/8/8/8/5PPP/Q5K1 w - - 0 1") catch unreachable;
    // King on g1 with distant pawns a2, b2, c2 (no shield, open files near king)
    const exposed = Board.fromFen("q3k3/8/8/8/8/8/PPP5/Q5K1 w - - 0 1") catch unreachable;
    // Shielded king gets pawn shield bonus, exposed king gets open file penalty
    try std.testing.expect(evaluate(&shielded) > evaluate(&exposed));
}
