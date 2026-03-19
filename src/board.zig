const std = @import("std");
const types = @import("types.zig");
const square_mod = @import("square.zig");
const bb = @import("bitboard.zig");
const attacks = @import("attacks.zig");
const moves_mod = @import("moves.zig");

const Color = types.Color;
const PieceType = types.PieceType;
const Piece = types.Piece;
const CastlingRights = types.CastlingRights;
const Square = square_mod.Square;
const Bitboard = bb.Bitboard;
const Move = moves_mod.Move;
const MoveFlags = moves_mod.MoveFlags;

// Zobrist keys
pub const Zobrist = struct {
    // piece_keys[color][piece_type][square]
    piece_keys: [2][6][64]u64,
    castling_keys: [16]u64,
    en_passant_keys: [8]u64,
    side_key: u64,

    pub const instance: Zobrist = blk: {
        @setEvalBranchQuota(100000);
        var z: Zobrist = undefined;
        var state: u64 = 1070372;

        for (0..2) |c| {
            for (0..6) |p| {
                for (0..64) |s| {
                    state = xorshift64(state);
                    z.piece_keys[c][p][s] = state;
                }
            }
        }

        for (0..16) |i| {
            state = xorshift64(state);
            z.castling_keys[i] = state;
        }

        for (0..8) |i| {
            state = xorshift64(state);
            z.en_passant_keys[i] = state;
        }

        state = xorshift64(state);
        z.side_key = state;

        break :blk z;
    };

    fn xorshift64(s: u64) u64 {
        var x = s;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        return x;
    }
};

pub const UndoInfo = struct {
    captured_piece: ?PieceType,
    castling: CastlingRights,
    en_passant: ?u6,
    halfmove_clock: u16,
    hash: u64,
};

