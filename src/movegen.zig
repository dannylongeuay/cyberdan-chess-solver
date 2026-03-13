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

fn addPieceMoves(list: *MoveList, from: u6, moves_bb: Bitboard, their_occ: Bitboard) void {
    var captures = moves_bb & their_occ;
    var quiets = moves_bb & ~their_occ;
    while (captures != 0) {
        const to = bb.popLsb(&captures);
        list.add(.{ .from = from, .to = to, .flags = .capture });
    }
    while (quiets != 0) {
        const to = bb.popLsb(&quiets);
        list.add(.{ .from = from, .to = to, .flags = .quiet });
    }
}

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
            addPieceMoves(&list, from, atk.knight_attacks[from] & ~our_occ, their_occ);
        }
    }

    // Bishops
    {
        var bishops = b.pieces[us_idx][@intFromEnum(PieceType.bishop)];
        while (bishops != 0) {
            const from = bb.popLsb(&bishops);
            addPieceMoves(&list, from, atk.bishopAttacks(from, all_occ) & ~our_occ, their_occ);
        }
    }

    // Rooks
    {
        var rooks = b.pieces[us_idx][@intFromEnum(PieceType.rook)];
        while (rooks != 0) {
            const from = bb.popLsb(&rooks);
            addPieceMoves(&list, from, atk.rookAttacks(from, all_occ) & ~our_occ, their_occ);
        }
    }

    // Queens
    {
        var queens = b.pieces[us_idx][@intFromEnum(PieceType.queen)];
        while (queens != 0) {
            const from = bb.popLsb(&queens);
            addPieceMoves(&list, from, atk.queenAttacks(from, all_occ) & ~our_occ, their_occ);
        }
    }

    // King
    addPieceMoves(&list, b.kingSquare(us), atk.king_attacks[b.kingSquare(us)] & ~our_occ, their_occ);

    // Castling
    generateCastling(b, us, &list);

    return list;
}

fn generatePawnMoves(b: *const Board, us: Color, their_occ: Bitboard, list: *MoveList) void {
    if (us == .white) {
        generatePawnMovesComptime(b, .white, their_occ, list);
    } else {
        generatePawnMovesComptime(b, .black, their_occ, list);
    }
}

fn generatePawnMovesComptime(b: *const Board, comptime us: Color, their_occ: Bitboard, list: *MoveList) void {
    const pawns = b.pieces[@intFromEnum(us)][@intFromEnum(PieceType.pawn)];
    const empty = ~b.all_occupancy;

    const push = if (us == .white) bb.northOne else bb.southOne;
    const cap_west = if (us == .white) bb.northWestOne else bb.southWestOne;
    const cap_east = if (us == .white) bb.northEastOne else bb.southEastOne;
    const double_rank = if (us == .white) bb.rank_3 else bb.rank_6;
    const promo_rank = if (us == .white) bb.rank_8 else bb.rank_1;
    const single_offset: u6 = if (us == .white) @as(u6, 0) -% 8 else 8;
    const double_offset: u6 = if (us == .white) @as(u6, 0) -% 16 else 16;
    const cap_west_offset: u6 = if (us == .white) @as(u6, 0) -% 7 else 9;
    const cap_east_offset: u6 = if (us == .white) @as(u6, 0) -% 9 else 7;
    const ep_atk_color: usize = if (us == .white) 1 else 0;

    var single = push(pawns) & empty;
    var double = push(single & double_rank) & empty;
    var left = cap_west(pawns) & their_occ;
    var right = cap_east(pawns) & their_occ;

    // Split off promotions
    var promo_single = single & promo_rank;
    single &= ~promo_rank;
    var promo_left = left & promo_rank;
    left &= ~promo_rank;
    var promo_right = right & promo_rank;
    right &= ~promo_rank;

    while (single != 0) {
        const to = bb.popLsb(&single);
        list.add(.{ .from = to +% single_offset, .to = to, .flags = .quiet });
    }
    while (double != 0) {
        const to = bb.popLsb(&double);
        list.add(.{ .from = to +% double_offset, .to = to, .flags = .double_pawn_push });
    }
    while (left != 0) {
        const to = bb.popLsb(&left);
        list.add(.{ .from = to +% cap_west_offset, .to = to, .flags = .capture });
    }
    while (right != 0) {
        const to = bb.popLsb(&right);
        list.add(.{ .from = to +% cap_east_offset, .to = to, .flags = .capture });
    }

    addPromotions(list, &promo_single, false, single_offset);
    addPromotions(list, &promo_left, true, cap_west_offset);
    addPromotions(list, &promo_right, true, cap_east_offset);

    if (b.en_passant) |ep| {
        var ep_pawns = atk.pawn_attacks[ep_atk_color][ep] & pawns;
        while (ep_pawns != 0) {
            const from = bb.popLsb(&ep_pawns);
            list.add(.{ .from = from, .to = ep, .flags = .ep_capture });
        }
    }
}

