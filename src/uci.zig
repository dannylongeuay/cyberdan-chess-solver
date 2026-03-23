const std = @import("std");
const board_mod = @import("board.zig");
const moves_mod = @import("moves.zig");
const movegen = @import("movegen.zig");
const notation = @import("notation.zig");
const search_mod = @import("search.zig");
const tt_mod = @import("tt.zig");
const eval_mod = @import("eval.zig");
const types = @import("types.zig");

const Board = board_mod.Board;
const Move = moves_mod.Move;
const TranspositionTable = tt_mod.TranspositionTable;

const UciState = struct {
    board: Board,
    tt: *TranspositionTable,
    stop_flag: std.atomic.Value(bool),
    search_thread: ?std.Thread,
    stdout_mutex: std.Thread.Mutex,
};

var global_state: UciState = undefined;

pub fn run() !void {
    var tt = TranspositionTable.init(std.heap.page_allocator, 64) catch {
        std.debug.print("Failed to allocate transposition table\n", .{});
        return;
    };
    defer tt.deinit();
    defer stopSearch(); // runs before tt.deinit() — defers execute LIFO

    global_state = .{
        .board = Board.init(),
        .tt = &tt,
        .stop_flag = std.atomic.Value(bool).init(false),
        .search_thread = null,
        .stdout_mutex = .{},
    };

    const stdin_file = std.fs.File.stdin();
    var stdin_buf: [8192]u8 = undefined;
    var stdin_reader = stdin_file.reader(&stdin_buf);
    const stdin = &stdin_reader.interface;

    while (true) {
        const line = stdin.takeDelimiter('\n') catch return orelse return;

        // Strip carriage return
        const input = if (line.len > 0 and line[line.len - 1] == '\r')
            line[0 .. line.len - 1]
        else
            line;

        if (input.len == 0) continue;

        var iter = std.mem.tokenizeScalar(u8, input, ' ');
        const cmd = iter.next() orelse continue;

        if (std.mem.eql(u8, cmd, "uci")) {
            sendLine("id name Cyberdan");
            sendLine("id author Daniel");
            sendLine("option name Hash type spin default 64 min 1 max 4096");
            sendLine("uciok");
        } else if (std.mem.eql(u8, cmd, "setoption")) {
            handleSetOption(&iter);
        } else if (std.mem.eql(u8, cmd, "isready")) {
            sendLine("readyok");
        } else if (std.mem.eql(u8, cmd, "ucinewgame")) {
            stopSearch();
            global_state.tt.clear();
            global_state.board = Board.init();
        } else if (std.mem.eql(u8, cmd, "position")) {
            stopSearch();
            handlePosition(&iter);
        } else if (std.mem.eql(u8, cmd, "go")) {
            handleGo(&iter);
        } else if (std.mem.eql(u8, cmd, "stop")) {
            stopSearch();
        } else if (std.mem.eql(u8, cmd, "quit")) {
            stopSearch();
            return;
        }
    }
}

fn handlePosition(iter: *std.mem.TokenIterator(u8, .scalar)) void {
    const pos_type = iter.next() orelse return;

    if (std.mem.eql(u8, pos_type, "startpos")) {
        global_state.board = Board.init();
    } else if (std.mem.eql(u8, pos_type, "fen")) {
        // Collect FEN tokens (up to 6 fields) until "moves" or end
        var fen_buf: [256]u8 = undefined;
        var fen_len: usize = 0;
        var field_count: usize = 0;

        while (iter.next()) |token| {
            if (std.mem.eql(u8, token, "moves")) {
                // Apply moves below
                applyMoves(iter);
                return;
            }
            if (fen_len > 0) {
                fen_buf[fen_len] = ' ';
                fen_len += 1;
            }
            if (fen_len + token.len > fen_buf.len) return;
            @memcpy(fen_buf[fen_len .. fen_len + token.len], token);
            fen_len += token.len;
            field_count += 1;
            if (field_count >= 6) break;
        }

        global_state.board = Board.fromFen(fen_buf[0..fen_len]) catch return;
    } else {
        return;
    }

    // Check for "moves" token
    while (iter.next()) |token| {
        if (std.mem.eql(u8, token, "moves")) {
            applyMoves(iter);
            return;
        }
    }
}

