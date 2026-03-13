const std = @import("std");
const board_mod = @import("board.zig");
const movegen = @import("movegen.zig");
const magics = @import("magics.zig");
const Board = board_mod.Board;

pub fn perft(b: *Board, depth: u32) u64 {
    if (depth == 0) return 1;

    const moves = movegen.generateLegalMoves(b);

    if (depth == 1) return moves.count;

    var nodes: u64 = 0;
    for (moves.slice()) |move| {
        const undo = b.makeMove(move);
        nodes += perft(b, depth - 1);
        b.unmakeMove(move, undo);
    }
    return nodes;
}

pub fn divide(b: *Board, depth: u32) u64 {
    const moves = movegen.generateLegalMoves(b);
    var total: u64 = 0;

    for (moves.slice()) |move| {
        const undo = b.makeMove(move);
        const nodes = if (depth <= 1) @as(u64, 1) else perft(b, depth - 1);
        total += nodes;

        const la = move.toLongAlgebraic();
        const len: usize = if (move.flags.isPromotion()) 5 else 4;
        std.debug.print("{s}: {d}\n", .{ la[0..len], nodes });

        b.unmakeMove(move, undo);
    }

    std.debug.print("\nTotal: {d}\n", .{total});
    return total;
}

test "perft starting position" {
    magics.init();

    var b = Board.init();
    try std.testing.expectEqual(@as(u64, 20), perft(&b, 1));
    try std.testing.expectEqual(@as(u64, 400), perft(&b, 2));
    try std.testing.expectEqual(@as(u64, 8902), perft(&b, 3));
    // try std.testing.expectEqual(@as(u64, 197281), perft(&b, 4));
}

test "perft kiwipete" {
    magics.init();

    var b = try Board.fromFen("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
    try std.testing.expectEqual(@as(u64, 48), perft(&b, 1));
    try std.testing.expectEqual(@as(u64, 2039), perft(&b, 2));
    try std.testing.expectEqual(@as(u64, 97862), perft(&b, 3));
    // try std.testing.expectEqual(@as(u64, 4085603), perft(&b, 4));
}

test "perft position 3" {
    magics.init();

    var b = try Board.fromFen("8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1");
    try std.testing.expectEqual(@as(u64, 14), perft(&b, 1));
    try std.testing.expectEqual(@as(u64, 191), perft(&b, 2));
    try std.testing.expectEqual(@as(u64, 2812), perft(&b, 3));
    // try std.testing.expectEqual(@as(u64, 43238), perft(&b, 4));
}

test "perft position 4" {
    magics.init();

    var b = try Board.fromFen("r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1");
    try std.testing.expectEqual(@as(u64, 6), perft(&b, 1));
    try std.testing.expectEqual(@as(u64, 264), perft(&b, 2));
    try std.testing.expectEqual(@as(u64, 9467), perft(&b, 3));
    // try std.testing.expectEqual(@as(u64, 422333), perft(&b, 4));
}

test "perft position 5" {
    magics.init();

    var b = try Board.fromFen("rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8");
    try std.testing.expectEqual(@as(u64, 44), perft(&b, 1));
    try std.testing.expectEqual(@as(u64, 1486), perft(&b, 2));
    try std.testing.expectEqual(@as(u64, 62379), perft(&b, 3));
    // try std.testing.expectEqual(@as(u64, 2103487), perft(&b, 4));
}

test "perft position 6" {
    magics.init();

    var b = try Board.fromFen("r4rk1/1pp1qppp/p1np1n2/2b1p1B/2B1P1b/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10");
    try std.testing.expectEqual(@as(u64, 46), perft(&b, 1));
    try std.testing.expectEqual(@as(u64, 2079), perft(&b, 2));
    try std.testing.expectEqual(@as(u64, 89890), perft(&b, 3));
    // try std.testing.expectEqual(@as(u64, 3894594), perft(&b, 4));
}