pub const Board = struct {
    // pieces[color][piece_type]
    pieces: [2][6]Bitboard,
    // Redundant occupancy
    occupancy: [2]Bitboard, // white, black
    all_occupancy: Bitboard,

    side_to_move: Color,
    castling: CastlingRights,
    en_passant: ?u6, // en passant target square
    halfmove_clock: u16,
    fullmove_number: u16,
    hash: u64,

    pub const starting_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

    pub fn init() Board {
        return fromFen(starting_fen) catch unreachable;
    }

    pub fn pieceAt(self: *const Board, sq: u6) ?Piece {
        const bit = @as(u64, 1) << sq;
        if (self.all_occupancy & bit == 0) return null;

        const color: Color = if (self.occupancy[0] & bit != 0) .white else .black;
        const c = @intFromEnum(color);

        inline for (0..6) |p| {
            if (self.pieces[c][p] & bit != 0) {
                return .{ .color = color, .piece_type = @enumFromInt(p) };
            }
        }

        return null;
    }

    pub fn putPiece(self: *Board, sq: u6, piece: Piece) void {
        const bit = @as(u64, 1) << sq;
        const c = @intFromEnum(piece.color);
        const p = @intFromEnum(piece.piece_type);

        self.pieces[c][p] |= bit;
        self.occupancy[c] |= bit;
        self.all_occupancy |= bit;
        self.hash ^= Zobrist.instance.piece_keys[c][p][sq];
    }

    pub fn removePiece(self: *Board, sq: u6, piece: Piece) void {
        const bit = @as(u64, 1) << sq;
        const c = @intFromEnum(piece.color);
        const p = @intFromEnum(piece.piece_type);

        self.pieces[c][p] &= ~bit;
        self.occupancy[c] &= ~bit;
        self.all_occupancy &= ~bit;
        self.hash ^= Zobrist.instance.piece_keys[c][p][sq];
    }

    fn movePiece(self: *Board, from: u6, to: u6, piece: Piece) void {
        const from_bit = @as(u64, 1) << from;
        const to_bit = @as(u64, 1) << to;
        const from_to = from_bit | to_bit;
        const c = @intFromEnum(piece.color);
        const p = @intFromEnum(piece.piece_type);

        self.pieces[c][p] ^= from_to;
        self.occupancy[c] ^= from_to;
        self.all_occupancy ^= from_to;
        self.hash ^= Zobrist.instance.piece_keys[c][p][from] ^ Zobrist.instance.piece_keys[c][p][to];
    }

    // Hash-free variants for unmakeMove (hash is restored from undo info)
    fn putPieceNoHash(self: *Board, sq: u6, piece: Piece) void {
        const bit = @as(u64, 1) << sq;
        const c = @intFromEnum(piece.color);
        const p = @intFromEnum(piece.piece_type);
        self.pieces[c][p] |= bit;
        self.occupancy[c] |= bit;
        self.all_occupancy |= bit;
    }

    fn removePieceNoHash(self: *Board, sq: u6, piece: Piece) void {
        const bit = @as(u64, 1) << sq;
        const c = @intFromEnum(piece.color);
        const p = @intFromEnum(piece.piece_type);
        self.pieces[c][p] &= ~bit;
        self.occupancy[c] &= ~bit;
        self.all_occupancy &= ~bit;
    }

    fn movePieceNoHash(self: *Board, from: u6, to: u6, piece: Piece) void {
        const from_bit = @as(u64, 1) << from;
        const to_bit = @as(u64, 1) << to;
        const from_to = from_bit | to_bit;
        const c = @intFromEnum(piece.color);
        const p = @intFromEnum(piece.piece_type);
        self.pieces[c][p] ^= from_to;
        self.occupancy[c] ^= from_to;
        self.all_occupancy ^= from_to;
    }

    // Castling rights update mask: indexed by from/to square
    const castling_update = blk: {
        var table: [64]u4 = [_]u4{0b1111} ** 64;
        // Moving from or capturing on these squares clears specific rights
        table[@intFromEnum(Square.a1)] &= ~@as(u4, 0b0010); // white queen side
        table[@intFromEnum(Square.e1)] &= ~@as(u4, 0b0011); // white both
        table[@intFromEnum(Square.h1)] &= ~@as(u4, 0b0001); // white king side
        table[@intFromEnum(Square.a8)] &= ~@as(u4, 0b1000); // black queen side
        table[@intFromEnum(Square.e8)] &= ~@as(u4, 0b1100); // black both
        table[@intFromEnum(Square.h8)] &= ~@as(u4, 0b0100); // black king side
        break :blk table;
    };

    pub fn makeMove(self: *Board, move: Move) UndoInfo {
        const from = move.from;
        const to = move.to;
        const flags = move.flags;
        const us = self.side_to_move;
        const them = us.opponent();
        const us_idx = @intFromEnum(us);

        // Save undo info
        var undo = UndoInfo{
            .captured_piece = null,
            .castling = self.castling,
            .en_passant = self.en_passant,
            .halfmove_clock = self.halfmove_clock,
            .hash = self.hash,
        };

        // Remove en passant from hash
        if (self.en_passant) |ep| {
            self.hash ^= Zobrist.instance.en_passant_keys[ep & 7];
        }

        self.halfmove_clock += 1;
        self.en_passant = null;

        const moving_piece_type = self.getPieceTypeAt(from, us_idx);

        switch (flags) {
            .quiet => {
                self.movePiece(from, to, .{ .color = us, .piece_type = moving_piece_type });
                if (moving_piece_type == .pawn) self.halfmove_clock = 0;
            },
            .double_pawn_push => {
                self.movePiece(from, to, .{ .color = us, .piece_type = .pawn });
                self.halfmove_clock = 0;
                // Only set en passant if an enemy pawn can actually capture
                const ep_sq: u6 = if (us == .white) from + 8 else from - 8;
                const them_idx = @intFromEnum(them);
                const enemy_pawns = self.pieces[them_idx][@intFromEnum(PieceType.pawn)];
                if (attacks.pawn_attacks[@intFromEnum(us)][ep_sq] & enemy_pawns != 0) {
                    self.en_passant = ep_sq;
                    self.hash ^= Zobrist.instance.en_passant_keys[from & 7];
                }
            },
            .king_castle => {
                self.movePiece(from, to, .{ .color = us, .piece_type = .king });
                // Move rook
                const rook_from: u6 = if (us == .white) @intFromEnum(Square.h1) else @intFromEnum(Square.h8);
                const rook_to: u6 = if (us == .white) @intFromEnum(Square.f1) else @intFromEnum(Square.f8);
                self.movePiece(rook_from, rook_to, .{ .color = us, .piece_type = .rook });
            },
            .queen_castle => {
                self.movePiece(from, to, .{ .color = us, .piece_type = .king });
                const rook_from: u6 = if (us == .white) @intFromEnum(Square.a1) else @intFromEnum(Square.a8);
                const rook_to: u6 = if (us == .white) @intFromEnum(Square.d1) else @intFromEnum(Square.d8);
                self.movePiece(rook_from, rook_to, .{ .color = us, .piece_type = .rook });
            },
            .capture => {
                const captured = self.getPieceTypeAt(to, @intFromEnum(them));
                undo.captured_piece = captured;
                self.removePiece(to, .{ .color = them, .piece_type = captured });
                self.movePiece(from, to, .{ .color = us, .piece_type = moving_piece_type });
                self.halfmove_clock = 0;
            },
            .ep_capture => {
                const cap_sq: u6 = if (us == .white) to - 8 else to + 8;
                undo.captured_piece = .pawn;
                self.removePiece(cap_sq, .{ .color = them, .piece_type = .pawn });
                self.movePiece(from, to, .{ .color = us, .piece_type = .pawn });
                self.halfmove_clock = 0;
            },
            .knight_promotion, .bishop_promotion, .rook_promotion, .queen_promotion,
            .knight_promo_capture, .bishop_promo_capture, .rook_promo_capture, .queen_promo_capture,
            => {
                if (flags.isCapture()) {
                    const captured = self.getPieceTypeAt(to, @intFromEnum(them));
                    undo.captured_piece = captured;
                    self.removePiece(to, .{ .color = them, .piece_type = captured });
                }
                self.removePiece(from, .{ .color = us, .piece_type = .pawn });
                self.putPiece(to, .{ .color = us, .piece_type = flags.promotionPieceType().? });
                self.halfmove_clock = 0;
            },
        }

        // Update castling rights
        self.hash ^= Zobrist.instance.castling_keys[self.castling.toInt()];
        const new_castling: u4 = self.castling.toInt() & castling_update[from] & castling_update[to];
        self.castling = @bitCast(new_castling);
        self.hash ^= Zobrist.instance.castling_keys[new_castling];

        // Switch side
        self.side_to_move = them;
        self.hash ^= Zobrist.instance.side_key;
        if (us == .black) self.fullmove_number += 1;

        return undo;
    }

    pub fn unmakeMove(self: *Board, move: Move, undo: UndoInfo) void {
        const to = move.to;
        const from = move.from;
        const flags = move.flags;

        // Switch side back
        self.side_to_move = self.side_to_move.opponent();
        const us = self.side_to_move;
        const them = us.opponent();

        if (us == .black) self.fullmove_number -= 1;

        switch (flags) {
            .quiet => {
                const pt = self.getPieceTypeAt(to, @intFromEnum(us));
                self.movePieceNoHash(to, from, .{ .color = us, .piece_type = pt });
            },
            .double_pawn_push => {
                self.movePieceNoHash(to, from, .{ .color = us, .piece_type = .pawn });
            },
            .king_castle => {
                self.movePieceNoHash(to, from, .{ .color = us, .piece_type = .king });
                const rook_from: u6 = if (us == .white) @intFromEnum(Square.h1) else @intFromEnum(Square.h8);
                const rook_to: u6 = if (us == .white) @intFromEnum(Square.f1) else @intFromEnum(Square.f8);
                self.movePieceNoHash(rook_to, rook_from, .{ .color = us, .piece_type = .rook });
            },
            .queen_castle => {
                self.movePieceNoHash(to, from, .{ .color = us, .piece_type = .king });
                const rook_from: u6 = if (us == .white) @intFromEnum(Square.a1) else @intFromEnum(Square.a8);
                const rook_to: u6 = if (us == .white) @intFromEnum(Square.d1) else @intFromEnum(Square.d8);
                self.movePieceNoHash(rook_to, rook_from, .{ .color = us, .piece_type = .rook });
            },
            .capture => {
                const pt = self.getPieceTypeAt(to, @intFromEnum(us));
                self.movePieceNoHash(to, from, .{ .color = us, .piece_type = pt });
                self.putPieceNoHash(to, .{ .color = them, .piece_type = undo.captured_piece.? });
            },
            .ep_capture => {
                self.movePieceNoHash(to, from, .{ .color = us, .piece_type = .pawn });
                const cap_sq: u6 = if (us == .white) to - 8 else to + 8;
                self.putPieceNoHash(cap_sq, .{ .color = them, .piece_type = .pawn });
            },
            .knight_promotion, .bishop_promotion, .rook_promotion, .queen_promotion => {
                const promo_type = flags.promotionPieceType().?;
                self.removePieceNoHash(to, .{ .color = us, .piece_type = promo_type });
                self.putPieceNoHash(from, .{ .color = us, .piece_type = .pawn });
            },
            .knight_promo_capture, .bishop_promo_capture, .rook_promo_capture, .queen_promo_capture => {
                const promo_type = flags.promotionPieceType().?;
                self.removePieceNoHash(to, .{ .color = us, .piece_type = promo_type });
                self.putPieceNoHash(from, .{ .color = us, .piece_type = .pawn });
                self.putPieceNoHash(to, .{ .color = them, .piece_type = undo.captured_piece.? });
            },
        }

        self.castling = undo.castling;
        self.en_passant = undo.en_passant;
        self.halfmove_clock = undo.halfmove_clock;
        self.hash = undo.hash;
    }

    pub const NullMoveUndo = struct {
        en_passant: ?u6,
        hash: u64,
    };

    pub fn makeNullMove(self: *Board) NullMoveUndo {
        const undo = NullMoveUndo{
            .en_passant = self.en_passant,
            .hash = self.hash,
        };

        // Clear en passant from hash
        if (self.en_passant) |ep| {
            self.hash ^= Zobrist.instance.en_passant_keys[ep & 7];
            self.en_passant = null;
        }

        // Toggle side to move
        self.side_to_move = self.side_to_move.opponent();
        self.hash ^= Zobrist.instance.side_key;

        return undo;
    }

    pub fn unmakeNullMove(self: *Board, undo: NullMoveUndo) void {
        self.side_to_move = self.side_to_move.opponent();
        self.en_passant = undo.en_passant;
        self.hash = undo.hash;
    }

    pub fn getPieceTypeAt(self: *const Board, sq: u6, color_idx: usize) PieceType {
        const bit = @as(u64, 1) << sq;
        inline for (0..6) |p| {
            if (self.pieces[color_idx][p] & bit != 0) return @enumFromInt(p);
        }
        unreachable;
    }

    pub fn isSquareAttacked(self: *const Board, sq: u6, by_color: Color) bool {
        return attacks.isSquareAttacked(sq, by_color, self.pieces, self.all_occupancy);
    }

    pub fn kingSquare(self: *const Board, color: Color) u6 {
        return bb.lsb(self.pieces[@intFromEnum(color)][@intFromEnum(PieceType.king)]);
    }

    pub fn isInCheck(self: *const Board) bool {
        return self.isSquareAttacked(self.kingSquare(self.side_to_move), self.side_to_move.opponent());
    }

    pub fn computeHash(self: *const Board) u64 {
        var h: u64 = 0;
        for (0..2) |c| {
            for (0..6) |p| {
                var pcs = self.pieces[c][p];
                while (pcs != 0) {
                    const sq = bb.popLsb(&pcs);
                    h ^= Zobrist.instance.piece_keys[c][p][sq];
                }
            }
        }
        h ^= Zobrist.instance.castling_keys[self.castling.toInt()];
        if (self.en_passant) |ep| {
            h ^= Zobrist.instance.en_passant_keys[ep & 7];
        }
        if (self.side_to_move == .black) h ^= Zobrist.instance.side_key;
        return h;
    }

    pub fn fromFen(fen: []const u8) !Board {
        var board: Board = .{
            .pieces = [_][6]Bitboard{[_]Bitboard{0} ** 6} ** 2,
            .occupancy = [_]Bitboard{0} ** 2,
            .all_occupancy = 0,
            .side_to_move = .white,
            .castling = CastlingRights.none,
            .en_passant = null,
            .halfmove_clock = 0,
            .fullmove_number = 1,
            .hash = 0,
        };

        var idx: usize = 0;

        // Parse piece placement
        var rank_i: i8 = 7;
        var file_i: i8 = 0;
        while (idx < fen.len and fen[idx] != ' ') : (idx += 1) {
            const ch = fen[idx];
            if (ch == '/') {
                rank_i -= 1;
                if (rank_i < 0) return error.InvalidFen;
                file_i = 0;
            } else if (ch >= '1' and ch <= '8') {
                file_i += @intCast(ch - '0');
                if (file_i > 8) return error.InvalidFen;
            } else {
                const color: Color = if (ch >= 'A' and ch <= 'Z') .white else .black;
                const lower = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
                const pt: PieceType = PieceType.fromChar(lower) orelse return error.InvalidFen;
                const sq = Square.fromRankFile(@intCast(rank_i), @intCast(file_i));
                board.putPiece(@intFromEnum(sq), .{ .color = color, .piece_type = pt });
                file_i += 1;
            }
        }

        if (idx >= fen.len) return board;
        idx += 1; // skip space

        // Side to move
        if (idx < fen.len) {
            board.side_to_move = if (fen[idx] == 'w') .white else .black;
            idx += 1;
        }

        if (idx < fen.len) idx += 1; // skip space

        // Castling
        while (idx < fen.len and fen[idx] != ' ') : (idx += 1) {
            switch (fen[idx]) {
                'K' => board.castling.white_king = true,
                'Q' => board.castling.white_queen = true,
                'k' => board.castling.black_king = true,
                'q' => board.castling.black_queen = true,
                '-' => {},
                else => {},
            }
        }

        if (idx < fen.len) idx += 1; // skip space

        // En passant
        if (idx < fen.len and fen[idx] != '-') {
            if (idx + 1 < fen.len) {
                board.en_passant = @intFromEnum(Square.fromString(fen[idx .. idx + 2]) orelse return error.InvalidFen);
                idx += 2;
            }
        } else if (idx < fen.len) {
            idx += 1; // skip '-'
        }

        if (idx < fen.len) idx += 1; // skip space

        // Halfmove clock
        if (idx < fen.len) {
            var num: u16 = 0;
            while (idx < fen.len and fen[idx] != ' ') : (idx += 1) {
                if (fen[idx] < '0' or fen[idx] > '9') return error.InvalidFen;
                num = num * 10 + @as(u16, fen[idx] - '0');
            }
            board.halfmove_clock = num;
        }

        if (idx < fen.len) idx += 1; // skip space

        // Fullmove number
        if (idx < fen.len) {
            var num: u16 = 0;
            while (idx < fen.len and fen[idx] != ' ') : (idx += 1) {
                if (fen[idx] < '0' or fen[idx] > '9') return error.InvalidFen;
                num = num * 10 + @as(u16, fen[idx] - '0');
            }
            board.fullmove_number = num;
        }

        // putPiece calls already XORed piece keys into the hash;
        // just add castling, EP, and side-to-move keys
        if (board.side_to_move == .black) board.hash ^= Zobrist.instance.side_key;
        board.hash ^= Zobrist.instance.castling_keys[board.castling.toInt()];
        if (board.en_passant) |ep| board.hash ^= Zobrist.instance.en_passant_keys[ep & 7];

        return board;
    }

    pub fn toFen(self: *const Board, buf: []u8) []const u8 {
        var idx: usize = 0;

        // Piece placement
        var rank_i: i8 = 7;
        while (rank_i >= 0) : (rank_i -= 1) {
            var empty: u8 = 0;
            for (0..8) |file_i| {
                const sq = Square.fromRankFile(@intCast(rank_i), @intCast(file_i));
                if (self.pieceAt(@intFromEnum(sq))) |piece| {
                    if (empty > 0) {
                        buf[idx] = '0' + empty;
                        idx += 1;
                        empty = 0;
                    }
                    const ch = piece.piece_type.toChar();
                    buf[idx] = if (piece.color == .white) ch - 32 else ch;
                    idx += 1;
                } else {
                    empty += 1;
                }
            }
            if (empty > 0) {
                buf[idx] = '0' + empty;
                idx += 1;
            }
            if (rank_i > 0) {
                buf[idx] = '/';
                idx += 1;
            }
        }

        buf[idx] = ' ';
        idx += 1;
        buf[idx] = if (self.side_to_move == .white) 'w' else 'b';
        idx += 1;
        buf[idx] = ' ';
        idx += 1;

        // Castling
        if (self.castling.toInt() == 0) {
            buf[idx] = '-';
            idx += 1;
        } else {
            if (self.castling.white_king) {
                buf[idx] = 'K';
                idx += 1;
            }
            if (self.castling.white_queen) {
                buf[idx] = 'Q';
                idx += 1;
            }
            if (self.castling.black_king) {
                buf[idx] = 'k';
                idx += 1;
            }
            if (self.castling.black_queen) {
                buf[idx] = 'q';
                idx += 1;
            }
        }

        buf[idx] = ' ';
        idx += 1;

        // En passant
        if (self.en_passant) |ep| {
            const sq: Square = @enumFromInt(ep);
            const str = sq.toString();
            buf[idx] = str[0];
            idx += 1;
            buf[idx] = str[1];
            idx += 1;
        } else {
            buf[idx] = '-';
            idx += 1;
        }

        buf[idx] = ' ';
        idx += 1;

        // Halfmove clock
        idx += writeU16(buf[idx..], self.halfmove_clock);
        buf[idx] = ' ';
        idx += 1;

        // Fullmove number
        idx += writeU16(buf[idx..], self.fullmove_number);

        return buf[0..idx];
    }

    fn writeU16(buf: []u8, val: u16) usize {
        if (val == 0) {
            buf[0] = '0';
            return 1;
        }
        var v = val;
        var digits: [5]u8 = undefined;
        var len: usize = 0;
        while (v > 0) {
            digits[len] = @intCast(v % 10 + '0');
            v /= 10;
            len += 1;
        }
        for (0..len) |i| {
            buf[i] = digits[len - 1 - i];
        }
        return len;
    }
};