fn applyMoves(iter: *std.mem.TokenIterator(u8, .scalar)) void {
    while (iter.next()) |move_str| {
        const move = notation.parseMove(move_str, &global_state.board) orelse {
            var msg_buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "info string invalid move: {s}", .{move_str}) catch return;
            sendLine(msg);
            return;
        };
        _ = global_state.board.makeMove(move);
    }
}

fn handleGo(iter: *std.mem.TokenIterator(u8, .scalar)) void {
    var max_depth: u32 = 100;
    var movetime: ?u64 = null;
    var wtime: ?u64 = null;
    var btime: ?u64 = null;
    var winc: u64 = 0;
    var binc: u64 = 0;
    var movestogo: u32 = 0;
    var infinite = false;

    while (iter.next()) |token| {
        if (std.mem.eql(u8, token, "depth")) {
            if (iter.next()) |v| max_depth = std.fmt.parseInt(u32, v, 10) catch 100;
        } else if (std.mem.eql(u8, token, "movetime")) {
            if (iter.next()) |v| movetime = std.fmt.parseInt(u64, v, 10) catch null;
        } else if (std.mem.eql(u8, token, "wtime")) {
            if (iter.next()) |v| wtime = clampTime(v);
        } else if (std.mem.eql(u8, token, "btime")) {
            if (iter.next()) |v| btime = clampTime(v);
        } else if (std.mem.eql(u8, token, "winc")) {
            if (iter.next()) |v| winc = std.fmt.parseInt(u64, v, 10) catch 0;
        } else if (std.mem.eql(u8, token, "binc")) {
            if (iter.next()) |v| binc = std.fmt.parseInt(u64, v, 10) catch 0;
        } else if (std.mem.eql(u8, token, "movestogo")) {
            if (iter.next()) |v| movestogo = std.fmt.parseInt(u32, v, 10) catch 0;
        } else if (std.mem.eql(u8, token, "infinite")) {
            infinite = true;
        }
    }

    // Compute timeout
    var timeout_ns: ?u64 = null;

    if (movetime) |mt| {
        timeout_ns = mt * std.time.ns_per_ms;
    } else if (!infinite) {
        const is_white = global_state.board.side_to_move == .white;
        const our_time = if (is_white) wtime else btime;
        const our_inc = if (is_white) winc else binc;

        if (our_time) |ot| {
            var alloc: u64 = 0;
            if (movestogo > 0) {
                alloc = ot / movestogo + our_inc;
            } else {
                alloc = ot / 30 + our_inc * 3 / 4;
            }
            // Safety margin: reserve 10% of remaining time, minimum 10ms
            const margin = @max(ot / 10, 10);
            if (ot > margin) {
                alloc = @min(alloc, ot - margin);
            } else {
                alloc = 1; // critically low — spend minimal time
            }
            alloc = @max(1, alloc);
            timeout_ns = alloc * std.time.ns_per_ms;
        }
    }

    // Stop any running search
    stopSearch();

    global_state.stop_flag.store(false, .monotonic);

    global_state.search_thread = std.Thread.spawn(.{}, searchThreadFn, .{
        max_depth,
        timeout_ns,
    }) catch return;
}

fn searchThreadFn(max_depth: u32, timeout_ns: ?u64) void {
    const result = search_mod.searchIterative(
        &global_state.board,
        .{
            .max_depth = max_depth,
            .timeout_ns = timeout_ns,
            .stop_flag = &global_state.stop_flag,
            .on_iteration = &onIteration,
        },
        global_state.tt,
    );

    // Send bestmove
    var buf: [16]u8 = undefined;
    if (result.best_move) |move| {
        const move_str = notation.moveToLongAlgebraic(move, &buf);
        var out_buf: [64]u8 = undefined;
        const out = std.fmt.bufPrint(&out_buf, "bestmove {s}", .{move_str}) catch return;
        sendLine(out);
    } else {
        sendLine("bestmove 0000");
    }
}

