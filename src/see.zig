const std = @import("std");
const types = @import("types.zig");
const bb = @import("bitboard.zig");
const board_mod = @import("board.zig");
const moves_mod = @import("moves.zig");
const atk = @import("attacks.zig");
const eval_mod = @import("eval.zig");

const Color = types.Color;
const PieceType = types.PieceType;
const Bitboard = bb.Bitboard;
const Board = board_mod.Board;
const Move = moves_mod.Move;
const MoveFlags = moves_mod.MoveFlags;

const piece_values = eval_mod.piece_values;

/// Compute all attackers (both colors) to a square under given occupancy.
fn allAttackersTo(pieces: [2][6]Bitboard, sq: u6, occ: Bitboard) Bitboard {
    const knights = pieces[0][@intFromEnum(PieceType.knight)] | pieces[1][@intFromEnum(PieceType.knight)];
    const bishops = pieces[0][@intFromEnum(PieceType.bishop)] | pieces[1][@intFromEnum(PieceType.bishop)];
    const rooks = pieces[0][@intFromEnum(PieceType.rook)] | pieces[1][@intFromEnum(PieceType.rook)];
    const queens = pieces[0][@intFromEnum(PieceType.queen)] | pieces[1][@intFromEnum(PieceType.queen)];
    const kings = pieces[0][@intFromEnum(PieceType.king)] | pieces[1][@intFromEnum(PieceType.king)];

    return (atk.pawn_attacks[1][sq] & pieces[0][@intFromEnum(PieceType.pawn)]) | // white pawns attack like black captures
        (atk.pawn_attacks[0][sq] & pieces[1][@intFromEnum(PieceType.pawn)]) | // black pawns attack like white captures
        (atk.knight_attacks[sq] & knights) |
        (atk.bishopAttacks(sq, occ) & (bishops | queens)) |
        (atk.rookAttacks(sq, occ) & (rooks | queens)) |
        (atk.king_attacks[sq] & kings);
}

/// Find the least valuable attacker of a given side among the attackers bitboard.
fn leastValuableAttacker(pieces: [2][6]Bitboard, attackers: Bitboard, side: Color) ?struct { sq: u6, piece_type: PieceType } {
    const side_idx = @intFromEnum(side);
    const piece_types = [_]PieceType{ .pawn, .knight, .bishop, .rook, .queen, .king };
    for (piece_types) |pt| {
        const candidates = attackers & pieces[side_idx][@intFromEnum(pt)];
        if (candidates != 0) {
            return .{ .sq = bb.lsb(candidates), .piece_type = pt };
        }
    }
    return null;
}

