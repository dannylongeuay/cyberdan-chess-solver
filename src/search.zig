const std = @import("std");
const types = @import("types.zig");
const bb = @import("bitboard.zig");
const board_mod = @import("board.zig");
const moves_mod = @import("moves.zig");
const movegen = @import("movegen.zig");
const eval_mod = @import("eval.zig");
const tt_mod = @import("tt.zig");

const Board = board_mod.Board;
const Move = moves_mod.Move;
const MoveFlags = moves_mod.MoveFlags;
const MoveList = moves_mod.MoveList;
const PieceType = types.PieceType;
const TranspositionTable = tt_mod.TranspositionTable;
const TTFlag = tt_mod.TTFlag;

pub const SearchResult = struct {
    best_move: ?Move,
    score: i32,
    nodes: u64,
    depth: u32,
};

pub const SearchOptions = struct {
    max_depth: u32 = 100,
    timeout_ns: ?u64 = null, // null = no timeout (depth-only)
};

const MAX_PLY = 128;
const MAX_HISTORY: i32 = 16384;

const SearchContext = struct {
    nodes: u64 = 0,
    stopped: bool = false,
    timer: ?std.time.Timer = null,
    timeout_ns: ?u64 = null,
    tt: ?*TranspositionTable = null,
    nominal_depth: u32 = 0,
    killers: [MAX_PLY][2]u16 = [_][2]u16{.{ 0, 0 }} ** MAX_PLY,
    history: [2][6][64]i32 = [_][6][64]i32{[_][64]i32{[_]i32{0} ** 64} ** 6} ** 2,

    fn init(options: SearchOptions, tt: ?*TranspositionTable) SearchContext {
        return .{
            .nodes = 0,
            .stopped = false,
            .timer = if (options.timeout_ns != null) std.time.Timer.start() catch null else null,
            .timeout_ns = options.timeout_ns,
            .tt = tt,
        };
    }

    fn updateHistory(self: *SearchContext, color: usize, piece: PieceType, to: u6, bonus: i32) void {
        const entry = &self.history[color][@intFromEnum(piece)][to];
        const abs_entry: i32 = if (entry.* < 0) -entry.* else entry.*;
        entry.* += bonus - @divTrunc(abs_entry * bonus, MAX_HISTORY);
    }

    /// Age history scores between iterative deepening iterations.
    fn ageHistory(self: *SearchContext) void {
        for (0..2) |color| {
            for (0..6) |piece| {
                for (0..64) |sq| {
                    self.history[color][piece][sq] = @divTrunc(self.history[color][piece][sq], 2);
                }
            }
        }
    }

    fn incrementNodes(self: *SearchContext) void {
        self.nodes += 1;
        if (self.nodes & 4095 == 0) {
            self.checkTimeout();
        }
    }

    fn checkTimeout(self: *SearchContext) void {
        if (self.timeout_ns) |timeout| {
            if (self.timer) |*timer| {
                if (timer.read() >= timeout) {
                    self.stopped = true;
                }
            }
        }
    }
};

const ScoredMoveList = struct {
    moves: [256]Move,
    scores: [256]i32,
    count: usize,
};

// LMR reduction table: lmr_table[depth][move_index]
// Formula: floor(0.75 + ln(depth) * ln(moveIndex) / 2.25)
const lmr_table: [64][64]u32 = blk: {
    @setEvalBranchQuota(10000);
    var table: [64][64]u32 = undefined;
    for (0..64) |d| {
        for (0..64) |m| {
            if (d == 0 or m == 0) {
                table[d][m] = 0;
            } else {
                const ln_d = @log(@as(f64, @floatFromInt(d)));
                const ln_m = @log(@as(f64, @floatFromInt(m)));
                const reduction = 0.75 + ln_d * ln_m / 2.25;
                table[d][m] = @intFromFloat(@max(reduction, 0.0));
            }
        }
    }
    break :blk table;
};

