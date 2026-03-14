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

pub fn serve(port: u16) !void {
    const address = net.Address.parseIp4("0.0.0.0", port) catch unreachable;
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("Chess server listening on http://0.0.0.0:{d}\n", .{port});

    while (true) {
        const conn = try server.accept();
        const thread = try std.Thread.spawn(.{}, handleConnection, .{conn});
        thread.detach();
    }
}

fn handleConnection(conn: net.Server.Connection) void {
    defer conn.stream.close();

    var reader_buf: [8192]u8 = undefined;
    var writer_buf: [8192]u8 = undefined;
    var conn_reader = conn.stream.reader(&reader_buf);
    var conn_writer = conn.stream.writer(&writer_buf);

    var http_server = Server.init(conn_reader.interface(), &conn_writer.interface);

    while (true) {
        var request = http_server.receiveHead() catch |err| {
            std.debug.print("Connection error: {}\n", .{err});
            return;
        };
        handleRequest(&request) catch |err| {
            std.debug.print("Request handler error: {}\n", .{err});
            return;
        };
        if (!request.head.keep_alive) return;
    }
}

fn handleRequest(request: *Server.Request) !void {
    const method = request.head.method;
    const target = request.head.target;

    if (method == .OPTIONS) {
        try request.respond("", .{
            .status = .no_content,
            .extra_headers = &.{
                .{ .name = "Access-Control-Allow-Origin", .value = "*" },
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

    // Get SAN before making the move
    var san_buf: [16]u8 = undefined;
    const san = notation.moveToSAN(move, &board, &san_buf, null);
    const san_copy = try alloc.dupe(u8, san);

    // Make the move
    _ = board.makeMove(move);

    // Get new FEN
    var fen_buf: [100]u8 = undefined;
    const new_fen = board.toFen(&fen_buf);

    // Determine game status
    const after_legal = movegen.generateLegalMoves(&board);
    const status = computeGameStatus(&board, after_legal.count);
    const side = if (board.side_to_move == .white) "white" else "black";

    // Build response JSON
    var json: JsonBuf = .empty;
    try json.appendSlice(alloc, "{\"fen\":\"");
    try json.appendSlice(alloc, new_fen);
    try json.appendSlice(alloc, "\",\"san\":\"");
    try json.appendSlice(alloc, san_copy);
    try json.appendSlice(alloc, "\",\"status\":\"");
    try json.appendSlice(alloc, status);
    try json.appendSlice(alloc, "\",\"side_to_move\":\"");
    try json.appendSlice(alloc, side);
    try json.appendSlice(alloc, "\"}");

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
            .{ .name = "Access-Control-Allow-Origin", .value = "*" },
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
