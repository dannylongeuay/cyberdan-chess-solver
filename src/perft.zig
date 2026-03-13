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