test "FEN roundtrip" {
    const fens = [_][]const u8{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
    };

    var buf: [100]u8 = undefined;
    for (fens) |fen| {
        const board = try Board.fromFen(fen);
        const result = board.toFen(&buf);
        try std.testing.expectEqualStrings(fen, result);
    }
}

test "makeMove/unmakeMove restores board" {
    var board = Board.init();
    const original_hash = board.hash;

    // Make e2e4
    const e2e4 = Move{ .from = @intFromEnum(Square.e2), .to = @intFromEnum(Square.e4), .flags = .double_pawn_push };
    const undo = board.makeMove(e2e4);

    try std.testing.expect(board.hash != original_hash);
    // From starting position, no enemy pawn can capture en passant, so ep square is not set
    try std.testing.expect(board.en_passant == null);

    board.unmakeMove(e2e4, undo);

    try std.testing.expectEqual(original_hash, board.hash);

    // Verify board is exactly the starting position
    var buf: [100]u8 = undefined;
    try std.testing.expectEqualStrings(Board.starting_fen, board.toFen(&buf));
}

test "double pawn push sets en passant when enemy pawn can capture" {
    // Black pawn on d4, white plays e2-e4 → ep square should be e3
    var board = try Board.fromFen("rnbqkbnr/ppp1pppp/8/8/3p4/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1");
    const e2e4 = Move{ .from = @intFromEnum(Square.e2), .to = @intFromEnum(Square.e4), .flags = .double_pawn_push };
    _ = board.makeMove(e2e4);

    try std.testing.expectEqual(@intFromEnum(Square.e3), board.en_passant.?);

    // FEN should show e3 as ep square
    var buf: [100]u8 = undefined;
    const fen = board.toFen(&buf);
    try std.testing.expect(std.mem.indexOf(u8, fen, " e3 ") != null);
}

