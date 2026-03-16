const std = @import("std");
const http = std.http;
const net = std.net;

const board_mod = @import("board.zig");
const movegen = @import("movegen.zig");
const moves_mod = @import("moves.zig");
const notation = @import("notation.zig");
const game_mod = @import("game.zig");
const square_mod = @import("square.zig");
const types = @import("types.zig");
const bb = @import("bitboard.zig");
const search_mod = @import("search.zig");
const tt_mod = @import("tt.zig");
const book = @import("book.zig");

const Board = board_mod.Board;
const Move = moves_mod.Move;
const MoveFlags = moves_mod.MoveFlags;
const MoveList = moves_mod.MoveList;
const Square = square_mod.Square;
const GameState = game_mod.GameState;
const GameResult = game_mod.GameResult;

const Allocator = std.mem.Allocator;
const Server = http.Server;
const JsonBuf = std.ArrayList(u8);

fn getCorsOrigin() []const u8 {
    const val = std.posix.getenv("CORS_PERMISSIVE") orelse return "https://chess.cyberdan.dev";
    if (std.mem.eql(u8, val, "1")) return "*";
    return "https://chess.cyberdan.dev";
}

pub fn serve(port: u16) !void {
    const address = net.Address.parseIp4("0.0.0.0", port) catch unreachable;
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    // Allocate TT once, shared across all requests (thread-safe by design —
    // worst case is a stale entry that fails the key check on probe).
    var tt = try tt_mod.TranspositionTable.init(std.heap.page_allocator, 16);
    defer tt.deinit();

    std.debug.print("Chess server listening on http://0.0.0.0:{d}\n", .{port});

    while (true) {
        const conn = try server.accept();
        const thread = try std.Thread.spawn(.{}, handleConnection, .{ conn, &tt });
        thread.detach();
    }
}

fn probeBookMove(board: *Board) ?Move {
    const hit = book.probe(board.hash) orelse return null;
    const candidate = hit.pickRandom();
    const legal = movegen.generateLegalMoves(board);
    for (legal.slice()) |m| {
        if (m.from == candidate.from and m.to == candidate.to and m.flags == candidate.flags) {
            return candidate;
        }
    }
    return null;
}

fn handleConnection(conn: net.Server.Connection, tt: *tt_mod.TranspositionTable) void {
    defer conn.stream.close();

    var reader_buf: [8192]u8 = undefined;
    var writer_buf: [8192]u8 = undefined;
    var conn_reader = conn.stream.reader(&reader_buf);
    var conn_writer = conn.stream.writer(&writer_buf);

    var http_server = Server.init(conn_reader.interface(), &conn_writer.interface);

    while (true) {
        var request = http_server.receiveHead() catch |err| {
            if (err != error.HttpConnectionClosing) {
                std.debug.print("Connection error: {}\n", .{err});
            }
            return;
        };
        handleRequest(&request, tt) catch |err| {
            std.debug.print("Request handler error: {}\n", .{err});
            return;
        };
        if (!request.head.keep_alive) return;
    }
}

