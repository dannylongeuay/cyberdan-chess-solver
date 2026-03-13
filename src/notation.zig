const std = @import("std");
const types = @import("types.zig");
const square_mod = @import("square.zig");
const bb = @import("bitboard.zig");
const moves_mod = @import("moves.zig");
const movegen = @import("movegen.zig");
const board_mod = @import("board.zig");
const magics = @import("magics.zig");

const Color = types.Color;
const PieceType = types.PieceType;
const Square = square_mod.Square;
const Move = moves_mod.Move;
const MoveFlags = moves_mod.MoveFlags;
const MoveList = moves_mod.MoveList;
const Board = board_mod.Board;

/// Parse a move from user input. Accepts:
/// - Long algebraic: e2e4, e7e8q
/// - SAN: Nf3, exd5, O-O, e8=Q
/// Returns null if the input doesn't match any legal move.
pub fn parseMove(input: []const u8, board: *Board) ?Move {
    const trimmed = std.mem.trim(u8, input, &[_]u8{ ' ', '\t', '\n', '\r' });
    if (trimmed.len == 0) return null;

    const legal = movegen.generateLegalMoves(board);

    // Try castling notation
    if (isCastlingKingside(trimmed)) {
        for (legal.slice()) |move| {
            if (move.flags == .king_castle) return move;
        }
        return null;
    }
    if (isCastlingQueenside(trimmed)) {
        for (legal.slice()) |move| {
            if (move.flags == .queen_castle) return move;
        }
        return null;
    }

    // Try long algebraic: e2e4 or e7e8q
    if (trimmed.len >= 4) {
        if (tryLongAlgebraic(trimmed, legal)) |move| return move;
    }

    // Try SAN
    return parseSAN(trimmed, legal, board);
}

fn parsePromotionChar(ch: u8) ?PieceType {
    return switch (ch) {
        'q', 'Q' => .queen,
        'r', 'R' => .rook,
        'b', 'B' => .bishop,
        'n', 'N' => .knight,
        else => null,
    };
}

fn tryLongAlgebraic(trimmed: []const u8, legal: MoveList) ?Move {
    const from_sq = Square.fromString(trimmed[0..2]) orelse return null;
    const to_sq = Square.fromString(trimmed[2..4]) orelse return null;
    const from: u6 = @intFromEnum(from_sq);
    const to: u6 = @intFromEnum(to_sq);

    var promo_type: ?PieceType = null;
    if (trimmed.len >= 5) {
        if (trimmed[4] == '=') {
            if (trimmed.len >= 6) promo_type = parsePromotionChar(trimmed[5]);
        } else {
            promo_type = parsePromotionChar(trimmed[4]);
        }
    }

    for (legal.slice()) |move| {
        if (move.from == from and move.to == to) {
            if (move.flags.isPromotion()) {
                if (promo_type) |pt| {
                    if (move.flags.promotionPieceType().? == pt) return move;
                }
            } else {
                return move;
            }
        }
    }

    return null;
}

fn parseSAN(san: []const u8, legal: MoveList, board: *const Board) ?Move {
    var s = san;

    // Strip check/checkmate markers
    while (s.len > 0 and (s[s.len - 1] == '+' or s[s.len - 1] == '#')) {
        s = s[0 .. s.len - 1];
    }

    if (s.len < 2) return null;

    // Pawn moves start with lowercase file letter
    if (s[0] >= 'a' and s[0] <= 'h') {
        return parsePawnSAN(s, legal);
    }

    // Piece moves: Nf3, Bxe5, Rad1, etc.
    const piece_type: PieceType = switch (s[0]) {
        'N' => .knight,
        'B' => .bishop,
        'R' => .rook,
        'Q' => .queen,
        'K' => .king,
        else => return null,
    };
    s = s[1..];

    // Parse target square (last 2 chars)
    if (s.len < 2) return null;
    const target = Square.fromString(s[s.len - 2 .. s.len]) orelse return null;
    const to: u6 = @intFromEnum(target);

    // Parse disambiguation from prefix (everything before target square, minus 'x')
    var prefix = s[0 .. s.len - 2];
    if (prefix.len > 0 and prefix[prefix.len - 1] == 'x') {
        prefix = prefix[0 .. prefix.len - 1];
    }

    var disambig_file: ?u3 = null;
    var disambig_rank: ?u3 = null;

    if (prefix.len >= 1) {
        if (prefix[0] >= 'a' and prefix[0] <= 'h') {
            disambig_file = @intCast(prefix[0] - 'a');
        } else if (prefix[0] >= '1' and prefix[0] <= '8') {
            disambig_rank = @intCast(prefix[0] - '1');
        }
    }
    if (prefix.len >= 2) {
        if (prefix[1] >= '1' and prefix[1] <= '8') {
            disambig_rank = @intCast(prefix[1] - '1');
        }
    }

    const us_idx = @intFromEnum(board.side_to_move);

    for (legal.slice()) |move| {
        if (move.to != to) continue;
        if (move.flags == .king_castle or move.flags == .queen_castle) continue;
        if (move.flags.isPromotion()) continue;

        // Check piece type at from square
        const from_pt = board.getPieceTypeAt(move.from, us_idx);
        if (from_pt != piece_type) continue;

        // Check disambiguation
        const from_sq: Square = @enumFromInt(move.from);
        if (disambig_file) |f| {
            if (from_sq.file() != f) continue;
        }
        if (disambig_rank) |r| {
            if (from_sq.rank() != r) continue;
        }

        return move;
    }

    return null;
}