fn onIteration(info: search_mod.IterationInfo) void {
    var buf: [512]u8 = undefined;
    var pos: usize = 0;

    // Format score
    var score_buf: [32]u8 = undefined;
    var score_str: []const u8 = "";

    const abs_score = if (info.score < 0) -info.score else info.score;
    if (abs_score >= eval_mod.CHECKMATE_SCORE - 256) {
        const ply_distance: i32 = eval_mod.CHECKMATE_SCORE - abs_score;
        const mate_moves = @divTrunc(ply_distance + 1, 2);
        const signed_mate: i32 = if (info.score > 0) mate_moves else -mate_moves;
        score_str = std.fmt.bufPrint(&score_buf, "score mate {d}", .{signed_mate}) catch return;
    } else {
        score_str = std.fmt.bufPrint(&score_buf, "score cp {d}", .{info.score}) catch return;
    }

    const nps = if (info.time_ms > 0) info.nodes * 1000 / info.time_ms else info.nodes;

    // Build info string
    const header = std.fmt.bufPrint(buf[pos..], "info depth {d} seldepth {d} {s} nodes {d} nps {d} time {d}", .{
        info.depth,
        info.seldepth,
        score_str,
        info.nodes,
        nps,
        info.time_ms,
    }) catch return;
    pos += header.len;

    // Append PV moves
    if (info.pv_len > 0) {
        if (pos + 4 > buf.len) return;
        @memcpy(buf[pos .. pos + 4], " pv ");
        pos += 4;

        for (info.pv[0..info.pv_len]) |move| {
            var move_buf: [6]u8 = undefined;
            const move_str = notation.moveToLongAlgebraic(move, &move_buf);
            if (pos + move_str.len + 1 > buf.len) break;
            if (pos > 0 and buf[pos - 1] != ' ') {
                buf[pos] = ' ';
                pos += 1;
            }
            @memcpy(buf[pos .. pos + move_str.len], move_str);
            pos += move_str.len;
        }
    }

    sendLine(buf[0..pos]);
}

fn handleSetOption(iter: *std.mem.TokenIterator(u8, .scalar)) void {
    // Expected format: name <name> value <value>
    const name_token = iter.next() orelse return;
    if (!std.mem.eql(u8, name_token, "name")) return;
    const opt_name = iter.next() orelse return;
    const value_token = iter.next() orelse return;
    if (!std.mem.eql(u8, value_token, "value")) return;
    const opt_value = iter.next() orelse return;

    if (std.ascii.eqlIgnoreCase(opt_name, "hash")) {
        const size_mb = std.fmt.parseInt(u32, opt_value, 10) catch return;
        const clamped = std.math.clamp(size_mb, 1, 4096);
        stopSearch();
        const new_tt = TranspositionTable.init(std.heap.page_allocator, clamped) catch return;
        global_state.tt.deinit();
        global_state.tt.* = new_tt;
    }
}

/// Parse a time value (possibly negative from GUIs), clamp to minimum 100ms.
fn clampTime(str: []const u8) ?u64 {
    const val = std.fmt.parseInt(i64, str, 10) catch return null;
    if (val < 100) return 100;
    return @intCast(val);
}

fn stopSearch() void {
    global_state.stop_flag.store(true, .monotonic);
    if (global_state.search_thread) |thread| {
        thread.join();
        global_state.search_thread = null;
    }
}

fn sendLine(msg: []const u8) void {
    global_state.stdout_mutex.lock();
    defer global_state.stdout_mutex.unlock();

    const stdout = std.fs.File.stdout();
    stdout.writeAll(msg) catch return;
    stdout.writeAll("\n") catch return;
}

test "UCI position parsing" {
    // Just ensure the module compiles and basic types are correct
    var tt = try TranspositionTable.init(std.testing.allocator, 1);
    defer tt.deinit();

    global_state = .{
        .board = Board.init(),
        .tt = &tt,
        .stop_flag = std.atomic.Value(bool).init(false),
        .search_thread = null,
        .stdout_mutex = .{},
    };

    // Test startpos
    var iter1 = std.mem.tokenizeScalar(u8, "startpos moves e2e4 e7e5", ' ');
    handlePosition(&iter1);
    // After e2e4 e7e5, side to move should be white
    try std.testing.expectEqual(types.Color.white, global_state.board.side_to_move);

    // Test FEN position
    var iter2 = std.mem.tokenizeScalar(u8, "fen rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1", ' ');
    handlePosition(&iter2);
    try std.testing.expectEqual(types.Color.black, global_state.board.side_to_move);
}
