const std = @import("std");
const types = @import("types.zig");
const board_mod = @import("board.zig");
const notation = @import("notation.zig");

const Board = board_mod.Board;
const Color = types.Color;

const FenEntry = struct {
    fen: []const u8,
    moves: std.ArrayList([]const u8),
};

pub fn parseOpenings(allocator: std.mem.Allocator, file_path: []const u8, color: Color) !void {
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("Failed to open file '{s}': {}\n", .{ file_path, err });
        return err;
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);

    var entries: std.ArrayList(FenEntry) = .empty;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &[_]u8{ ' ', '\t', '\r' });
        if (line.len < 2 or line[0] != '1' or line[1] != '.') continue;
        processLine(allocator, line, color, &entries) catch |err| {
            std.debug.print("Skipping line: {}\n", .{err});
        };
    }

    // Print output in book.zig format
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    for (entries.items) |entry| {
        try stdout.print("    .{{ .fen = \"{s}\", .moves = &.{{ ", .{entry.fen});
        for (entry.moves.items, 0..) |uci, i| {
            if (i > 0) try stdout.print(", ", .{});
            try stdout.print("\"{s}\"", .{uci});
        }
        try stdout.print(" }} }},\n", .{});
    }
    try stdout.flush();
}

fn processLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    color: Color,
    entries: *std.ArrayList(FenEntry),
) !void {
    var board = Board.init();
    var half_move: usize = 0;
    const target_half: usize = if (color == .white) 0 else 1;

    var tokens = std.mem.tokenizeAny(u8, line, &[_]u8{ ' ', '\t' });
    while (tokens.next()) |token| {
        const san = stripMoveNumber(token) orelse continue;
        if (san.len == 0) continue;

        const move = notation.parseMove(san, &board) orelse {
            std.debug.print("  Could not parse: '{s}' on line '{s}'\n", .{ san, line });
            return error.InvalidMove;
        };

        if (half_move % 2 == target_half) {
            var fen_buf: [100]u8 = undefined;
            const fen_str = board.toFen(&fen_buf);
            const fen = try allocator.dupe(u8, fen_str);

            var uci_buf: [6]u8 = undefined;
            const uci_str = notation.moveToLongAlgebraic(move, &uci_buf);
            const uci = try allocator.dupe(u8, uci_str);

            try addToEntries(allocator, entries, fen, uci);
        }

        _ = board.makeMove(move);
        half_move += 1;
    }
}

fn stripMoveNumber(token: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < token.len and token[i] >= '0' and token[i] <= '9') : (i += 1) {}

    if (i > 0 and i < token.len and token[i] == '.') {
        // Skip past dots (handles "1..." for black move numbers)
        var j: usize = i + 1;
        while (j < token.len and token[j] == '.') : (j += 1) {}
        const rest = token[j..];
        if (rest.len == 0) return null;
        return rest;
    }

    // No number prefix — return token as-is for the parser to handle
    return token;
}

fn addToEntries(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(FenEntry),
    fen: []const u8,
    uci: []const u8,
) !void {
    for (entries.items) |*entry| {
        if (std.mem.eql(u8, entry.fen, fen)) {
            // Deduplicate moves
            for (entry.moves.items) |existing| {
                if (std.mem.eql(u8, existing, uci)) return;
            }
            try entry.moves.append(allocator, uci);
            return;
        }
    }

    var new_entry = FenEntry{
        .fen = fen,
        .moves = .empty,
    };
    try new_entry.moves.append(allocator, uci);
    try entries.append(allocator, new_entry);
}