fn handleRequest(request: *Server.Request, tt: *tt_mod.TranspositionTable) !void {
    const method = request.head.method;
    const target = request.head.target;

    if (method == .OPTIONS) {
        try request.respond("", .{
            .status = .no_content,
            .extra_headers = &.{
                .{ .name = "Access-Control-Allow-Origin", .value = getCorsOrigin() },
                .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, OPTIONS" },
                .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type" },
            },
        });
        return;
    }

    if (std.mem.eql(u8, target, "/health")) {
        if (method != .GET) {
            try sendError(request, .method_not_allowed, "method_not_allowed", "Only GET is allowed", .{});
            return;
        }
        try sendJson(request, .ok, "{\"status\":\"ok\"}", .{});
    } else if (std.mem.eql(u8, target, "/validmoves")) {
        if (method != .POST) {
            try sendError(request, .method_not_allowed, "method_not_allowed", "Only POST is allowed", .{});
            return;
        }
        try handleValidMoves(request);
    } else if (std.mem.eql(u8, target, "/submitmove")) {
        if (method != .POST) {
            try sendError(request, .method_not_allowed, "method_not_allowed", "Only POST is allowed", .{});
            return;
        }
        try handleSubmitMove(request);
    } else if (std.mem.eql(u8, target, "/bestmove")) {
        if (method != .POST) {
            try sendError(request, .method_not_allowed, "method_not_allowed", "Only POST is allowed", .{});
            return;
        }
        try handleBestMove(request, tt);
    } else if (std.mem.eql(u8, target, "/submitbestmove")) {
        if (method != .POST) {
            try sendError(request, .method_not_allowed, "method_not_allowed", "Only POST is allowed", .{});
            return;
        }
        try handleSubmitBestMove(request, tt);
    } else {
        try sendError(request, .not_found, "not_found", "Endpoint not found", .{});
    }
}

fn handleValidMoves(request: *Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Read body (invalidates head strings, but we already routed)
    const body = readBody(request, alloc) catch {
        try sendError(request, .bad_request, "invalid_request", "Failed to read request body", .{});
        return;
    };

    // Parse JSON
    const FenRequest = struct { fen: []const u8 };
    const parsed = std.json.parseFromSliceLeaky(FenRequest, alloc, body, .{}) catch {
        try sendError(request, .bad_request, "invalid_json", "Failed to parse request body", .{ .keep_alive = true });
        return;
    };

    // Parse FEN
    var board = Board.fromFen(parsed.fen) catch {
        try sendError(request, .bad_request, "invalid_fen", "The provided FEN string is invalid", .{ .keep_alive = true });
        return;
    };

    // Generate legal moves
    const legal = movegen.generateLegalMoves(&board);

    // Determine game status
    const status = computeGameStatus(&board, legal.count);
    const side = if (board.side_to_move == .white) "white" else "black";

    // Build response JSON
    var json: JsonBuf = .empty;
    try json.appendSlice(alloc, "{\"fen\":\"");
    try appendJsonEscaped(&json, alloc, parsed.fen);
    try json.appendSlice(alloc, "\",\"side_to_move\":\"");
    try json.appendSlice(alloc, side);
    try json.appendSlice(alloc, "\",\"status\":\"");
    try json.appendSlice(alloc, status);
    try json.appendSlice(alloc, "\",\"move_count\":");
    var count_buf: [16]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{legal.count}) catch unreachable;
    try json.appendSlice(alloc, count_str);
    try json.appendSlice(alloc, ",\"moves\":[");

    for (legal.slice(), 0..) |move, i| {
        if (i > 0) try json.append(alloc, ',');
        try appendMoveObject(&json, alloc, move, &board, legal);
    }

    try json.appendSlice(alloc, "]}");

    try sendJson(request, .ok, json.items, .{ .keep_alive = true });
}

fn handleSubmitMove(request: *Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Read body
    const body = readBody(request, alloc) catch {
        try sendError(request, .bad_request, "invalid_request", "Failed to read request body", .{});
        return;
    };

    // Parse JSON
    const MoveRequest = struct { fen: []const u8, move: []const u8 };
    const parsed = std.json.parseFromSliceLeaky(MoveRequest, alloc, body, .{}) catch {
        try sendError(request, .bad_request, "invalid_json", "Failed to parse request body", .{ .keep_alive = true });
        return;
    };

    // Parse FEN
    var board = Board.fromFen(parsed.fen) catch {
        try sendError(request, .bad_request, "invalid_fen", "The provided FEN string is invalid", .{ .keep_alive = true });
        return;
    };

    // Parse and validate move
    const move = notation.parseMove(parsed.move, &board) orelse {
        var msg: JsonBuf = .empty;
        try msg.appendSlice(alloc, "{\"error\":\"invalid_move\",\"message\":\"Move '");
        try appendJsonEscaped(&msg, alloc, parsed.move);
        try msg.appendSlice(alloc, "' is not legal in this position\"}");
        try sendJson(request, .bad_request, msg.items, .{ .keep_alive = true });
        return;
    };

    // Build move fields before making the move (SAN needs pre-move board)
    var json: JsonBuf = .empty;
    try json.appendSlice(alloc, "{");
    try appendMoveFields(&json, alloc, move, &board);

    // Make the move
    _ = board.makeMove(move);

    // Append post-move state (FEN, status, legal moves)
    try appendPostMoveFields(&json, alloc, &board);

    try json.appendSlice(alloc, "}");

    try sendJson(request, .ok, json.items, .{ .keep_alive = true });
}

