const std = @import("std");
const types = @import("types.zig");
const square_mod = @import("square.zig");
const bb = @import("bitboard.zig");
const atk = @import("attacks.zig");
const magics = @import("magics.zig");
const moves_mod = @import("moves.zig");
const board_mod = @import("board.zig");

const Color = types.Color;
const PieceType = types.PieceType;
const Square = square_mod.Square;
const Bitboard = bb.Bitboard;
const Move = moves_mod.Move;
const MoveFlags = moves_mod.MoveFlags;
const MoveList = moves_mod.MoveList;
const Board = board_mod.Board;

pub fn generatePseudoLegalMoves(b: *const Board) MoveList {
    var list = MoveList.init();
    const us = b.side_to_move;
    const us_idx = @intFromEnum(us);
    const them_idx = @intFromEnum(us.opponent());
    const our_occ = b.occupancy[us_idx];
    const their_occ = b.occupancy[them_idx];
    const all_occ = b.all_occupancy;

    // Pawns
    generatePawnMoves(b, us, their_occ, &list);

    // Knights
    {
        var knights = b.pieces[us_idx][@intFromEnum(PieceType.knight)];
        while (knights != 0) {
            const from = bb.popLsb(&knights);
            var moves_bb = atk.knight_attacks[from] & ~our_occ;
            while (moves_bb != 0) {
                const to = bb.popLsb(&moves_bb);
                const flags: MoveFlags = if (their_occ & (@as(u64, 1) << to) != 0) .capture else .quiet;
                list.add(.{ .from = from, .to = to, .flags = flags });
            }
        }
    }

    // Bishops
    {
        var bishops = b.pieces[us_idx][@intFromEnum(PieceType.bishop)];
        while (bishops != 0) {
            const from = bb.popLsb(&bishops);
            var moves_bb = atk.bishopAttacks(from, all_occ) & ~our_occ;
            while (moves_bb != 0) {
                const to = bb.popLsb(&moves_bb);
                const flags: MoveFlags = if (their_occ & (@as(u64, 1) << to) != 0) .capture else .quiet;
                list.add(.{ .from = from, .to = to, .flags = flags });
            }
        }
    }

    // Rooks
    {
        var rooks = b.pieces[us_idx][@intFromEnum(PieceType.rook)];
        while (rooks != 0) {
            const from = bb.popLsb(&rooks);
            var moves_bb = atk.rookAttacks(from, all_occ) & ~our_occ;
            while (moves_bb != 0) {
                const to = bb.popLsb(&moves_bb);
                const flags: MoveFlags = if (their_occ & (@as(u64, 1) << to) != 0) .capture else .quiet;
                list.add(.{ .from = from, .to = to, .flags = flags });
            }
        }
    }

    // Queens
    {
        var queens = b.pieces[us_idx][@intFromEnum(PieceType.queen)];
        while (queens != 0) {
            const from = bb.popLsb(&queens);
            var moves_bb = atk.queenAttacks(from, all_occ) & ~our_occ;
            while (moves_bb != 0) {
                const to = bb.popLsb(&moves_bb);
                const flags: MoveFlags = if (their_occ & (@as(u64, 1) << to) != 0) .capture else .quiet;
                list.add(.{ .from = from, .to = to, .flags = flags });
            }
        }
    }

    // King
    {
        const from = b.kingSquare(us);
        var moves_bb = atk.king_attacks[from] & ~our_occ;
        while (moves_bb != 0) {
            const to = bb.popLsb(&moves_bb);
            const flags: MoveFlags = if (their_occ & (@as(u64, 1) << to) != 0) .capture else .quiet;
            list.add(.{ .from = from, .to = to, .flags = flags });
        }
    }

    // Castling
    generateCastling(b, us, &list);

    return list;
}

