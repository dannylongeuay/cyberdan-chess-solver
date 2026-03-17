const std = @import("std");
const board_mod = @import("board.zig");
const moves_mod = @import("moves.zig");
const square_mod = @import("square.zig");
const types = @import("types.zig");

const Board = board_mod.Board;
const Move = moves_mod.Move;
const MoveFlags = moves_mod.MoveFlags;
const PieceType = types.PieceType;

const max_book_moves = 8;

const BookEntry = struct {
    fen: []const u8,
    moves: []const []const u8,
};

const BookLookup = struct {
    hash: u64,
    moves: [max_book_moves]Move,
    count: u8,
};

pub const BookHit = struct {
    moves: []const Move,

    pub fn pickRandom(self: BookHit) Move {
        if (self.moves.len == 1) return self.moves[0];
        const ts: u128 = @bitCast(std.time.nanoTimestamp());
        const idx = @as(usize, @truncate(ts)) % self.moves.len;
        return self.moves[idx];
    }
};

// ── Book entries: FEN + UCI move strings ──────────────────────────────

const book_entries = [_]BookEntry{
    // Starting position
    .{ .fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", .moves = &.{ "e2e4", "d2d4" } },

    // After 1.e4
    .{ .fen = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1", .moves = &.{ "e7e5", "c7c5", "c7c6" } },

    // After 1.d4
    .{ .fen = "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1", .moves = &.{ "d7d5", "g8f6" } },

    // After 1.Nf3
    .{ .fen = "rnbqkbnr/pppppppp/8/8/8/5N2/PPPPPPPP/RNBQKB1R b KQkq - 1 1", .moves = &.{"d7d5"} },

    // After 1.c4 (English)
    .{ .fen = "rnbqkbnr/pppppppp/8/8/2P5/8/PP1PPPPP/RNBQKBNR b KQkq - 0 1", .moves = &.{"e7e5"} },

    // After 1.e4 e5
    .{ .fen = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2", .moves = &.{"g1f3"} },

    // After 1.e4 c5 (Sicilian)
    .{ .fen = "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2", .moves = &.{"g1f3"} },

    // After 1.e4 e6 (French)
    .{ .fen = "rnbqkbnr/pppp1ppp/4p3/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2", .moves = &.{"d2d4"} },

    // After 1.e4 c6 (Caro-Kann)
    .{ .fen = "rnbqkbnr/pp1ppppp/2p5/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2", .moves = &.{"d2d4"} },

    // After 1.d4 d5
    .{ .fen = "rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 2", .moves = &.{"g1f3"} },

    // After 1.d4 Nf6
    .{ .fen = "rnbqkb1r/pppppppp/5n2/8/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 1 2", .moves = &.{"c2c4"} },

    // After 1.e4 e5 2.Nf3
    .{ .fen = "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2", .moves = &.{"b8c6"} },

    // After 1.d4 Nf6 2.c4
    .{ .fen = "rnbqkb1r/pppppppp/5n2/8/2PP4/8/PP2PPPP/RNBQKBNR b KQkq - 0 2", .moves = &.{"e7e6"} },

    // After 1.d4 d5 2.c4 (Queen's Gambit)
    .{ .fen = "rnbqkbnr/ppp1pppp/8/3p4/2PP4/8/PP2PPPP/RNBQKBNR b KQkq - 0 2", .moves = &.{"c7c6"} },

    // After 1.e4 e5 2.Nf3 Nc6
    .{ .fen = "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3", .moves = &.{"f1b5"} },
};

// ── Comptime table builder ────────────────────────────────────────────

fn parseUciComptime(uci: []const u8, board: Board) Move {
    const from_sq = square_mod.Square.fromString(uci[0..2]).?;
    const to_sq = square_mod.Square.fromString(uci[2..4]).?;
    const from: u6 = @intFromEnum(from_sq);
    const to: u6 = @intFromEnum(to_sq);

    const enemy_idx = @intFromEnum(board.side_to_move) ^ 1;
    const to_bit = @as(u64, 1) << to;
    const is_capture = board.occupancy[enemy_idx] & to_bit != 0;

    // Promotion (5th character)
    if (uci.len >= 5) {
        const promo: PieceType = PieceType.fromChar(uci[4]).?;
        const flags: MoveFlags = if (is_capture) switch (promo) {
            .queen => .queen_promo_capture,
            .rook => .rook_promo_capture,
            .bishop => .bishop_promo_capture,
            .knight => .knight_promo_capture,
            else => unreachable,
        } else switch (promo) {
            .queen => .queen_promotion,
            .rook => .rook_promotion,
            .bishop => .bishop_promotion,
            .knight => .knight_promotion,
            else => unreachable,
        };
        return .{ .from = from, .to = to, .flags = flags };
    }

    // Determine moving piece type
    const us_idx = @intFromEnum(board.side_to_move);
    const piece_type = board.getPieceTypeAt(from, us_idx);

    // Castling: king moves 2 files
    if (piece_type == .king) {
        const ff = from_sq.file();
        const tf = to_sq.file();
        if (tf > ff and tf - ff == 2) return .{ .from = from, .to = to, .flags = .king_castle };
        if (ff > tf and ff - tf == 2) return .{ .from = from, .to = to, .flags = .queen_castle };
    }

    // Pawn special moves
    if (piece_type == .pawn) {
        // En passant
        if (board.en_passant) |ep| {
            if (to == ep) return .{ .from = from, .to = to, .flags = .ep_capture };
        }
        // Double pawn push
        const fr = from_sq.rank();
        const tr = to_sq.rank();
        const rank_diff = if (tr > fr) tr - fr else fr - tr;
        if (rank_diff == 2) return .{ .from = from, .to = to, .flags = .double_pawn_push };
    }

    // Regular capture or quiet
    if (is_capture) return .{ .from = from, .to = to, .flags = .capture };
    return .{ .from = from, .to = to, .flags = .quiet };
}

const book_table: [book_entries.len]BookLookup = blk: {
    @setEvalBranchQuota(1_000_000);
    var table: [book_entries.len]BookLookup = undefined;
    for (book_entries, 0..) |entry, i| {
        const board = Board.fromFen(entry.fen) catch unreachable;
        table[i].hash = board.hash;
        if (entry.moves.len > max_book_moves) @compileError("too many book moves");
        table[i].count = @intCast(entry.moves.len);
        for (entry.moves, 0..) |uci, j| {
            table[i].moves[j] = parseUciComptime(uci, board);
        }
    }
    break :blk table;
};

// ── Runtime probe ─────────────────────────────────────────────────────

pub fn probe(hash: u64) ?BookHit {
    for (0..book_table.len) |i| {
        if (book_table[i].hash == hash) {
            return .{ .moves = book_table[i].moves[0..book_table[i].count] };
        }
    }
    return null;
}

// ── Tests ─────────────────────────────────────────────────────────────

test "probe starting position" {
    const board = Board.init();
    const hit = probe(board.hash) orelse return error.ExpectedBookHit;
    try std.testing.expectEqual(@as(usize, 4), hit.moves.len);
}

test "probe returns null for unknown position" {
    // Random endgame position — not in book
    const board = Board.fromFen("8/8/4k3/8/8/4K3/8/8 w - - 0 1") catch unreachable;
    try std.testing.expectEqual(@as(?BookHit, null), probe(board.hash));
}

test "book moves have valid squares" {
    for (0..book_table.len) |i| {
        const entry = book_table[i];
        for (entry.moves[0..entry.count]) |move| {
            try std.testing.expect(move.from < 64);
            try std.testing.expect(move.to < 64);
        }
    }
}

test "book move flags are correct" {
    // Starting position: e2e4 should be double_pawn_push
    const board = Board.init();
    const hit = probe(board.hash).?;
    // First entry is e2e4
    const e2e4 = hit.moves[0];
    try std.testing.expectEqual(MoveFlags.double_pawn_push, e2e4.flags);
    try std.testing.expectEqual(@as(u6, @intFromEnum(@import("square.zig").Square.e2)), e2e4.from);
    try std.testing.expectEqual(@as(u6, @intFromEnum(@import("square.zig").Square.e4)), e2e4.to);
}

test "book capture move flag" {
    // Queen's Gambit Accepted: d5c4 should be a capture
    const board = Board.fromFen("rnbqkbnr/ppp1pppp/8/3p4/2PP4/8/PP2PPPP/RNBQKBNR b KQkq c3 0 2") catch unreachable;
    const hit = probe(board.hash) orelse return error.ExpectedBookHit;
    // d5c4 is the third move in this entry
    const dxc4 = hit.moves[2];
    try std.testing.expectEqual(MoveFlags.capture, dxc4.flags);
}

test "pickRandom returns valid move" {
    const board = Board.init();
    const hit = probe(board.hash).?;
    const move = hit.pickRandom();
    try std.testing.expect(move.from < 64);
    try std.testing.expect(move.to < 64);
}