fn handleBestMove(request: *Server.Request, tt: *tt_mod.TranspositionTable) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Read body
    const body = readBody(request, alloc) catch {
        try sendError(request, .bad_request, "invalid_request", "Failed to read request body", .{});
        return;
    };

    // Parse JSON
    const BestMoveRequest = struct { fen: []const u8, depth: ?u32 = null, timeout_ms: ?u64 = null };
    const parsed = std.json.parseFromSliceLeaky(BestMoveRequest, alloc, body, .{}) catch {
        try sendError(request, .bad_request, "invalid_json", "Failed to parse request body", .{ .keep_alive = true });
        return;
    };

    // Build search options:
    //   timeout_ms provided → use it (with max_depth from depth or 100)
    //   depth provided (no timeout) → depth-only, backward compatible
    //   neither → default 5s timeout, max_depth 100
    const options: search_mod.SearchOptions = if (parsed.timeout_ms) |t|
        .{ .max_depth = @min(parsed.depth orelse 100, 100), .timeout_ns = t * std.time.ns_per_ms }
    else if (parsed.depth) |d|
        .{ .max_depth = @min(d, 20) }
    else
        .{ .timeout_ns = 5000 * std.time.ns_per_ms };

    // Parse FEN
    var board = Board.fromFen(parsed.fen) catch {
        try sendError(request, .bad_request, "invalid_fen", "The provided FEN string is invalid", .{ .keep_alive = true });
        return;
    };

    // Check opening book first
    if (probeBookMove(&board)) |candidate| {
        var json: JsonBuf = .empty;
        try json.appendSlice(alloc, "{\"fen\":\"");
        try appendJsonEscaped(&json, alloc, parsed.fen);
        try json.appendSlice(alloc, "\",\"depth\":0,");
        try appendMoveFields(&json, alloc, candidate, &board);
        try json.appendSlice(alloc, ",\"score\":0,\"nodes\":0,\"source\":\"book\"}");
        try sendJson(request, .ok, json.items, .{ .keep_alive = true });
        return;
    }

    // Run search (uses shared TT allocated once at server startup)
    const result = search_mod.searchIterative(&board, options, tt);

    // Build response
    var json: JsonBuf = .empty;
    try json.appendSlice(alloc, "{\"fen\":\"");
    try appendJsonEscaped(&json, alloc, parsed.fen);
    try json.appendSlice(alloc, "\",\"depth\":");
    var depth_buf: [16]u8 = undefined;
    try json.appendSlice(alloc, std.fmt.bufPrint(&depth_buf, "{d}", .{result.depth}) catch unreachable);

    if (result.best_move) |move| {
        try json.append(alloc, ',');
        try appendMoveFields(&json, alloc, move, &board);
    } else {
        try json.appendSlice(alloc, ",\"uci\":null,\"san\":null,\"from\":null,\"to\":null");
    }

    try json.appendSlice(alloc, ",\"score\":");
    var score_buf: [16]u8 = undefined;
    try json.appendSlice(alloc, std.fmt.bufPrint(&score_buf, "{d}", .{result.score}) catch unreachable);

    try json.appendSlice(alloc, ",\"nodes\":");
    var nodes_buf: [24]u8 = undefined;
    try json.appendSlice(alloc, std.fmt.bufPrint(&nodes_buf, "{d}", .{result.nodes}) catch unreachable);

    try json.appendSlice(alloc, ",\"source\":\"search\"}");

    try sendJson(request, .ok, json.items, .{ .keep_alive = true });
}

