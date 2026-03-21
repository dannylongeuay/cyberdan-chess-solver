const std = @import("std");
const types = @import("types.zig");
const bb = @import("bitboard.zig");
const board_mod = @import("board.zig");
const movegen = @import("movegen.zig");
const moves_mod = @import("moves.zig");

const Color = types.Color;
const PieceType = types.PieceType;
const Bitboard = bb.Bitboard;
const Board = board_mod.Board;
const Move = moves_mod.Move;
const UndoInfo = board_mod.UndoInfo;

pub const GameResult = enum {
    ongoing,
    white_wins,
    black_wins,
    draw_stalemate,
    draw_fifty_move,
    draw_threefold,
    draw_insufficient,
};

const HistoryEntry = struct {
    hash: u64,
    move: Move,
    undo: UndoInfo,
};

pub const GameState = struct {
    board: Board,
    history: [1024]HistoryEntry,
    history_len: usize,

    pub fn init() GameState {
        return initFromFen(Board.starting_fen) catch unreachable;
    }

    pub fn initFromFen(fen: []const u8) !GameState {
        return .{
            .board = try Board.fromFen(fen),
            .history = undefined,
            .history_len = 0,
        };
    }

    pub fn makeMove(self: *GameState, move: Move) void {
        const hash = self.board.hash;
        const undo = self.board.makeMove(move);
        self.history[self.history_len] = .{
            .hash = hash,
            .move = move,
            .undo = undo,
        };
        self.history_len += 1;
    }

    pub fn unmakeMove(self: *GameState) void {
        if (self.history_len == 0) return;
        self.history_len -= 1;
        const entry = self.history[self.history_len];
        self.board.unmakeMove(entry.move, entry.undo);
    }

    pub fn isInCheck(self: *const GameState) bool {
        return self.board.isInCheck();
    }

    pub fn isCheckmate(self: *GameState) bool {
        if (!self.isInCheck()) return false;
        const legal = movegen.generateLegalMoves(&self.board);
        return legal.count == 0;
    }

    pub fn isStalemate(self: *GameState) bool {
        if (self.isInCheck()) return false;
        const legal = movegen.generateLegalMoves(&self.board);
        return legal.count == 0;
    }

    pub fn isFiftyMoveRule(self: *const GameState) bool {
        return self.board.halfmove_clock >= 100;
    }

    pub fn isThreefoldRepetition(self: *const GameState) bool {
        const current_hash = self.board.hash;
        var count: u32 = 1; // current position counts as 1

        // Only need to check positions with the same side to move (every 2 plies)
        // and only back to the last irreversible move
        var i = self.history_len;
        var plies_back: u32 = 0;
        while (i > 0) {
            i -= 1;
            plies_back += 1;

            // Stop at irreversible moves (captures, pawn moves, castling rights changes)
            if (self.history[i].undo.halfmove_clock == 0) break;

            // Only check same side to move (every 2 plies)
            if (plies_back % 2 == 0) {
                if (self.history[i].hash == current_hash) {
                    count += 1;
                    if (count >= 3) return true;
                }
            }
        }

        return false;
    }

    pub fn isInsufficientMaterial(self: *const GameState) bool {
        const b = &self.board;

        // If any pawns, rooks, or queens exist, material is sufficient
        if (b.pieces[0][@intFromEnum(PieceType.pawn)] != 0) return false;
        if (b.pieces[1][@intFromEnum(PieceType.pawn)] != 0) return false;
        if (b.pieces[0][@intFromEnum(PieceType.rook)] != 0) return false;
        if (b.pieces[1][@intFromEnum(PieceType.rook)] != 0) return false;
        if (b.pieces[0][@intFromEnum(PieceType.queen)] != 0) return false;
        if (b.pieces[1][@intFromEnum(PieceType.queen)] != 0) return false;

        const w_knights = bb.popCount(b.pieces[0][@intFromEnum(PieceType.knight)]);
        const w_bishops = bb.popCount(b.pieces[0][@intFromEnum(PieceType.bishop)]);
        const b_knights = bb.popCount(b.pieces[1][@intFromEnum(PieceType.knight)]);
        const b_bishops = bb.popCount(b.pieces[1][@intFromEnum(PieceType.bishop)]);

        const w_minor = w_knights + w_bishops;
        const b_minor = b_knights + b_bishops;

        // K vs K
        if (w_minor == 0 and b_minor == 0) return true;
        // K+N vs K or K+B vs K
        if (w_minor == 0 and b_minor == 1) return true;
        if (w_minor == 1 and b_minor == 0) return true;
        // K+B vs K+B (same color bishops)
        if (w_minor == 1 and b_minor == 1 and w_bishops == 1 and b_bishops == 1) {
            const w_bsq = bb.lsb(b.pieces[0][@intFromEnum(PieceType.bishop)]);
            const b_bsq = bb.lsb(b.pieces[1][@intFromEnum(PieceType.bishop)]);
            // Same color if both on same square color (rank+file parity)
            const w_color = (@as(u8, w_bsq >> 3) + @as(u8, w_bsq & 7)) % 2;
            const b_color = (@as(u8, b_bsq >> 3) + @as(u8, b_bsq & 7)) % 2;
            if (w_color == b_color) return true;
        }

        return false;
    }

    pub fn gameResult(self: *GameState) GameResult {
        // Check checkmate/stalemate first (FIDE rules: checkmate takes priority over draws)
        const legal = movegen.generateLegalMoves(&self.board);
        if (legal.count == 0) {
            if (self.isInCheck()) {
                return if (self.board.side_to_move == .white) .black_wins else .white_wins;
            } else {
                return .draw_stalemate;
            }
        }

        if (self.isInsufficientMaterial()) return .draw_insufficient;
        if (self.isFiftyMoveRule()) return .draw_fifty_move;
        if (self.isThreefoldRepetition()) return .draw_threefold;

        return .ongoing;
    }

    pub fn resultString(result: GameResult) []const u8 {
        return switch (result) {
            .ongoing => "Game in progress",
            .white_wins => "1-0 White wins by checkmate",
            .black_wins => "0-1 Black wins by checkmate",
            .draw_stalemate => "1/2-1/2 Draw by stalemate",
            .draw_fifty_move => "1/2-1/2 Draw by fifty-move rule",
            .draw_threefold => "1/2-1/2 Draw by threefold repetition",
            .draw_insufficient => "1/2-1/2 Draw by insufficient material",
        };
    }
};

