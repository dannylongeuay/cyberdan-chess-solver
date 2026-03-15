const std = @import("std");
const types = @import("types.zig");
const bb = @import("bitboard.zig");
const board_mod = @import("board.zig");
const moves_mod = @import("moves.zig");
const movegen = @import("movegen.zig");
const eval_mod = @import("eval.zig");

const Board = board_mod.Board;
const Move = moves_mod.Move;
const MoveFlags = moves_mod.MoveFlags;
const MoveList = moves_mod.MoveList;
const PieceType = types.PieceType;

pub const SearchResult = struct {
    best_move: ?Move,
    score: i32,
    nodes: u64,
    depth: u32,
};

const ScoredMoveList = struct {
    moves: [256]Move,
    scores: [256]i32,
    count: usize,
};

/// Iterative deepening entry point.
pub fn searchIterative(board: *Board, max_depth: u32) SearchResult {
    var best_result = SearchResult{
        .best_move = null,
        .score = 0,
        .nodes = 0,
        .depth = 0,
    };

    var depth: u32 = 1;
    while (depth <= max_depth) : (depth += 1) {
        var result = search(board, depth);
        result.nodes += best_result.nodes; // accumulate total nodes
        best_result = result;
        best_result.depth = depth;

        // Early exit on checkmate found
        if (best_result.score >= eval_mod.CHECKMATE_SCORE - 256 or
            best_result.score <= -eval_mod.CHECKMATE_SCORE + 256)
        {
            break;
        }
    }

    return best_result;
}

/// Root-level alpha-beta search.
fn search(board: *Board, depth: u32) SearchResult {
    const legal = movegen.generateLegalMoves(board);

    if (legal.count == 0) {
        // No legal moves: checkmate or stalemate
        if (board.isInCheck()) {
            return .{ .best_move = null, .score = -eval_mod.CHECKMATE_SCORE, .nodes = 1, .depth = depth };
        }
        return .{ .best_move = null, .score = eval_mod.DRAW_SCORE, .nodes = 1, .depth = depth };
    }

    var scored = scoreMoves(board, legal);
    var best_move: ?Move = null;
    var best_score: i32 = -eval_mod.CHECKMATE_SCORE - 1;
    var alpha: i32 = -eval_mod.CHECKMATE_SCORE - 1;
    const beta: i32 = eval_mod.CHECKMATE_SCORE + 1;
    var nodes: u64 = 0;

    for (0..scored.count) |i| {
        pickMove(&scored, i);
        const move = scored.moves[i];
        const undo = board.makeMove(move);
        const score = -negamax(board, depth - 1, -beta, -alpha, &nodes, 1);
        board.unmakeMove(move, undo);

        if (score > best_score) {
            best_score = score;
            best_move = move;
        }
        if (score > alpha) {
            alpha = score;
        }
    }

    return .{ .best_move = best_move, .score = best_score, .nodes = nodes, .depth = depth };
}

/// Recursive negamax with alpha-beta pruning.
fn negamax(board: *Board, depth: u32, alpha_in: i32, beta: i32, nodes: *u64, ply: u32) i32 {
    if (depth == 0) {
        return quiescence(board, alpha_in, beta, nodes, ply);
    }

    nodes.* += 1;

    const legal = movegen.generateLegalMoves(board);

    if (legal.count == 0) {
        if (board.isInCheck()) {
            // Checkmate — prefer shorter mates
            return -eval_mod.CHECKMATE_SCORE + @as(i32, @intCast(ply));
        }
        return eval_mod.DRAW_SCORE;
    }

    var scored = scoreMoves(board, legal);
    var alpha = alpha_in;

    for (0..scored.count) |i| {
        pickMove(&scored, i);
        const move = scored.moves[i];
        const undo = board.makeMove(move);
        const score = -negamax(board, depth - 1, -beta, -alpha, nodes, ply + 1);
        board.unmakeMove(move, undo);

        if (score >= beta) {
            return beta;
        }
        if (score > alpha) {
            alpha = score;
        }
    }

    return alpha;
}