fn handleSubmitBestMove(request: *Server.Request, tt: *tt_mod.TranspositionTable) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Read body
    const body = readBody(request, alloc) catch {
        try sendError(request, .bad_request, "invalid_request", "Failed to read request body", .{});
        return;
    };

    // Parse JSON
    const BestMoveRequest = struct { fen: []const u8, depth: ?u32 = null, timeout_ms: ?u64 = null };
    const parsed = std.json.parseFromSliceLeaky(BestMoveRequest, alloc, body, .{}) catch {
        try sendError(request, .bad_request, "invalid_json", "Failed to parse request body", .{ .keep_alive = true });
        return;
    };

    // Parse FEN
    var board = Board.fromFen(parsed.fen) catch {
        try sendError(request, .bad_request, "invalid_fen", "The provided FEN string is invalid", .{ .keep_alive = true });
        return;
    };

    // Check opening book first
    if (probeBookMove(&board)) |candidate| {
        var json: JsonBuf = .empty;
        try json.appendSlice(alloc, "{");
        try appendMoveFields(&json, alloc, candidate, &board);
        _ = board.makeMove(candidate);
        try appendPostMoveFields(&json, alloc, &board);
        try json.appendSlice(alloc, ",\"depth\":0,\"score\":0,\"nodes\":0,\"source\":\"book\"}");
        try sendJson(request, .ok, json.items, .{ .keep_alive = true });
        return;
    }

    // Build search options (same logic as handleBestMove)
    const options: search_mod.SearchOptions = if (parsed.timeout_ms) |t|
        .{ .max_depth = @min(parsed.depth orelse 100, 100), .timeout_ns = t * std.time.ns_per_ms }
    else if (parsed.depth) |d|
        .{ .max_depth = @min(d, 20) }
    else
        .{ .timeout_ns = 5000 * std.time.ns_per_ms };

    // Run search
    const result = search_mod.searchIterative(&board, options, tt);

    const best_move = result.best_move orelse {
        try sendError(request, .bad_request, "no_moves", "No legal moves available in this position", .{ .keep_alive = true });
        return;
    };

    // Build move fields before making the move (SAN needs pre-move board)
    var json: JsonBuf = .empty;
    try json.appendSlice(alloc, "{");
    try appendMoveFields(&json, alloc, best_move, &board);

    // Make the move
    _ = board.makeMove(best_move);

    // Append post-move state (FEN, status, legal moves)
    try appendPostMoveFields(&json, alloc, &board);

    try json.appendSlice(alloc, ",\"depth\":");
    var depth_buf: [16]u8 = undefined;
    try json.appendSlice(alloc, std.fmt.bufPrint(&depth_buf, "{d}", .{result.depth}) catch unreachable);

    try json.appendSlice(alloc, ",\"score\":");
    var score_buf: [16]u8 = undefined;
    try json.appendSlice(alloc, std.fmt.bufPrint(&score_buf, "{d}", .{result.score}) catch unreachable);

    try json.appendSlice(alloc, ",\"nodes\":");
    var nodes_buf: [24]u8 = undefined;
    try json.appendSlice(alloc, std.fmt.bufPrint(&nodes_buf, "{d}", .{result.nodes}) catch unreachable);

    try json.appendSlice(alloc, ",\"source\":\"search\"}");

    try sendJson(request, .ok, json.items, .{ .keep_alive = true });
}

fn readBody(request: *Server.Request, allocator: Allocator) ![]const u8 {
    var read_buf: [8192]u8 = undefined;
    const reader = try request.readerExpectContinue(&read_buf);
    return try reader.allocRemaining(allocator, .limited(65536));
}