/// Static Exchange Evaluation: returns the material gain/loss of a capture sequence.
pub fn see(board: *const Board, move: Move) i32 {
    std.debug.assert(move.flags.isCapture());
    const to_sq = move.to;
    const from_sq = move.from;
    const us_idx = @intFromEnum(board.side_to_move);

    // Determine the initial attacker piece type
    const attacker_pt = board.getPieceTypeAt(from_sq, us_idx);

    // Determine the initial captured piece value
    var gain: [32]i32 = undefined;
    if (move.flags == .ep_capture) {
        gain[0] = piece_values[@intFromEnum(PieceType.pawn)];
    } else {
        const them_idx = us_idx ^ 1;
        const victim_pt = board.getPieceTypeAt(to_sq, them_idx);
        gain[0] = piece_values[@intFromEnum(victim_pt)];
    }

    // Add promotion value if applicable
    if (move.flags.isPromotion()) {
        if (move.flags.promotionPieceType()) |promo_pt| {
            gain[0] += piece_values[@intFromEnum(promo_pt)] - piece_values[@intFromEnum(PieceType.pawn)];
        }
    }

    // Set up occupancy: remove the initial attacker
    var occ = board.all_occupancy;
    occ ^= @as(u64, 1) << from_sq;

    // For EP, also remove the captured pawn from occupancy
    if (move.flags == .ep_capture) {
        const ep_captured_sq: u6 = if (board.side_to_move == .white) to_sq - 8 else to_sq + 8;
        occ ^= @as(u64, 1) << ep_captured_sq;
    }

    // Get all attackers to the target square
    var attackers = allAttackersTo(board.pieces, to_sq, occ) & occ;

    var side = board.side_to_move.opponent();
    var current_attacker_pt = attacker_pt;
    var d: usize = 1;

    while (true) {
        // Find the least valuable attacker for the current side
        const lva = leastValuableAttacker(board.pieces, attackers, side) orelse break;

        // The piece we're capturing is whatever the previous attacker was
        gain[d] = piece_values[@intFromEnum(current_attacker_pt)] - gain[d - 1];

        // Remove this attacker from occupancy (reveals X-ray attackers)
        occ ^= @as(u64, 1) << lva.sq;
        attackers = allAttackersTo(board.pieces, to_sq, occ) & occ;

        current_attacker_pt = lva.piece_type;
        side = side.opponent();
        d += 1;
    }

    // Propagate backwards: each side chooses to capture or not
    while (d > 1) {
        d -= 1;
        gain[d - 1] = -@max(-gain[d - 1], gain[d]);
    }

    return gain[0];
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "SEE: winning capture PxQ undefended" {
    // White pawn on d4, black queen on e5 undefended
    var board = Board.fromFen("4k3/8/8/4q3/3P4/8/8/4K3 w - - 0 1") catch unreachable;
    const move = Move{ .from = @intFromEnum(@import("square.zig").Square.d4), .to = @intFromEnum(@import("square.zig").Square.e5), .flags = .capture };
    const score = see(&board, move);
    try std.testing.expectEqual(@as(i32, 900), score);
}

test "SEE: equal exchange RxR defended by R" {
    // White rook on a1, black rooks on a7 and a8
    // RxRa7, Rxa7 — white wins rook, loses rook = 0
    var board = Board.fromFen("r3k3/r7/8/8/8/8/8/R3K3 w - - 0 1") catch unreachable;
    const Square = @import("square.zig").Square;
    const move = Move{ .from = @intFromEnum(Square.a1), .to = @intFromEnum(Square.a7), .flags = .capture };
    const score = see(&board, move);
    try std.testing.expectEqual(@as(i32, 0), score);
}

test "SEE: losing capture QxP defended" {
    // White queen on d1, black pawn on e5 defended by pawn on d6
    // QxPe5, dxe5 — white wins pawn (100), loses queen (900) = -800
    var board = Board.fromFen("4k3/8/3p4/4p3/8/8/8/3QK3 w - - 0 1") catch unreachable;
    const Square = @import("square.zig").Square;
    const move = Move{ .from = @intFromEnum(Square.d1), .to = @intFromEnum(Square.e5), .flags = .capture };
    const score = see(&board, move);
    try std.testing.expect(score < 0);
}

test "SEE: X-ray rook battery" {
    // White rooks on a1 and a2, black rook on a7
    // Ra2xa7 — Rxa7 captures rook (500), no recapture since the second white rook x-rays through
    // Wait, black has no defender, so it's just 500.
    // Better: white rooks on a1,a2, black rooks on a7,a8.
    // Ra2xa7, Ra8xa7, Ra1xa7 — net: win R, lose R, win R = 500
    var board = Board.fromFen("r3k3/r7/8/8/8/8/R7/R3K3 w - - 0 1") catch unreachable;
    const Square = @import("square.zig").Square;
    const move = Move{ .from = @intFromEnum(Square.a2), .to = @intFromEnum(Square.a7), .flags = .capture };
    const score = see(&board, move);
    try std.testing.expectEqual(@as(i32, 500), score);
}

test "SEE: en passant capture" {
    // White pawn on e5, black pawn on d5 (just pushed), EP available on d6
    var board = Board.fromFen("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1") catch unreachable;
    const Square = @import("square.zig").Square;
    const move = Move{ .from = @intFromEnum(Square.e5), .to = @intFromEnum(Square.d6), .flags = .ep_capture };
    const score = see(&board, move);
    try std.testing.expectEqual(@as(i32, 100), score);
}

test "SEE: NxB defended by pawn — slightly winning (330-320 = 10)" {
    var board = Board.fromFen("4k3/8/4p3/3b4/8/2N5/8/4K3 w - - 0 1") catch unreachable;
    const Square = @import("square.zig").Square;
    const move = Move{ .from = @intFromEnum(Square.c3), .to = @intFromEnum(Square.d5), .flags = .capture };
    const score = see(&board, move);
    try std.testing.expectEqual(@as(i32, 10), score);
}

test "SEE: pawn capture-promotes to queen on 8th rank" {
    // White pawn on g7, black rook on h8. PxR promoting to queen.
    // gain = rook(500) + queen(900) - pawn(100) = 1300
    var board = Board.fromFen("4k2r/6P1/8/8/8/8/8/4K3 w - - 0 1") catch unreachable;
    const Square = @import("square.zig").Square;
    const move = Move{ .from = @intFromEnum(Square.g7), .to = @intFromEnum(Square.h8), .flags = .queen_promo_capture };
    const score = see(&board, move);
    // Captures rook (500) and promotes pawn to queen (+900-100=+800) = 1300
    try std.testing.expectEqual(@as(i32, 1300), score);
}
