const std = @import("std");

pub const types = @import("types.zig");
pub const square = @import("square.zig");
pub const bitboard = @import("bitboard.zig");
pub const attacks = @import("attacks.zig");
pub const magics = @import("magics.zig");
pub const moves_mod = @import("moves.zig");
pub const board_mod = @import("board.zig");
pub const movegen = @import("movegen.zig");
pub const perft_mod = @import("perft.zig");
pub const game_mod = @import("game.zig");
pub const display = @import("display.zig");
pub const notation = @import("notation.zig");
pub const random = @import("random.zig");
pub const server = @import("server.zig");

const Board = board_mod.Board;
const GameState = game_mod.GameState;
const GameResult = game_mod.GameResult;

const Mode = enum { hvh, hvc };
const Command = enum { play, perft, serve };

pub fn main() !void {
    var args = std.process.args();
    _ = args.next(); // skip program name

    var command: Command = .play;
    var mode: Mode = .hvh;
    var fen: ?[]const u8 = null;
    var perft_depth: u32 = 0;
    var do_divide = false;
    var port: u16 = 8080;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "play")) {
            command = .play;
        } else if (std.mem.eql(u8, arg, "perft")) {
            command = .perft;
            if (args.next()) |depth_str| {
                perft_depth = std.fmt.parseInt(u32, depth_str, 10) catch {
                    std.debug.print("Invalid depth: {s}\n", .{depth_str});
                    return;
                };
            } else {
                std.debug.print("Usage: cyberdan-chess-solver perft <depth>\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "serve")) {
            command = .serve;
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (args.next()) |port_str| {
                port = std.fmt.parseInt(u16, port_str, 10) catch {
                    std.debug.print("Invalid port: {s}\n", .{port_str});
                    return;
                };
            }
        } else if (std.mem.eql(u8, arg, "--mode")) {
            if (args.next()) |mode_str| {
                if (std.mem.eql(u8, mode_str, "hvh")) {
                    mode = .hvh;
                } else if (std.mem.eql(u8, mode_str, "hvc")) {
                    mode = .hvc;
                } else {
                    std.debug.print("Invalid mode: {s}. Use 'hvh' or 'hvc'\n", .{mode_str});
                    return;
                }
            }
        } else if (std.mem.eql(u8, arg, "--fen")) {
            fen = args.next();
        } else if (std.mem.eql(u8, arg, "--divide")) {
            do_divide = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        }
    }

    switch (command) {
        .perft => {
            var board = if (fen) |f|
                Board.fromFen(f) catch {
                    std.debug.print("Invalid FEN: {s}\n", .{f});
                    return;
                }
            else
                Board.init();

            if (do_divide) {
                _ = perft_mod.divide(&board, perft_depth);
            } else {
                var timer = std.time.Timer.start() catch {
                    const result = perft_mod.perft(&board, perft_depth);
                    std.debug.print("{d}\n", .{result});
                    return;
                };
                const result = perft_mod.perft(&board, perft_depth);
                const elapsed = timer.read();
                const ms = elapsed / std.time.ns_per_ms;
                std.debug.print("Nodes: {d}\n", .{result});
                std.debug.print("Time: {d}ms\n", .{ms});
                if (ms > 0) {
                    std.debug.print("NPS: {d}\n", .{result * 1000 / ms});
                }
            }
        },
        .play => {
            try runGame(fen, mode);
        },
        .serve => {
            server.serve(port) catch |err| {
                std.debug.print("Server error: {}\n", .{err});
                return;
            };
        },
    }
}