fn sendJson(request: *Server.Request, status: http.Status, body: []const u8, options: struct { keep_alive: bool = false }) !void {
    try request.respond(body, .{
        .status = status,
        .keep_alive = options.keep_alive,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Access-Control-Allow-Origin", .value = getCorsOrigin() },
            .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, OPTIONS" },
            .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type" },
        },
    });
}

fn sendError(request: *Server.Request, status: http.Status, code: []const u8, message: []const u8, options: struct { keep_alive: bool = false }) !void {
    var buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\",\"message\":\"{s}\"}}", .{ code, message }) catch unreachable;
    try sendJson(request, status, body, .{ .keep_alive = options.keep_alive });
}

fn computeGameStatus(board: *Board, legal_count: usize) []const u8 {
    if (legal_count == 0) {
        if (board.isInCheck()) return "checkmate";
        return "stalemate";
    }
    if (board.halfmove_clock >= 100) return "fifty_move_rule";
    if (isInsufficientMaterial(board)) return "insufficient_material";
    return "ongoing";
}

fn isInsufficientMaterial(board: *const Board) bool {
    const pawn = @intFromEnum(types.PieceType.pawn);
    const rook = @intFromEnum(types.PieceType.rook);
    const queen = @intFromEnum(types.PieceType.queen);
    const knight = @intFromEnum(types.PieceType.knight);
    const bishop = @intFromEnum(types.PieceType.bishop);

    if (board.pieces[0][pawn] != 0) return false;
    if (board.pieces[1][pawn] != 0) return false;
    if (board.pieces[0][rook] != 0) return false;
    if (board.pieces[1][rook] != 0) return false;
    if (board.pieces[0][queen] != 0) return false;
    if (board.pieces[1][queen] != 0) return false;

    const w_knights = bb.popCount(board.pieces[0][knight]);
    const w_bishops = bb.popCount(board.pieces[0][bishop]);
    const b_knights = bb.popCount(board.pieces[1][knight]);
    const b_bishops = bb.popCount(board.pieces[1][bishop]);

    const w_minor = w_knights + w_bishops;
    const b_minor = b_knights + b_bishops;

    if (w_minor == 0 and b_minor == 0) return true;
    if (w_minor == 0 and b_minor == 1) return true;
    if (w_minor == 1 and b_minor == 0) return true;
    if (w_minor == 1 and b_minor == 1 and w_bishops == 1 and b_bishops == 1) {
        const w_bsq = bb.lsb(board.pieces[0][bishop]);
        const b_bsq = bb.lsb(board.pieces[1][bishop]);
        const w_color = (@as(u8, w_bsq >> 3) + @as(u8, w_bsq & 7)) % 2;
        const b_color = (@as(u8, b_bsq >> 3) + @as(u8, b_bsq & 7)) % 2;
        if (w_color == b_color) return true;
    }

    return false;
}

fn appendPostMoveFields(json: *JsonBuf, alloc: Allocator, board_ptr: *Board) !void {
    var fen_buf: [100]u8 = undefined;
    const new_fen = board_ptr.toFen(&fen_buf);
    const after_legal = movegen.generateLegalMoves(board_ptr);
    const status = computeGameStatus(board_ptr, after_legal.count);
    const side = if (board_ptr.side_to_move == .white) "white" else "black";

    try json.appendSlice(alloc, ",\"fen\":\"");
    try json.appendSlice(alloc, new_fen);
    try json.appendSlice(alloc, "\",\"status\":\"");
    try json.appendSlice(alloc, status);
    try json.appendSlice(alloc, "\",\"side_to_move\":\"");
    try json.appendSlice(alloc, side);
    try json.appendSlice(alloc, "\",\"move_count\":");
    var count_buf: [16]u8 = undefined;
    try json.appendSlice(alloc, std.fmt.bufPrint(&count_buf, "{d}", .{after_legal.count}) catch unreachable);
    try json.appendSlice(alloc, ",\"moves\":[");

    for (after_legal.slice(), 0..) |m, i| {
        if (i > 0) try json.append(alloc, ',');
        try appendMoveObject(json, alloc, m, board_ptr, after_legal);
    }

    try json.appendSlice(alloc, "]");
}