test "double pawn push sets en passant with enemy pawn on other side" {
    // Black pawn on f4, white plays e2-e4 → ep square should be e3
    var board = try Board.fromFen("rnbqkbnr/ppppp1pp/8/8/5p2/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1");
    const e2e4 = Move{ .from = @intFromEnum(Square.e2), .to = @intFromEnum(Square.e4), .flags = .double_pawn_push };
    _ = board.makeMove(e2e4);

    try std.testing.expectEqual(@intFromEnum(Square.e3), board.en_passant.?);
}

test "double pawn push no en passant without adjacent enemy pawn" {
    // No black pawns near e-file on 4th rank, white plays e2-e4 → no ep
    var board = try Board.fromFen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1");
    const e2e4 = Move{ .from = @intFromEnum(Square.e2), .to = @intFromEnum(Square.e4), .flags = .double_pawn_push };
    _ = board.makeMove(e2e4);

    try std.testing.expect(board.en_passant == null);

    var buf: [100]u8 = undefined;
    const fen = board.toFen(&buf);
    try std.testing.expect(std.mem.indexOf(u8, fen, " - ") != null);
}

test "black double pawn push sets en passant when white pawn can capture" {
    // White pawn on e5, black plays d7-d5 → ep square should be d6
    var board = try Board.fromFen("rnbqkbnr/pppppppp/8/4P3/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1");
    const d7d5 = Move{ .from = @intFromEnum(Square.d7), .to = @intFromEnum(Square.d5), .flags = .double_pawn_push };
    _ = board.makeMove(d7d5);

    try std.testing.expectEqual(@intFromEnum(Square.d6), board.en_passant.?);
}