fn generatePawnMoves(b: *const Board, us: Color, their_occ: Bitboard, list: *MoveList) void {
    const us_idx = @intFromEnum(us);
    const pawns = b.pieces[us_idx][@intFromEnum(PieceType.pawn)];
    const empty = ~b.all_occupancy;

    if (us == .white) {
        // Single push
        var single = bb.northOne(pawns) & empty;
        // Double push
        var double = bb.northOne(single & bb.rank_3) & empty;
        // Captures
        var cap_left = bb.northWestOne(pawns) & their_occ;
        var cap_right = bb.northEastOne(pawns) & their_occ;

        // Promotions (rank 8)
        var promo_single = single & bb.rank_8;
        single &= ~bb.rank_8;
        var promo_cap_left = cap_left & bb.rank_8;
        cap_left &= ~bb.rank_8;
        var promo_cap_right = cap_right & bb.rank_8;
        cap_right &= ~bb.rank_8;

        while (single != 0) {
            const to = bb.popLsb(&single);
            list.add(.{ .from = to - 8, .to = to, .flags = .quiet });
        }
        while (double != 0) {
            const to = bb.popLsb(&double);
            list.add(.{ .from = to - 16, .to = to, .flags = .double_pawn_push });
        }
        while (cap_left != 0) {
            const to = bb.popLsb(&cap_left);
            list.add(.{ .from = to - 7, .to = to, .flags = .capture });
        }
        while (cap_right != 0) {
            const to = bb.popLsb(&cap_right);
            list.add(.{ .from = to - 9, .to = to, .flags = .capture });
        }

        // Promotions (white: from = to - delta, use wrapping offsets)
        addPromotions(list, &promo_single, false, @as(u6, 0) -% 8);
        addPromotions(list, &promo_cap_left, true, @as(u6, 0) -% 7);
        addPromotions(list, &promo_cap_right, true, @as(u6, 0) -% 9);

        // En passant
        if (b.en_passant) |ep| {
            var ep_pawns = atk.pawn_attacks[1][ep] & pawns; // black pawn attack pattern from ep square
            while (ep_pawns != 0) {
                const from = bb.popLsb(&ep_pawns);
                list.add(.{ .from = from, .to = ep, .flags = .ep_capture });
            }
        }
    } else {
        // Black
        var single = bb.southOne(pawns) & empty;
        var double = bb.southOne(single & bb.rank_6) & empty;
        var cap_left = bb.southWestOne(pawns) & their_occ;
        var cap_right = bb.southEastOne(pawns) & their_occ;

        var promo_single = single & bb.rank_1;
        single &= ~bb.rank_1;
        var promo_cap_left = cap_left & bb.rank_1;
        cap_left &= ~bb.rank_1;
        var promo_cap_right = cap_right & bb.rank_1;
        cap_right &= ~bb.rank_1;

        while (single != 0) {
            const to = bb.popLsb(&single);
            list.add(.{ .from = to + 8, .to = to, .flags = .quiet });
        }
        while (double != 0) {
            const to = bb.popLsb(&double);
            list.add(.{ .from = to + 16, .to = to, .flags = .double_pawn_push });
        }
        while (cap_left != 0) {
            const to = bb.popLsb(&cap_left);
            list.add(.{ .from = to + 9, .to = to, .flags = .capture });
        }
        while (cap_right != 0) {
            const to = bb.popLsb(&cap_right);
            list.add(.{ .from = to + 7, .to = to, .flags = .capture });
        }

        // Black: from = to + delta (to is rank 1, always fits in u6)
        addPromotions(list, &promo_single, false, 8);
        addPromotions(list, &promo_cap_left, true, 9);
        addPromotions(list, &promo_cap_right, true, 7);

        if (b.en_passant) |ep| {
            var ep_pawns = atk.pawn_attacks[0][ep] & pawns; // white pawn attack pattern from ep square
            while (ep_pawns != 0) {
                const from = bb.popLsb(&ep_pawns);
                list.add(.{ .from = from, .to = ep, .flags = .ep_capture });
            }
        }
    }
}