fn parsePawnSAN(s: []const u8, legal: MoveList) ?Move {
    var input = s;

    // Check for promotion suffix: =Q, =R, =B, =N
    var promo_type: ?PieceType = null;
    if (input.len >= 2) {
        const last = input[input.len - 1];
        const second_last = input[input.len - 2];
        if (second_last == '=') {
            promo_type = parsePromotionChar(last);
            if (promo_type != null) {
                input = input[0 .. input.len - 2];
            }
        }
    }

    if (input.len == 2) {
        // Simple pawn push: e4
        const target = Square.fromString(input[0..2]) orelse return null;
        const to: u6 = @intFromEnum(target);

        for (legal.slice()) |move| {
            if (move.to != to) continue;
            if (move.flags.isCapture()) continue;
            if (move.flags == .quiet or move.flags == .double_pawn_push or move.flags.isPromotion()) {
                if (matchPromotion(move, promo_type)) return move;
            }
        }
    } else if (input.len >= 4 and input[1] == 'x') {
        // Pawn capture: exd5
        const from_file: u3 = @intCast(input[0] - 'a');
        const target = Square.fromString(input[2..4]) orelse return null;
        const to: u6 = @intFromEnum(target);

        for (legal.slice()) |move| {
            if (move.to != to) continue;
            const from_sq: Square = @enumFromInt(move.from);
            if (from_sq.file() != from_file) continue;
            if (move.flags.isCapture()) {
                if (matchPromotion(move, promo_type)) return move;
            }
        }
    }

    return null;
}

fn matchPromotion(move: Move, promo_type: ?PieceType) bool {
    if (move.flags.isPromotion()) {
        if (promo_type) |pt| {
            return move.flags.promotionPieceType().? == pt;
        }
        return false;
    }
    return promo_type == null;
}

fn isCastlingKingside(s: []const u8) bool {
    return std.mem.eql(u8, s, "O-O") or std.mem.eql(u8, s, "0-0");
}

fn isCastlingQueenside(s: []const u8) bool {
    return std.mem.eql(u8, s, "O-O-O") or std.mem.eql(u8, s, "0-0-0");
}