/// Quiescence search — only captures, to avoid horizon effect.
/// When in check, searches all evasions and detects checkmate.
fn quiescence(board: *Board, alpha_in: i32, beta: i32, nodes: *u64, ply: u32) i32 {
    nodes.* += 1;

    const in_check = board.isInCheck();

    // Stand-pat: don't use as lower bound when in check (can't stand pat in check)
    if (!in_check) {
        const stand_pat = eval_mod.evaluate(board);
        if (stand_pat >= beta) {
            return beta;
        }
        var alpha = alpha_in;
        if (stand_pat > alpha) {
            alpha = stand_pat;
        }

        const legal = movegen.generateLegalMoves(board);
        var scored = scoreMoves(board, legal);

        for (0..scored.count) |i| {
            pickMove(&scored, i);
            const move = scored.moves[i];

            // Only search captures (they are sorted first with positive scores)
            if (!move.flags.isCapture()) break;

            const undo = board.makeMove(move);
            const score = -quiescence(board, -beta, -alpha, nodes, ply + 1);
            board.unmakeMove(move, undo);

            if (score >= beta) {
                return beta;
            }
            if (score > alpha) {
                alpha = score;
            }
        }

        return alpha;
    }

    // In check: must search all evasions
    const legal = movegen.generateLegalMoves(board);
    if (legal.count == 0) {
        // Checkmate — prefer shorter mates
        return -eval_mod.CHECKMATE_SCORE + @as(i32, @intCast(ply));
    }

    var scored = scoreMoves(board, legal);
    var alpha = alpha_in;

    for (0..scored.count) |i| {
        pickMove(&scored, i);
        const move = scored.moves[i];
        const undo = board.makeMove(move);
        const score = -quiescence(board, -beta, -alpha, nodes, ply + 1);
        board.unmakeMove(move, undo);

        if (score >= beta) {
            return beta;
        }
        if (score > alpha) {
            alpha = score;
        }
    }

    return alpha;
}

/// MVV-LVA scoring: captures get victim_value * 100 - attacker_value, quiet moves get 0.
fn scoreMoves(board: *const Board, legal: MoveList) ScoredMoveList {
    var result: ScoredMoveList = undefined;
    result.count = legal.count;

    const us_idx = @intFromEnum(board.side_to_move);
    const them_idx = us_idx ^ 1;

    for (0..legal.count) |i| {
        const move = legal.moves[i];
        result.moves[i] = move;

        if (move.flags.isCapture()) {
            const attacker = board.getPieceTypeAt(move.from, us_idx);
            const attacker_val = eval_mod.piece_values[@intFromEnum(attacker)];

            // En passant: victim is always a pawn
            const victim_val = if (move.flags == .ep_capture)
                eval_mod.piece_values[@intFromEnum(PieceType.pawn)]
            else
                eval_mod.piece_values[@intFromEnum(board.getPieceTypeAt(move.to, them_idx))];

            result.scores[i] = 10_000_000 + victim_val * 100 - attacker_val;
        } else {
            result.scores[i] = 0;
        }
    }

    return result;
}

/// Partial selection sort: swap the best-scored move to position `start`.
fn pickMove(scored: *ScoredMoveList, start: usize) void {
    var best_idx = start;
    var best_score = scored.scores[start];

    for (start + 1..scored.count) |i| {
        if (scored.scores[i] > best_score) {
            best_score = scored.scores[i];
            best_idx = i;
        }
    }

    if (best_idx != start) {
        const tmp_move = scored.moves[start];
        scored.moves[start] = scored.moves[best_idx];
        scored.moves[best_idx] = tmp_move;

        const tmp_score = scored.scores[start];
        scored.scores[start] = scored.scores[best_idx];
        scored.scores[best_idx] = tmp_score;
    }
}

test "mate in 1 found at depth 1" {
    // Scholar's mate position: white can play Qxf7# (or Qf7#)
    // After 1.e4 e5 2.Bc4 Nc6 3.Qh5 Nf6?? — Qxf7# is mate
    var board = Board.fromFen("r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4") catch unreachable;
    const result = searchIterative(&board, 1);
    try std.testing.expect(result.best_move != null);
    // The best move should capture on f7
    const move = result.best_move.?;
    const to_sq = @import("square.zig").Square;
    try std.testing.expectEqual(@intFromEnum(to_sq.f7), @as(u6, move.to));
    // Score should indicate checkmate
    try std.testing.expect(result.score >= eval_mod.CHECKMATE_SCORE - 256);
}

test "stalemate returns draw score" {
    // Classic stalemate: black king on a8, white king on c6, white queen on b6 — black to move
    var board = Board.fromFen("k7/8/1QK5/8/8/8/8/8 b - - 0 1") catch unreachable;
    const result = search(&board, 1);
    try std.testing.expectEqual(eval_mod.DRAW_SCORE, result.score);
}

test "iterative deepening returns a move from starting position" {
    var board = Board.init();
    const result = searchIterative(&board, 3);
    try std.testing.expect(result.best_move != null);
    try std.testing.expect(result.nodes > 0);
    try std.testing.expectEqual(@as(u32, 3), result.depth);
}
