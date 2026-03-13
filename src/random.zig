const std = @import("std");
const board_mod = @import("board.zig");
const movegen = @import("movegen.zig");
const moves_mod = @import("moves.zig");
const Board = board_mod.Board;
const Move = moves_mod.Move;

pub fn randomMove(board: *Board, prng: *std.Random.DefaultPrng) ?Move {
    const legal = movegen.generateLegalMoves(board);
    if (legal.count == 0) return null;

    const random = prng.random();
    const idx = random.uintLessThan(usize, legal.count);
    return legal.moves[idx];
}