fn runGame(fen: ?[]const u8, mode: Mode) !void {
    var game = if (fen) |f|
        GameState.initFromFen(f) catch {
            std.debug.print("Invalid FEN: {s}\n", .{f});
            return;
        }
    else
        GameState.init();

    var prng = std.Random.DefaultPrng.init(@truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))));

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    const stdin_file = std.fs.File.stdin();
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = stdin_file.reader(&stdin_buf);
    const stdin = &stdin_reader.interface;

    try stdout.print("cyberdan-chess-solver\n", .{});
    try stdout.print("Mode: {s}\n", .{if (mode == .hvh) "Human vs Human" else "Human vs Computer"});
    try stdout.print("Type 'quit' to exit, 'fen' to show FEN, 'moves' to list legal moves, 'undo' to undo\n\n", .{});
    try stdout.flush();

    while (true) {
        // Display board
        try display.printBoard(&game.board, stdout);
        try stdout.print("\n", .{});
        try stdout.flush();

        // Check game result
        const result = game.gameResult();
        if (result != .ongoing) {
            try stdout.print("{s}\n", .{GameState.resultString(result)});
            try stdout.flush();
            return;
        }

        const is_computer_turn = mode == .hvc and game.board.side_to_move == .black;

        if (is_computer_turn) {
            // Computer's turn
            const move = random.randomMove(&game.board, &prng) orelse {
                try stdout.print("No legal moves!\n", .{});
                try stdout.flush();
                return;
            };

            var san_buf: [16]u8 = undefined;
            const san = notation.moveToSAN(move, &game.board, &san_buf, null);
            game.makeMove(move);
            try stdout.print("Computer plays: {s}\n\n", .{san});
            try stdout.flush();
        } else {
            // Human's turn
            const side_str = if (game.board.side_to_move == .white) "White" else "Black";
            try stdout.print("{s} to move: ", .{side_str});
            try stdout.flush();

            const line = stdin.takeDelimiter('\n') catch {
                return;
            } orelse return;

            // Strip carriage return if present
            const input = if (line.len > 0 and line[line.len - 1] == '\r')
                line[0 .. line.len - 1]
            else
                line;

            if (input.len == 0) continue;

            // Commands
            if (std.mem.eql(u8, input, "quit") or std.mem.eql(u8, input, "q")) {
                try stdout.print("Goodbye!\n", .{});
                try stdout.flush();
                return;
            }

            if (std.mem.eql(u8, input, "fen")) {
                var fen_buf: [100]u8 = undefined;
                const fen_str = game.board.toFen(&fen_buf);
                try stdout.print("FEN: {s}\n\n", .{fen_str});
                try stdout.flush();
                continue;
            }

            if (std.mem.eql(u8, input, "moves")) {
                const legal = movegen.generateLegalMoves(&game.board);
                try stdout.print("Legal moves ({d}):", .{legal.count});
                for (legal.slice()) |move| {
                    var san_buf: [16]u8 = undefined;
                    const san = notation.moveToSAN(move, &game.board, &san_buf, legal);
                    try stdout.print(" {s}", .{san});
                }
                try stdout.print("\n\n", .{});
                try stdout.flush();
                continue;
            }

            if (std.mem.eql(u8, input, "undo")) {
                if (game.history_len > 0) {
                    game.unmakeMove();
                    if (mode == .hvc and game.history_len > 0) {
                        game.unmakeMove(); // Also undo computer's move
                    }
                    try stdout.print("Move undone.\n\n", .{});
                } else {
                    try stdout.print("Nothing to undo.\n\n", .{});
                }
                try stdout.flush();
                continue;
            }

            // Parse move
            if (notation.parseMove(input, &game.board)) |move| {
                var san_buf: [16]u8 = undefined;
                const san = notation.moveToSAN(move, &game.board, &san_buf, null);
                game.makeMove(move);
                try stdout.print("{s}\n\n", .{san});
                try stdout.flush();
            } else {
                // Check if it's a promotion that needs piece specified
                if (input.len >= 4) {
                    const from_sq = square.Square.fromString(input[0..2]);
                    const to_sq = square.Square.fromString(input[2..4]);
                    if (from_sq != null and to_sq != null) {
                        const from_idx = @intFromEnum(from_sq.?);
                        const to_rank = to_sq.?.rank();
                        // Only suggest promotion if the piece on from-square is a pawn
                        const is_pawn = if (game.board.pieceAt(from_idx)) |piece|
                            piece.piece_type == .pawn
                        else
                            false;
                        if (is_pawn and (to_rank == 0 or to_rank == 7)) {
                            try stdout.print("Promotion move - please specify piece (e.g., {s}q for queen)\n\n", .{input});
                            try stdout.flush();
                            continue;
                        }
                    }
                }
                try stdout.print("Invalid move: {s}\n", .{input});
                try stdout.print("Use long algebraic (e2e4) or SAN (Nf3). Type 'moves' to see legal moves.\n\n", .{});
                try stdout.flush();
            }
        }
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage: cyberdan-chess-solver [command] [options]
        \\
        \\Commands:
        \\  play              Start a game (default)
        \\  perft <depth>     Run perft test
        \\  serve             Start HTTP API server
        \\
        \\Options for play:
        \\  --mode hvh        Human vs Human (default)
        \\  --mode hvc        Human vs Computer
        \\  --fen <fen>       Start from FEN position
        \\
        \\Options for perft:
        \\  --fen <fen>       Test position (default: starting position)
        \\  --divide          Show per-move breakdown
        \\
        \\Options for serve:
        \\  --port <port>     Port to listen on (default: 8080)
        \\
    , .{});
}

test {
    _ = types;
    _ = square;
    _ = bitboard;
    _ = attacks;
    _ = magics;
    _ = moves_mod;
    _ = board_mod;
    _ = movegen;
    _ = perft_mod;
    _ = game_mod;
    _ = display;
    _ = notation;
    _ = random;
    _ = server;
}