fn addPromotions(list: *MoveList, targets: *Bitboard, is_capture: bool, from_offset: u6) void {
    while (targets.* != 0) {
        const to = bb.popLsb(targets);
        const from = to +% from_offset;
        if (is_capture) {
            list.add(.{ .from = from, .to = to, .flags = .queen_promo_capture });
            list.add(.{ .from = from, .to = to, .flags = .rook_promo_capture });
            list.add(.{ .from = from, .to = to, .flags = .bishop_promo_capture });
            list.add(.{ .from = from, .to = to, .flags = .knight_promo_capture });
        } else {
            list.add(.{ .from = from, .to = to, .flags = .queen_promotion });
            list.add(.{ .from = from, .to = to, .flags = .rook_promotion });
            list.add(.{ .from = from, .to = to, .flags = .bishop_promotion });
            list.add(.{ .from = from, .to = to, .flags = .knight_promotion });
        }
    }
}

fn generateCastling(b: *const Board, us: Color, list: *MoveList) void {
    const them = us.opponent();

    if (us == .white) {
        // King side: e1-g1
        if (b.castling.white_king) {
            const path = Square.f1.toBitboard() | Square.g1.toBitboard();
            if (b.all_occupancy & path == 0) {
                // King must not be in check, and must not pass through check
                if (!b.isSquareAttacked(@intFromEnum(Square.e1), them) and
                    !b.isSquareAttacked(@intFromEnum(Square.f1), them) and
                    !b.isSquareAttacked(@intFromEnum(Square.g1), them))
                {
                    list.add(.{ .from = @intFromEnum(Square.e1), .to = @intFromEnum(Square.g1), .flags = .king_castle });
                }
            }
        }
        // Queen side: e1-c1
        if (b.castling.white_queen) {
            const path = Square.d1.toBitboard() | Square.c1.toBitboard() | Square.b1.toBitboard();
            if (b.all_occupancy & path == 0) {
                if (!b.isSquareAttacked(@intFromEnum(Square.e1), them) and
                    !b.isSquareAttacked(@intFromEnum(Square.d1), them) and
                    !b.isSquareAttacked(@intFromEnum(Square.c1), them))
                {
                    list.add(.{ .from = @intFromEnum(Square.e1), .to = @intFromEnum(Square.c1), .flags = .queen_castle });
                }
            }
        }
    } else {
        if (b.castling.black_king) {
            const path = Square.f8.toBitboard() | Square.g8.toBitboard();
            if (b.all_occupancy & path == 0) {
                if (!b.isSquareAttacked(@intFromEnum(Square.e8), them) and
                    !b.isSquareAttacked(@intFromEnum(Square.f8), them) and
                    !b.isSquareAttacked(@intFromEnum(Square.g8), them))
                {
                    list.add(.{ .from = @intFromEnum(Square.e8), .to = @intFromEnum(Square.g8), .flags = .king_castle });
                }
            }
        }
        if (b.castling.black_queen) {
            const path = Square.d8.toBitboard() | Square.c8.toBitboard() | Square.b8.toBitboard();
            if (b.all_occupancy & path == 0) {
                if (!b.isSquareAttacked(@intFromEnum(Square.e8), them) and
                    !b.isSquareAttacked(@intFromEnum(Square.d8), them) and
                    !b.isSquareAttacked(@intFromEnum(Square.c8), them))
                {
                    list.add(.{ .from = @intFromEnum(Square.e8), .to = @intFromEnum(Square.c8), .flags = .queen_castle });
                }
            }
        }
    }
}

pub fn generateLegalMoves(b: *Board) MoveList {
    const pseudo = generatePseudoLegalMoves(b);
    var legal = MoveList.init();

    for (pseudo.slice()) |move| {
        const undo = b.makeMove(move);
        // Check if own king is attacked (the side that just moved)
        const king_sq = b.kingSquare(b.side_to_move.opponent());
        if (!b.isSquareAttacked(king_sq, b.side_to_move)) {
            legal.add(move);
        }
        b.unmakeMove(move, undo);
    }

    return legal;
}

test "starting position has 20 legal moves" {
    magics.init();

    var board = Board.init();
    const legal = generateLegalMoves(&board);
    try std.testing.expectEqual(@as(usize, 20), legal.count);
}

test "kiwipete has 48 legal moves" {
    magics.init();

    var board = try Board.fromFen("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
    const legal = generateLegalMoves(&board);
    try std.testing.expectEqual(@as(usize, 48), legal.count);
}