fn addPromotions(list: *MoveList, targets: *Bitboard, comptime is_capture: bool, from_offset: u6) void {
    const promo_flags = if (is_capture)
        [4]MoveFlags{ .queen_promo_capture, .rook_promo_capture, .bishop_promo_capture, .knight_promo_capture }
    else
        [4]MoveFlags{ .queen_promotion, .rook_promotion, .bishop_promotion, .knight_promotion };

    while (targets.* != 0) {
        const to = bb.popLsb(targets);
        const from = to +% from_offset;
        inline for (promo_flags) |flags| {
            list.add(.{ .from = from, .to = to, .flags = flags });
        }
    }
}

const CastleInfo = struct {
    king_from: u6,
    king_to: u6,
    path_mask: Bitboard,
    check_sqs: [3]u6,
    flags: MoveFlags,
};

const castle_table = [4]CastleInfo{
    // White king side
    .{ .king_from = @intFromEnum(Square.e1), .king_to = @intFromEnum(Square.g1), .path_mask = Square.f1.toBitboard() | Square.g1.toBitboard(), .check_sqs = .{ @intFromEnum(Square.e1), @intFromEnum(Square.f1), @intFromEnum(Square.g1) }, .flags = .king_castle },
    // White queen side
    .{ .king_from = @intFromEnum(Square.e1), .king_to = @intFromEnum(Square.c1), .path_mask = Square.d1.toBitboard() | Square.c1.toBitboard() | Square.b1.toBitboard(), .check_sqs = .{ @intFromEnum(Square.e1), @intFromEnum(Square.d1), @intFromEnum(Square.c1) }, .flags = .queen_castle },
    // Black king side
    .{ .king_from = @intFromEnum(Square.e8), .king_to = @intFromEnum(Square.g8), .path_mask = Square.f8.toBitboard() | Square.g8.toBitboard(), .check_sqs = .{ @intFromEnum(Square.e8), @intFromEnum(Square.f8), @intFromEnum(Square.g8) }, .flags = .king_castle },
    // Black queen side
    .{ .king_from = @intFromEnum(Square.e8), .king_to = @intFromEnum(Square.c8), .path_mask = Square.d8.toBitboard() | Square.c8.toBitboard() | Square.b8.toBitboard(), .check_sqs = .{ @intFromEnum(Square.e8), @intFromEnum(Square.d8), @intFromEnum(Square.c8) }, .flags = .queen_castle },
};

fn generateCastling(b: *const Board, us: Color, list: *MoveList) void {
    const them = us.opponent();
    const rights = b.castling.toInt();
    const offset: usize = if (us == .white) 0 else 2;

    // Bits: 0=WK, 1=WQ, 2=BK, 3=BQ
    const right_bits = [2]u4{ 0b0001, 0b0010 };

    inline for (0..2) |i| {
        if (rights & right_bits[i] << @intCast(offset) != 0) {
            const info = castle_table[offset + i];
            if (b.all_occupancy & info.path_mask == 0) {
                if (!b.isSquareAttacked(info.check_sqs[0], them) and
                    !b.isSquareAttacked(info.check_sqs[1], them) and
                    !b.isSquareAttacked(info.check_sqs[2], them))
                {
                    list.add(.{ .from = info.king_from, .to = info.king_to, .flags = info.flags });
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