/// Iterative deepening entry point with aspiration windows.
pub fn searchIterative(board: *Board, options: SearchOptions, tt: ?*TranspositionTable) SearchResult {
    var best_result = SearchResult{
        .best_move = null,
        .score = 0,
        .nodes = 0,
        .depth = 0,
    };

    if (tt) |t| t.newSearch();

    var ctx = SearchContext.init(options, tt);

    const INITIAL_WINDOW: i32 = 25;
    const MAX_WINDOW: i32 = 500;

    var depth: u32 = 1;
    while (depth <= options.max_depth) : (depth += 1) {
        if (depth > 1) ctx.ageHistory();
        ctx.nominal_depth = depth;

        var result: SearchResult = undefined;

        if (depth <= 1) {
            // Full window for depth 1
            result = search(board, depth, &ctx);
        } else {
            // Aspiration window: start narrow, widen on fail
            var delta: i32 = INITIAL_WINDOW;
            var alpha: i32 = best_result.score - delta;
            var beta: i32 = best_result.score + delta;

            while (true) {
                result = searchWindow(board, depth, alpha, beta, &ctx);
                if (ctx.stopped) break;

                if (result.score <= alpha) {
                    // Fail-low: widen alpha
                    alpha = if (delta >= MAX_WINDOW) -eval_mod.CHECKMATE_SCORE - 1 else result.score - delta;
                    delta *= 2;
                } else if (result.score >= beta) {
                    // Fail-high: widen beta
                    beta = if (delta >= MAX_WINDOW) eval_mod.CHECKMATE_SCORE + 1 else result.score + delta;
                    delta *= 2;
                } else {
                    // Score within window
                    break;
                }

                // Fall back to full window if delta too large
                if (delta >= MAX_WINDOW) {
                    alpha = -eval_mod.CHECKMATE_SCORE - 1;
                    beta = eval_mod.CHECKMATE_SCORE + 1;
                }
            }
        }

        // If stopped mid-search, discard partial result
        if (ctx.stopped) break;

        best_result = result;
        best_result.depth = depth;
        best_result.nodes = ctx.nodes;

        // Early exit on checkmate found
        if (best_result.score >= eval_mod.CHECKMATE_SCORE - 256 or
            best_result.score <= -eval_mod.CHECKMATE_SCORE + 256)
        {
            break;
        }

        // Check timeout between depths
        ctx.checkTimeout();
        if (ctx.stopped) break;
    }

    return best_result;
}

/// Root-level alpha-beta search with full window.
fn search(board: *Board, depth: u32, ctx: *SearchContext) SearchResult {
    return searchWindow(board, depth, -eval_mod.CHECKMATE_SCORE - 1, eval_mod.CHECKMATE_SCORE + 1, ctx);
}

/// Root-level alpha-beta search with explicit window bounds.
fn searchWindow(board: *Board, depth: u32, alpha_in: i32, beta: i32, ctx: *SearchContext) SearchResult {
    const legal = movegen.generateLegalMoves(board);

    if (legal.count == 0) {
        // No legal moves: checkmate or stalemate
        if (board.isInCheck()) {
            return .{ .best_move = null, .score = -eval_mod.CHECKMATE_SCORE, .nodes = 1, .depth = depth };
        }
        return .{ .best_move = null, .score = eval_mod.DRAW_SCORE, .nodes = 1, .depth = depth };
    }

    // Probe TT for hash move ordering at root (no cutoffs)
    var tt_move_raw: u16 = 0;
    if (ctx.tt) |tt| {
        if (tt.probe(board.hash)) |entry| {
            tt_move_raw = entry.best_move;
        }
    }

    var scored = scoreMoves(board, legal, tt_move_raw, ctx, 0);
    var best_move: ?Move = null;
    var best_score: i32 = -eval_mod.CHECKMATE_SCORE - 1;
    var alpha: i32 = alpha_in;

    for (0..scored.count) |i| {
        pickMove(&scored, i);
        const move = scored.moves[i];
        const undo = board.makeMove(move);

        var score: i32 = undefined;
        if (i == 0) {
            // First move: full window search
            score = -negamax(board, depth - 1, -beta, -alpha, ctx, 1, true);
        } else {
            // PVS: null window search
            score = -negamax(board, depth - 1, -alpha - 1, -alpha, ctx, 1, true);
            // Re-search with full window if it improved alpha
            if (score > alpha and score < beta) {
                score = -negamax(board, depth - 1, -beta, -alpha, ctx, 1, true);
            }
        }

        board.unmakeMove(move, undo);

        if (ctx.stopped) break;

        if (score > best_score) {
            best_score = score;
            best_move = move;
        }
        if (score > alpha) {
            alpha = score;
        }
        if (alpha >= beta) break;
    }

    // Store root result in TT
    if (ctx.tt) |tt| {
        if (!ctx.stopped) {
            const flag: TTFlag = if (best_score <= alpha_in) .alpha else if (best_score >= beta) .beta else .exact;
            const move_raw: u16 = if (best_move) |m| @bitCast(m) else 0;
            tt.store(board.hash, @intCast(depth), tt_mod.scoreToTT(best_score, 0), flag, move_raw);
        }
    }

    return .{ .best_move = best_move, .score = best_score, .nodes = ctx.nodes, .depth = depth };
}