/// Format a move in SAN notation. If `legal_moves` is provided, it is used for
/// disambiguation instead of regenerating legal moves internally.
pub fn moveToSAN(move: Move, board: *Board, buf: []u8, legal_moves: ?MoveList) []const u8 {
    var idx: usize = 0;

    if (move.flags == .king_castle) {
        @memcpy(buf[0..3], "O-O");
        idx = 3;
    } else if (move.flags == .queen_castle) {
        @memcpy(buf[0..5], "O-O-O");
        idx = 5;
    } else {
        const from_sq: Square = @enumFromInt(move.from);
        const to_sq: Square = @enumFromInt(move.to);
        const us_idx = @intFromEnum(board.side_to_move);

        const piece_type = board.getPieceTypeAt(move.from, us_idx);

        if (piece_type != .pawn) {
            buf[idx] = piece_type.toUpperChar();
            idx += 1;

            // Disambiguation: check if another piece of same type can move to same square
            const legal = legal_moves orelse movegen.generateLegalMoves(board);
            var need_file = false;
            var need_rank = false;
            for (legal.slice()) |other| {
                if (other.from == move.from) continue;
                if (other.to != move.to) continue;
                if (other.flags == .king_castle or other.flags == .queen_castle) continue;
                const other_pt = board.getPieceTypeAt(other.from, us_idx);
                if (other_pt != piece_type) continue;
                const other_sq: Square = @enumFromInt(other.from);
                if (other_sq.file() != from_sq.file()) {
                    need_file = true;
                } else if (other_sq.rank() != from_sq.rank()) {
                    need_rank = true;
                } else {
                    need_file = true;
                    need_rank = true;
                }
            }

            if (need_file) {
                buf[idx] = 'a' + @as(u8, from_sq.file());
                idx += 1;
            }
            if (need_rank) {
                buf[idx] = '1' + @as(u8, from_sq.rank());
                idx += 1;
            }
        } else if (move.flags.isCapture()) {
            buf[idx] = 'a' + @as(u8, from_sq.file());
            idx += 1;
        }

        if (move.flags.isCapture()) {
            buf[idx] = 'x';
            idx += 1;
        }

        const to_str = to_sq.toString();
        buf[idx] = to_str[0];
        idx += 1;
        buf[idx] = to_str[1];
        idx += 1;

        if (move.flags.isPromotion()) {
            buf[idx] = '=';
            idx += 1;
            buf[idx] = move.flags.promotionPieceType().?.toUpperChar();
            idx += 1;
        }
    }

    // Check/checkmate suffix
    const undo = board.makeMove(move);
    const in_check = board.isInCheck();
    if (in_check) {
        const legal_after = movegen.generateLegalMoves(board);
        if (legal_after.count == 0) {
            buf[idx] = '#';
        } else {
            buf[idx] = '+';
        }
        idx += 1;
    }
    board.unmakeMove(move, undo);

    return buf[0..idx];
}

/// Format a move in long algebraic notation
pub fn moveToLongAlgebraic(move: Move, buf: []u8) []const u8 {
    const from_sq: Square = @enumFromInt(move.from);
    const to_sq: Square = @enumFromInt(move.to);
    const f = from_sq.toString();
    const t = to_sq.toString();

    buf[0] = f[0];
    buf[1] = f[1];
    buf[2] = t[0];
    buf[3] = t[1];

    if (move.flags.isPromotion()) {
        buf[4] = move.flags.promotionPieceType().?.toChar();
        return buf[0..5];
    }

    return buf[0..4];
}

test "parse long algebraic" {
    magics.init();

    var board = Board.init();

    const m = parseMove("e2e4", &board);
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(u6, @intFromEnum(Square.e2)), m.?.from);
    try std.testing.expectEqual(@as(u6, @intFromEnum(Square.e4)), m.?.to);
    try std.testing.expectEqual(MoveFlags.double_pawn_push, m.?.flags);

    try std.testing.expect(parseMove("e2e5", &board) == null);
}

test "parse SAN" {
    magics.init();

    var board = Board.init();

    // e4 (pawn push)
    const m1 = parseMove("e4", &board);
    try std.testing.expect(m1 != null);
    try std.testing.expectEqual(@as(u6, @intFromEnum(Square.e4)), m1.?.to);

    // Nf3 (knight move)
    const m2 = parseMove("Nf3", &board);
    try std.testing.expect(m2 != null);
    try std.testing.expectEqual(@as(u6, @intFromEnum(Square.f3)), m2.?.to);

    // Bc4 should not work from starting position (bishop blocked)
    try std.testing.expect(parseMove("Bc4", &board) == null);
}

test "parse SAN with captures" {
    magics.init();

    // Position after 1.e4 e5 2.Bc4 Nc6 3.Qh5 Nf6
    var board = try Board.fromFen("r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4");
    const m = parseMove("Qxf7", &board);
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(u6, @intFromEnum(Square.f7)), m.?.to);
}

test "SAN formatting" {
    magics.init();

    var board = Board.init();
    var buf: [16]u8 = undefined;

    const legal = movegen.generateLegalMoves(&board);
    for (legal.slice()) |move| {
        if (move.from == @intFromEnum(Square.e2) and move.to == @intFromEnum(Square.e4)) {
            const san = moveToSAN(move, &board, &buf, legal);
            try std.testing.expectEqualStrings("e4", san);
            break;
        }
    }
}