fn appendJsonEscaped(json: *JsonBuf, alloc: Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try json.appendSlice(alloc, "\\\""),
            '\\' => try json.appendSlice(alloc, "\\\\"),
            '\n' => try json.appendSlice(alloc, "\\n"),
            '\r' => try json.appendSlice(alloc, "\\r"),
            '\t' => try json.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    // skip other control chars
                } else {
                    try json.append(alloc, c);
                }
            },
        }
    }
}

fn appendMoveFields(json: *JsonBuf, alloc: Allocator, move: Move, board: *Board) !void {
    var uci_buf: [6]u8 = undefined;
    const uci = notation.moveToLongAlgebraic(move, &uci_buf);
    var san_buf: [16]u8 = undefined;
    const san = notation.moveToSAN(move, board, &san_buf, null);
    const from_sq: Square = @enumFromInt(move.from);
    const to_sq: Square = @enumFromInt(move.to);
    const from_str = from_sq.toString();
    const to_str = to_sq.toString();

    try json.appendSlice(alloc, "\"uci\":\"");
    try json.appendSlice(alloc, uci);
    try json.appendSlice(alloc, "\",\"san\":\"");
    try json.appendSlice(alloc, san);
    try json.appendSlice(alloc, "\",\"from\":\"");
    try json.appendSlice(alloc, &from_str);
    try json.appendSlice(alloc, "\",\"to\":\"");
    try json.appendSlice(alloc, &to_str);
    try json.appendSlice(alloc, "\"");
}

fn appendMoveObject(json: *JsonBuf, alloc: Allocator, move: Move, board: *Board, legal: MoveList) !void {
    var uci_buf: [6]u8 = undefined;
    const uci = notation.moveToLongAlgebraic(move, &uci_buf);

    var san_buf: [16]u8 = undefined;
    const san = notation.moveToSAN(move, board, &san_buf, legal);

    const from_sq: Square = @enumFromInt(move.from);
    const to_sq: Square = @enumFromInt(move.to);
    const from_str = from_sq.toString();
    const to_str = to_sq.toString();

    const is_capture = move.flags.isCapture();
    const is_castling = move.flags == .king_castle or move.flags == .queen_castle;
    const is_check = san.len > 0 and (san[san.len - 1] == '+' or san[san.len - 1] == '#');

    try json.appendSlice(alloc, "{\"uci\":\"");
    try json.appendSlice(alloc, uci);
    try json.appendSlice(alloc, "\",\"san\":\"");
    try json.appendSlice(alloc, san);
    try json.appendSlice(alloc, "\",\"from\":\"");
    try json.appendSlice(alloc, &from_str);
    try json.appendSlice(alloc, "\",\"to\":\"");
    try json.appendSlice(alloc, &to_str);
    try json.appendSlice(alloc, "\",\"capture\":");
    try json.appendSlice(alloc, if (is_capture) "true" else "false");
    try json.appendSlice(alloc, ",\"promotion\":");
    if (move.flags.promotionPieceType()) |pt| {
        try json.appendSlice(alloc, "\"");
        try json.appendSlice(alloc, switch (pt) {
            .queen => "queen",
            .rook => "rook",
            .bishop => "bishop",
            .knight => "knight",
            else => "unknown",
        });
        try json.appendSlice(alloc, "\"");
    } else {
        try json.appendSlice(alloc, "null");
    }
    try json.appendSlice(alloc, ",\"castling\":");
    try json.appendSlice(alloc, if (is_castling) "true" else "false");
    try json.appendSlice(alloc, ",\"check\":");
    try json.appendSlice(alloc, if (is_check) "true" else "false");
    try json.appendSlice(alloc, "}");
}