/// Recursive negamax with alpha-beta pruning, TT, NMP, and LMR.
fn negamax(board: *Board, depth: u32, alpha_in: i32, beta: i32, ctx: *SearchContext, ply: u32, allow_null: bool) i32 {
    if (ctx.stopped) return 0;

    if (depth == 0) {
        return quiescence(board, alpha_in, beta, ctx, ply);
    }

    ctx.incrementNodes();

    var alpha = alpha_in;

    // TT probe
    var tt_move_raw: u16 = 0;
    if (ctx.tt) |tt| {
        if (tt.probe(board.hash)) |entry| {
            tt_move_raw = entry.best_move;
            if (entry.depth >= @as(i8, @intCast(depth))) {
                const tt_score = tt_mod.scoreFromTT(entry.score, ply);
                switch (entry.flag) {
                    .exact => return tt_score,
                    .beta => {
                        if (tt_score >= beta) return tt_score;
                    },
                    .alpha => {
                        if (tt_score <= alpha) return tt_score;
                    },
                    .none => {},
                }
            }
        }
    }

    // Check if in check (reused for NMP guard and checkmate detection)
    const in_check = board.isInCheck();

    // Null Move Pruning
    if (!in_check and allow_null and depth >= 3 and !isPawnEndgame(board)) {
        const r: u32 = 2 + depth / 6;
        const reduced = if (depth > 1 + r) depth - 1 - r else 0;

        const null_undo = board.makeNullMove();
        const null_score = -negamax(board, reduced, -beta, -beta + 1, ctx, ply + 1, false);
        board.unmakeNullMove(null_undo);

        if (ctx.stopped) return 0;

        if (null_score >= beta) {
            return beta;
        }
    }

    const legal = movegen.generateLegalMoves(board);

    if (legal.count == 0) {
        if (in_check) {
            // Checkmate — prefer shorter mates
            return -eval_mod.CHECKMATE_SCORE + @as(i32, @intCast(ply));
        }
        return eval_mod.DRAW_SCORE;
    }

    var scored = scoreMoves(board, legal, tt_move_raw, ctx, ply);
    var best_move_raw: u16 = 0;
    var best_score: i32 = -eval_mod.CHECKMATE_SCORE - 1;
    var moves_searched: u32 = 0;
    var quiets_searched: [256]Move = undefined;
    var quiets_count: usize = 0;

    for (0..scored.count) |i| {
        pickMove(&scored, i);
        const move = scored.moves[i];
        const undo = board.makeMove(move);

        var score: i32 = undefined;

        // Late Move Reductions
        const is_quiet = !move.flags.isCapture() and !move.flags.isPromotion();
        const gives_check = board.isInCheck(); // checks side-to-move after makeMove

        // Check extension: search deeper when the move gives check
        const extension: u32 = if (gives_check and ply < 2 * ctx.nominal_depth) 1 else 0;
        const new_depth = depth - 1 + extension;

        const can_reduce = moves_searched >= 3 and depth >= 3 and is_quiet and !in_check and !gives_check;

        if (can_reduce) {
            const r = lmr_table[@min(depth, 63)][@min(moves_searched, 63)];
            const reduced_depth: u32 = if (new_depth > r) new_depth - r else 0;
            // LMR: null window search at reduced depth
            score = -negamax(board, reduced_depth, -alpha - 1, -alpha, ctx, ply + 1, true);
            // If LMR fails high, re-search at full depth with null window
            if (score > alpha) {
                score = -negamax(board, new_depth, -alpha - 1, -alpha, ctx, ply + 1, true);
                // PVS: if null window fails high within bounds, re-search with full window
                if (score > alpha and score < beta) {
                    score = -negamax(board, new_depth, -beta, -alpha, ctx, ply + 1, true);
                }
            }
        } else if (moves_searched == 0) {
            // First move: full window search
            score = -negamax(board, new_depth, -beta, -alpha, ctx, ply + 1, true);
        } else {
            // PVS: null window search for subsequent moves
            score = -negamax(board, new_depth, -alpha - 1, -alpha, ctx, ply + 1, true);
            // Re-search with full window if it improved alpha
            if (score > alpha and score < beta) {
                score = -negamax(board, new_depth, -beta, -alpha, ctx, ply + 1, true);
            }
        }

        board.unmakeMove(move, undo);

        if (ctx.stopped) return 0;

        if (score > best_score) {
            best_score = score;
            best_move_raw = @bitCast(move);
        }

        if (score >= beta) {
            // Update killer moves and history on beta cutoff for quiet moves
            if (is_quiet and ply < MAX_PLY) {
                const move_raw: u16 = @bitCast(move);
                // Update killers: shift slot 0 to slot 1, store new in slot 0
                if (ctx.killers[ply][0] != move_raw) {
                    ctx.killers[ply][1] = ctx.killers[ply][0];
                    ctx.killers[ply][0] = move_raw;
                }
                // Update history with gravity clamping
                const us_idx = @intFromEnum(board.side_to_move);
                const piece = board.getPieceTypeAt(move.from, us_idx);
                const bonus = @as(i32, @intCast(depth)) * @as(i32, @intCast(depth));
                ctx.updateHistory(us_idx, piece, move.to, bonus);

                // Malus: penalize all quiet moves that failed to cause cutoff
                for (0..quiets_count) |qi| {
                    const q = quiets_searched[qi];
                    const q_piece = board.getPieceTypeAt(q.from, us_idx);
                    ctx.updateHistory(us_idx, q_piece, q.to, -bonus);
                }
            }

            // Store beta cutoff in TT
            if (ctx.tt) |tt| {
                tt.store(board.hash, @intCast(depth), tt_mod.scoreToTT(score, ply), .beta, @bitCast(move));
            }
            return beta;
        }
        if (score > alpha) {
            alpha = score;
        }

        if (is_quiet) {
            if (quiets_count < quiets_searched.len) {
                quiets_searched[quiets_count] = move;
                quiets_count += 1;
            }
        }

        moves_searched += 1;
    }

    // Store in TT (skip if stopped — partial results would poison future lookups)
    if (ctx.tt) |tt| {
        if (!ctx.stopped) {
            const flag: TTFlag = if (best_score > alpha_in) .exact else .alpha;
            tt.store(board.hash, @intCast(depth), tt_mod.scoreToTT(best_score, ply), flag, best_move_raw);
        }
    }

    return alpha;
}