test "black double pawn push no en passant without adjacent white pawn" {
    // No white pawns near d-file on 5th rank, black plays d7-d5 → no ep
    var board = try Board.fromFen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1");
    const d7d5 = Move{ .from = @intFromEnum(Square.d7), .to = @intFromEnum(Square.d5), .flags = .double_pawn_push };
    _ = board.makeMove(d7d5);

    try std.testing.expect(board.en_passant == null);
}

test "en passant unmake restores null ep square" {
    // Black pawn on d4, white plays e2-e4 (sets ep), then unmake should clear it
    var board = try Board.fromFen("rnbqkbnr/ppp1pppp/8/8/3p4/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1");
    const original_hash = board.hash;
    const e2e4 = Move{ .from = @intFromEnum(Square.e2), .to = @intFromEnum(Square.e4), .flags = .double_pawn_push };
    const undo = board.makeMove(e2e4);

    try std.testing.expect(board.en_passant != null);

    board.unmakeMove(e2e4, undo);
    try std.testing.expect(board.en_passant == null);
    try std.testing.expectEqual(original_hash, board.hash);
}

test "makeNullMove/unmakeNullMove restores board" {
    var board = Board.init();
    const original_hash = board.hash;
    const original_side = board.side_to_move;

    const undo = board.makeNullMove();

    // Side should have toggled
    try std.testing.expect(board.side_to_move != original_side);
    // Hash should have changed
    try std.testing.expect(board.hash != original_hash);

    board.unmakeNullMove(undo);

    // Everything restored
    try std.testing.expectEqual(original_hash, board.hash);
    try std.testing.expectEqual(original_side, board.side_to_move);
}
