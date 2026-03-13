const std = @import("std");
const board_mod = @import("board.zig");
const square_mod = @import("square.zig");
const Board = board_mod.Board;
const Square = square_mod.Square;

const separator = "  +---+---+---+---+---+---+---+---+\n";

pub fn printBoard(b: *const Board, writer: anytype) !void {
    var rank_i: i8 = 7;
    while (rank_i >= 0) : (rank_i -= 1) {
        try writer.writeAll(separator);
        try writer.print("{d} ", .{@as(u8, @intCast(rank_i)) + 1});
        for (0..8) |file_i| {
            const sq = Square.fromRankFile(@intCast(rank_i), @intCast(file_i));
            const ch: u8 = if (b.pieceAt(@intFromEnum(sq))) |piece| blk: {
                const c: u8 = switch (piece.piece_type) {
                    .pawn => 'p',
                    .knight => 'n',
                    .bishop => 'b',
                    .rook => 'r',
                    .queen => 'q',
                    .king => 'k',
                };
                break :blk if (piece.color == .white) c - 32 else c;
            } else ' ';
            try writer.print("| {c} ", .{ch});
        }
        try writer.writeAll("|\n");
    }
    try writer.writeAll(separator);
    try writer.writeAll("    a   b   c   d   e   f   g   h\n");
}