/// Quiescence search — only captures, to avoid horizon effect.
/// When in check, searches all evasions and detects checkmate.
fn quiescence(board: *Board, alpha_in: i32, beta: i32, ctx: *SearchContext, ply: u32) i32 {
    if (ctx.stopped) return 0;

    ctx.incrementNodes();

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
        var scored = scoreMoves(board, legal, 0, ctx, ply);

        for (0..scored.count) |i| {
            pickMove(&scored, i);
            const move = scored.moves[i];

            // Only search captures (they are sorted first with positive scores)
            if (!move.flags.isCapture()) break;

            const undo = board.makeMove(move);
            const score = -quiescence(board, -beta, -alpha, ctx, ply + 1);
            board.unmakeMove(move, undo);

            if (ctx.stopped) return 0;

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

    var scored = scoreMoves(board, legal, 0, ctx, ply);
    var alpha = alpha_in;

    for (0..scored.count) |i| {
        pickMove(&scored, i);
        const move = scored.moves[i];
        const undo = board.makeMove(move);
        const score = -quiescence(board, -beta, -alpha, ctx, ply + 1);
        board.unmakeMove(move, undo);

        if (ctx.stopped) return 0;

        if (score >= beta) {
            return beta;
        }
        if (score > alpha) {
            alpha = score;
        }
    }

    return alpha;
}

/// Returns true if the side to move has no non-pawn, non-king pieces (zugzwang risk).
fn isPawnEndgame(board: *const Board) bool {
    const us = @intFromEnum(board.side_to_move);
    return board.pieces[us][@intFromEnum(PieceType.knight)] == 0 and
        board.pieces[us][@intFromEnum(PieceType.bishop)] == 0 and
        board.pieces[us][@intFromEnum(PieceType.rook)] == 0 and
        board.pieces[us][@intFromEnum(PieceType.queen)] == 0;
}

/// MVV-LVA scoring with TT move priority, killer moves, and history heuristic.
/// TT move: 20M, captures: 10M + MVV-LVA, killers: 9M, quiets: history score.
fn scoreMoves(board: *const Board, legal: MoveList, tt_move_raw: u16, ctx: *const SearchContext, ply: u32) ScoredMoveList {
    var result: ScoredMoveList = undefined;
    result.count = legal.count;

    const us_idx = @intFromEnum(board.side_to_move);
    const them_idx = us_idx ^ 1;

    for (0..legal.count) |i| {
        const move = legal.moves[i];
        result.moves[i] = move;
        const move_raw: u16 = @bitCast(move);

        // TT move gets highest priority
        if (tt_move_raw != 0 and move_raw == tt_move_raw) {
            result.scores[i] = 20_000_000;
        } else if (move.flags.isCapture()) {
            const attacker = board.getPieceTypeAt(move.from, us_idx);
            const attacker_val = eval_mod.piece_values[@intFromEnum(attacker)];

            // En passant: victim is always a pawn
            const victim_val = if (move.flags == .ep_capture)
                eval_mod.piece_values[@intFromEnum(PieceType.pawn)]
            else
                eval_mod.piece_values[@intFromEnum(board.getPieceTypeAt(move.to, them_idx))];

            result.scores[i] = 10_000_000 + victim_val * 100 - attacker_val;
        } else if (ply < MAX_PLY and (move_raw == ctx.killers[ply][0] or move_raw == ctx.killers[ply][1])) {
            // Killer moves score below captures but above history
            result.scores[i] = 9_000_000;
        } else {
            // History heuristic for quiet moves
            const piece = board.getPieceTypeAt(move.from, us_idx);
            result.scores[i] = ctx.history[us_idx][@intFromEnum(piece)][move.to];
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
    const result = searchIterative(&board, .{ .max_depth = 1 }, null);
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
    var ctx = SearchContext.init(.{ .max_depth = 1 }, null);
    const result = search(&board, 1, &ctx);
    try std.testing.expectEqual(eval_mod.DRAW_SCORE, result.score);
}

test "iterative deepening returns a move from starting position" {
    var board = Board.init();
    const result = searchIterative(&board, .{ .max_depth = 3, .timeout_ns = 5_000_000_000 }, null);
    try std.testing.expect(result.best_move != null);
    try std.testing.expect(result.nodes > 0);
    try std.testing.expectEqual(@as(u32, 3), result.depth);
}

test "search with timeout returns a move" {
    var board = Board.init();
    const result = searchIterative(&board, .{ .timeout_ns = 10_000_000 }, null); // 10ms
    try std.testing.expect(result.best_move != null);
    try std.testing.expect(result.depth >= 1);
    try std.testing.expect(result.nodes > 0);
}

test "search with TT returns a move" {
    var tt = try TranspositionTable.init(std.testing.allocator, 1);
    defer tt.deinit();

    var board = Board.init();
    const result = searchIterative(&board, .{ .max_depth = 4, .timeout_ns = 5_000_000_000 }, &tt);
    try std.testing.expect(result.best_move != null);
    try std.testing.expect(result.nodes > 0);
    try std.testing.expectEqual(@as(u32, 4), result.depth);
}

test "LMR table has reasonable values" {
    // At depth 1, move 1: should be 0 or small
    try std.testing.expectEqual(@as(u32, 0), lmr_table[1][1]);
    // At higher depths and move indices, reduction should be positive
    try std.testing.expect(lmr_table[10][10] > 0);
    // Reduction should grow with depth and move index
    try std.testing.expect(lmr_table[20][20] > lmr_table[10][10]);
}

test "mate in 2 found at appropriate depth" {
    // 1.Ra1+ Kb8 2.Ra8#
    var board = Board.fromFen("k7/8/1K6/8/8/8/8/1R6 w - - 0 1") catch unreachable;
    const result = searchIterative(&board, .{ .max_depth = 4, .timeout_ns = 5_000_000_000 }, null);
    try std.testing.expect(result.best_move != null);
    // Score should indicate checkmate within 4 ply
    try std.testing.expect(result.score >= eval_mod.CHECKMATE_SCORE - 4);
}

test "mate distance preference — mate-in-1 scores higher than mate-in-3" {
    // Mate-in-1: Qxf7# position
    var board_m1 = Board.fromFen("r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4") catch unreachable;
    const result_m1 = searchIterative(&board_m1, .{ .max_depth = 6, .timeout_ns = 5_000_000_000 }, null);

    // Mate-in-2: k7/8/1K6/8/8/8/8/1R6 w - - 0 1 (Ra1+, Kb8, Ra8#)
    var board_m2 = Board.fromFen("k7/8/1K6/8/8/8/8/1R6 w - - 0 1") catch unreachable;
    const result_m2 = searchIterative(&board_m2, .{ .max_depth = 6, .timeout_ns = 5_000_000_000 }, null);

    // Mate-in-1 score should be higher (closer to CHECKMATE_SCORE)
    try std.testing.expect(result_m1.score > result_m2.score);
    // Both should be checkmate scores
    try std.testing.expect(result_m1.score >= eval_mod.CHECKMATE_SCORE - 2);
    try std.testing.expect(result_m2.score >= eval_mod.CHECKMATE_SCORE - 4);
}

test "avoids being mated — finds the only non-losing move" {
    // Black queen on a2 threatens Qa1#. White must defend (e.g. Rd8+, g3, h3).
    var board = Board.fromFen("6k1/5ppp/8/8/8/8/q4PPP/3R2K1 w - - 0 1") catch unreachable;
    const result = searchIterative(&board, .{ .max_depth = 4, .timeout_ns = 5_000_000_000 }, null);
    try std.testing.expect(result.best_move != null);
    // Engine should not be getting mated — score should not be a checkmate loss
    try std.testing.expect(result.score > -eval_mod.CHECKMATE_SCORE + 256);
}

test "simple tactic — finds winning capture of hanging queen" {
    // Black queen hanging on d5, white knight on c3 can capture
    // 4k3/8/8/3q4/8/2N5/8/4K3 w - - 0 1
    var board = Board.fromFen("4k3/8/8/3q4/8/2N5/8/4K3 w - - 0 1") catch unreachable;
    const result = searchIterative(&board, .{ .max_depth = 3, .timeout_ns = 5_000_000_000 }, null);
    try std.testing.expect(result.best_move != null);
    const move = result.best_move.?;
    const Square = @import("square.zig").Square;
    // Knight should capture queen on d5
    try std.testing.expectEqual(@intFromEnum(Square.d5), @as(u6, move.to));
    try std.testing.expect(move.flags.isCapture());
    // Score should reflect a significant material advantage (queen capture)
    try std.testing.expect(result.score > 200);
}

test "null move pruning does not prune when in check" {
    // Position where white is in check — NMP must be skipped, search must work correctly
    // 4k3/8/8/8/8/8/3q4/3K4 w - - 0 1 — white king on d1, black queen on d2 gives check
    // Wait: d2 to d1 is one square on the d-file, so queen on d2 does check king on d1.
    // White must move the king. Only legal moves are Kc1, Ke1, Kc2, Ke2.
    // After Kc2 or Ke2 the queen can chase, but at low depth it should find a move.
    var board = Board.fromFen("4k3/8/8/8/8/8/3q4/3K4 w - - 0 1") catch unreachable;
    try std.testing.expect(board.isInCheck());
    const result = searchIterative(&board, .{ .max_depth = 3, .timeout_ns = 5_000_000_000 }, null);
    try std.testing.expect(result.best_move != null);
    // Engine must find a legal evasion (not crash/hang from NMP in check)
}

test "null move pruning skipped in pawn endgame" {
    // K+P vs K+P — isPawnEndgame should be true, NMP disabled
    // 8/4k3/8/4p3/4P3/8/4K3/8 w - - 0 1
    var board = Board.fromFen("8/4k3/8/4p3/4P3/8/4K3/8 w - - 0 1") catch unreachable;
    try std.testing.expect(isPawnEndgame(&board));
    const result = searchIterative(&board, .{ .max_depth = 4, .timeout_ns = 5_000_000_000 }, null);
    try std.testing.expect(result.best_move != null);
    // Should return a reasonable eval (drawn-ish position)
    try std.testing.expect(result.score > -500 and result.score < 500);
}

test "quiescence resolves hanging piece — qsearch changes assessment" {
    // White has a knight that can capture a hanging black bishop on d5.
    // Static eval sees roughly equal material, but Nxd5 wins a piece.
    // 4k3/8/8/3b4/8/2N5/8/4K3 w - - 0 1
    // White: K + N (320). Black: K + B (330). Static eval slightly negative for white.
    // After Nxd5: White: K + N (320) vs Black: K (0). Much better for white.
    var board = Board.fromFen("4k3/8/8/3b4/8/2N5/8/4K3 w - - 0 1") catch unreachable;
    const static_score = eval_mod.evaluate(&board);
    var ctx = SearchContext.init(.{ .max_depth = 1 }, null);
    const qscore = quiescence(&board, -eval_mod.CHECKMATE_SCORE - 1, eval_mod.CHECKMATE_SCORE + 1, &ctx, 0);
    // Quiescence should find the winning capture and score higher than static eval
    try std.testing.expect(qscore > static_score);
}

test "quiescence detects checkmate when in check with no evasions" {
    // Scholar's mate final position — black king has no legal moves.
    var board = Board.fromFen("r1bqkb1r/pppp1Qpp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 0 4") catch unreachable;
    try std.testing.expect(board.isInCheck());
    const legal = movegen.generateLegalMoves(&board);
    try std.testing.expectEqual(@as(usize, 0), legal.count);
    var ctx = SearchContext.init(.{ .max_depth = 1 }, null);
    const score = quiescence(&board, -eval_mod.CHECKMATE_SCORE - 1, eval_mod.CHECKMATE_SCORE + 1, &ctx, 0);
    // Should detect checkmate (negative checkmate score from black's perspective)
    try std.testing.expect(score <= -eval_mod.CHECKMATE_SCORE + 256);
}