test "checkmate detection" {
    // Scholar's mate final position: 1.e4 e5 2.Bc4 Nc6 3.Qh5 Nf6 4.Qxf7#
    var game = try GameState.initFromFen("r1bqkb1r/pppp1Qpp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 0 4");
    try std.testing.expectEqual(GameResult.white_wins, game.gameResult());
}

test "stalemate detection" {
    // Classic stalemate: K on a8, white Q on b6, white K on c8... let me use a known stalemate
    // white K on g6, white Q on f7, black K on h8 - black has no legal moves, not in check
    var game2 = try GameState.initFromFen("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1");
    try std.testing.expectEqual(GameResult.draw_stalemate, game2.gameResult());
}

test "insufficient material" {
    // K vs K
    var game = try GameState.initFromFen("4k3/8/8/8/8/8/8/4K3 w - - 0 1");
    try std.testing.expect(game.isInsufficientMaterial());

    // K+B vs K
    var game2 = try GameState.initFromFen("4k3/8/8/8/8/8/8/4KB2 w - - 0 1");
    try std.testing.expect(game2.isInsufficientMaterial());

    // K+R vs K (sufficient)
    var game3 = try GameState.initFromFen("4k3/8/8/8/8/8/8/4KR2 w - - 0 1");
    try std.testing.expect(!game3.isInsufficientMaterial());
}

test "threefold repetition detection" {
    // Start from a simple position and repeat moves: Ke1-e2-e1-e2-e1
    // But we need both sides to move. Let's use kings shuffling:
    // 4k3/8/8/8/8/8/8/4K3 w - - 0 1
    // 1.Ke2 Ke7 2.Ke1 Ke8 3.Ke2 Ke7 — after 3...Ke7 the position repeats for the 3rd time.
    // Actually: position after move 0: Ke1,Ke8. After 1.Ke2 Ke7: Ke2,Ke7.
    // After 2.Ke1 Ke8: Ke1,Ke8 (same as start = 2nd occurrence).
    // After 3.Ke2 Ke7: Ke2,Ke7 (same as after move 1 = 2nd occurrence).
    // After 4.Ke1 Ke8: Ke1,Ke8 (3rd occurrence!)
    // Use halfmove_clock > 0 so the irreversible-move check doesn't stop the scan early
    var game = try GameState.initFromFen("4k3/8/8/8/8/8/8/4K3 w - - 10 1");

    const sq = @import("square.zig").Square;

    const e1: u6 = @intFromEnum(sq.e1);
    const e2: u6 = @intFromEnum(sq.e2);
    const e8: u6 = @intFromEnum(sq.e8);
    const e7: u6 = @intFromEnum(sq.e7);

    const ke1_e2 = Move{ .from = e1, .to = e2, .flags = .quiet };
    const ke8_e7 = Move{ .from = e8, .to = e7, .flags = .quiet };
    const ke2_e1 = Move{ .from = e2, .to = e1, .flags = .quiet };
    const ke7_e8 = Move{ .from = e7, .to = e8, .flags = .quiet };

    // Round 1
    game.makeMove(ke1_e2); // w: Ke2
    game.makeMove(ke8_e7); // b: Ke7
    try std.testing.expect(!game.isThreefoldRepetition());

    // Round 2 — back to start
    game.makeMove(ke2_e1); // w: Ke1
    game.makeMove(ke7_e8); // b: Ke8 (2nd occurrence of starting position)
    try std.testing.expect(!game.isThreefoldRepetition());

    // Round 3
    game.makeMove(ke1_e2); // w: Ke2
    game.makeMove(ke8_e7); // b: Ke7 (2nd occurrence of Ke2/Ke7)
    try std.testing.expect(!game.isThreefoldRepetition());

    // Round 4 — back to start again
    game.makeMove(ke2_e1); // w: Ke1
    game.makeMove(ke7_e8); // b: Ke8 (3rd occurrence!)
    try std.testing.expect(game.isThreefoldRepetition());
}

test "fifty-move rule detection" {
    // Set up position with halfmove_clock = 99
    var game = try GameState.initFromFen("4k3/8/8/8/8/8/8/4K3 w - - 99 50");
    try std.testing.expect(!game.isFiftyMoveRule()); // 99 < 100

    // Make one more non-capture, non-pawn move — clock becomes 100
    const e1: u6 = @intFromEnum(@import("square.zig").Square.e1);
    const e2: u6 = @intFromEnum(@import("square.zig").Square.e2);
    const ke1_e2 = moves_mod.Move{ .from = e1, .to = e2, .flags = .quiet };
    game.makeMove(ke1_e2);
    try std.testing.expect(game.isFiftyMoveRule()); // 100 >= 100
}
