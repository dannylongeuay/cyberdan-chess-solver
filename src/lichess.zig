const std = @import("std");
const board_mod = @import("board.zig");
const moves_mod = @import("moves.zig");
const movegen = @import("movegen.zig");
const notation = @import("notation.zig");
const search_mod = @import("search.zig");
const tt_mod = @import("tt.zig");
const types = @import("types.zig");
const book = @import("book.zig");

const Board = board_mod.Board;
const Move = moves_mod.Move;
const TranspositionTable = tt_mod.TranspositionTable;

const base_url = "https://lichess.org";

// --- JSON types ---

const StreamEvent = struct {
    type: []const u8,
    game: ?GameStartInfo = null,
    challenge: ?ChallengeInfo = null,
};

const GameStartInfo = struct {
    gameId: []const u8 = "",
    id: []const u8 = "",
};

const ChallengeInfo = struct {
    id: []const u8,
    rated: bool = false,
    variant: VariantInfo = .{},
    speed: []const u8 = "",
};

const VariantInfo = struct {
    key: []const u8 = "standard",
};

const AccountInfo = struct {
    id: []const u8,
    username: []const u8,
};

const PlayerInfo = struct {
    id: []const u8 = "",
    name: []const u8 = "",
};

const GameFull = struct {
    type: []const u8 = "",
    white: PlayerInfo = .{},
    black: PlayerInfo = .{},
    initialFen: []const u8 = "startpos",
    state: GameStateEvent = .{},
};

const GameStateEvent = struct {
    type: []const u8 = "",
    moves: []const u8 = "",
    status: []const u8 = "",
    wtime: ?u64 = null,
    btime: ?u64 = null,
    winc: ?u64 = null,
    binc: ?u64 = null,
    wdraw: ?bool = null,
    bdraw: ?bool = null,
    wtakeback: ?bool = null,
    btakeback: ?bool = null,
};

// --- Global state ---

var in_game = std.atomic.Value(bool).init(false);
var running = std.atomic.Value(bool).init(true);

// --- Entry point ---

pub fn run() !void {
    const token = std.posix.getenv("LICHESS_TOKEN") orelse {
        std.debug.print("Error: LICHESS_TOKEN environment variable not set\n", .{});
        return error.MissingToken;
    };

    // Fetch account info using a temporary arena
    var bot_id_buf: [64]u8 = undefined;
    var bot_id_len: usize = 0;
    {
        var init_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer init_arena.deinit();
        const init_alloc = init_arena.allocator();

        const account_body = try apiFetch(init_alloc, token, "/api/account", .GET, null);
        const account = std.json.parseFromSliceLeaky(AccountInfo, init_alloc, account_body, .{
            .ignore_unknown_fields = true,
        }) catch {
            std.debug.print("Failed to parse account info\n", .{});
            return error.ParseError;
        };
        std.debug.print("Logged in as: {s}\n", .{account.username});

        if (account.id.len > bot_id_buf.len) return error.BotIdTooLong;
        @memcpy(bot_id_buf[0..account.id.len], account.id);
        bot_id_len = account.id.len;
    }
    const bot_id = bot_id_buf[0..bot_id_len];

    // Allocate TT
    var tt = TranspositionTable.init(std.heap.page_allocator, 64) catch {
        std.debug.print("Failed to allocate transposition table\n", .{});
        return error.TTAlloc;
    };
    defer tt.deinit();

    // Event stream with reconnection — fresh arena per connection
    while (running.load(.monotonic)) {
        std.debug.print("Connecting to event stream...\n", .{});
        {
            var stream_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer stream_arena.deinit();
            streamEvents(stream_arena.allocator(), token, bot_id, &tt) catch |err| {
                std.debug.print("Event stream error: {}, reconnecting in 5s...\n", .{err});
            };
        }
        if (!running.load(.monotonic)) break;
        std.Thread.sleep(5 * std.time.ns_per_s);
    }
}

// --- Event stream ---

fn streamEvents(alloc: std.mem.Allocator, token: []const u8, bot_id: []const u8, tt: *TranspositionTable) !void {
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var url_buf: [512]u8 = undefined;
    const url_str = std.fmt.bufPrint(&url_buf, "{s}/api/stream/event", .{base_url}) catch return error.UrlTooLong;
    const uri = std.Uri.parse(url_str) catch return error.InvalidUri;

    var auth_buf: [256]u8 = undefined;
    const auth_value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch return error.AuthTooLong;

    var req = try client.request(.GET, uri, .{
        .headers = .{ .authorization = .{ .override = auth_value } },
        .extra_headers = &.{.{ .name = "accept", .value = "application/x-ndjson" }},
        .keep_alive = false,
        .redirect_behavior = .unhandled,
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [1]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    if (response.head.status != .ok) {
        std.debug.print("Event stream returned status: {}\n", .{response.head.status});
        if (response.head.status == .unauthorized) return error.Unauthorized;
        return error.ApiError;
    }

    var transfer_buf: [64]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);

    while (running.load(.monotonic)) {
        const line = body_reader.takeDelimiter('\n') catch break orelse break;
        if (line.len == 0) continue; // keepalive

        const event = std.json.parseFromSliceLeaky(StreamEvent, alloc, line, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.debug.print("Failed to parse event: {}\n", .{err});
            continue;
        };

        if (std.mem.eql(u8, event.type, "gameStart")) {
            const game_id = if (event.game) |g|
                (if (g.gameId.len > 0) g.gameId else g.id)
            else
                "";
            if (game_id.len == 0) continue;

            if (in_game.load(.monotonic)) {
                std.debug.print("Already in a game, ignoring gameStart for {s}\n", .{game_id});
                continue;
            }

            const game_id_copy = try alloc.dupe(u8, game_id);
            const token_copy = try alloc.dupe(u8, token);
            const bot_id_copy = try alloc.dupe(u8, bot_id);
            in_game.store(true, .monotonic);

            const thread = std.Thread.spawn(.{}, gameThreadFn, .{
                game_id_copy, token_copy, bot_id_copy, tt,
            }) catch |err| {
                std.debug.print("Failed to spawn game thread: {}\n", .{err});
                in_game.store(false, .monotonic);
                continue;
            };
            thread.detach();
        } else if (std.mem.eql(u8, event.type, "gameFinish")) {
            std.debug.print("Game finished\n", .{});
            // in_game flag is owned by the game thread (defer in gameThreadFn)
        } else if (std.mem.eql(u8, event.type, "challenge")) {
            if (event.challenge) |challenge| {
                handleChallenge(alloc, token, challenge);
            }
        } else if (std.mem.eql(u8, event.type, "challengeCanceled")) {
            std.debug.print("Challenge canceled\n", .{});
        } else if (std.mem.eql(u8, event.type, "challengeDeclined")) {
            std.debug.print("Challenge declined\n", .{});
        }
    }
}

// --- Challenge handling ---

fn handleChallenge(alloc: std.mem.Allocator, token: []const u8, challenge: ChallengeInfo) void {
    const busy = in_game.load(.monotonic);
    const is_standard = std.mem.eql(u8, challenge.variant.key, "standard");
    const is_acceptable_speed = std.mem.eql(u8, challenge.speed, "bullet") or
        std.mem.eql(u8, challenge.speed, "blitz") or
        std.mem.eql(u8, challenge.speed, "rapid");

    if (!busy and !challenge.rated and is_standard and is_acceptable_speed) {
        std.debug.print("Accepting challenge {s}\n", .{challenge.id});
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/challenge/{s}/accept", .{challenge.id}) catch return;
        _ = apiFetch(alloc, token, path, .POST, null) catch |err| {
            std.debug.print("Failed to accept challenge: {}\n", .{err});
        };
    } else {
        std.debug.print("Declining challenge {s} (rated={}, variant={s}, speed={s}, in_game={})\n", .{
            challenge.id, challenge.rated, challenge.variant.key, challenge.speed, busy,
        });
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/challenge/{s}/decline", .{challenge.id}) catch return;
        _ = apiFetch(alloc, token, path, .POST, null) catch |err| {
            std.debug.print("Failed to decline challenge: {}\n", .{err});
        };
    }
}

// --- Game thread ---

fn gameThreadFn(game_id: []const u8, token: []const u8, bot_id: []const u8, tt: *TranspositionTable) void {
    defer in_game.store(false, .monotonic);

    playGame(game_id, token, bot_id, tt) catch |err| {
        std.debug.print("Game {s} fatal error: {}, resigning\n", .{ game_id, err });
        resignGame(game_id, token);
    };
    std.debug.print("Game {s} ended\n", .{game_id});
}

fn resignGame(game_id: []const u8, token: []const u8) void {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/api/bot/game/{s}/resign", .{game_id}) catch return;
    // Use page_allocator directly since we may not have a valid arena
    var resign_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer resign_arena.deinit();
    _ = apiFetch(resign_arena.allocator(), token, path, .POST, null) catch |err| {
        std.debug.print("Failed to resign game {s}: {}\n", .{ game_id, err });
    };
}

fn playGame(game_id: []const u8, token: []const u8, bot_id: []const u8, tt: *TranspositionTable) !void {
    var game_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer game_arena.deinit();
    const alloc = game_arena.allocator();

    // Send greeting
    {
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/bot/game/{s}/chat", .{game_id}) catch return;
        _ = apiFetch(alloc, token, path, .POST, "room=player&text=Good+luck%2C+have+fun!") catch |err| {
            std.debug.print("Failed to send chat: {}\n", .{err});
        };
    }

    // Open game stream
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var url_buf: [512]u8 = undefined;
    const url_str = std.fmt.bufPrint(&url_buf, "{s}/api/bot/game/stream/{s}", .{ base_url, game_id }) catch return;
    const uri = std.Uri.parse(url_str) catch return;

    var auth_buf: [256]u8 = undefined;
    const auth_value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch return;

    var req = try client.request(.GET, uri, .{
        .headers = .{ .authorization = .{ .override = auth_value } },
        .extra_headers = &.{.{ .name = "accept", .value = "application/x-ndjson" }},
        .keep_alive = false,
        .redirect_behavior = .unhandled,
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [1]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    if (response.head.status != .ok) {
        std.debug.print("Game stream returned status: {}\n", .{response.head.status});
        return error.ApiError;
    }

    var transfer_buf: [64]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);

    // First line should be gameFull
    const first_line = body_reader.takeDelimiter('\n') catch return orelse return;
    if (first_line.len == 0) return;

    const game_full = std.json.parseFromSliceLeaky(GameFull, alloc, first_line, .{
        .ignore_unknown_fields = true,
    }) catch return;

    // Determine our color
    const our_color: types.Color = if (std.ascii.eqlIgnoreCase(game_full.white.id, bot_id))
        .white
    else if (std.ascii.eqlIgnoreCase(game_full.black.id, bot_id))
        .black
    else {
        std.debug.print("Could not determine our color in game {s}\n", .{game_id});
        return error.UnknownColor;
    };

    std.debug.print("Game {s}: playing as {s}\n", .{ game_id, if (our_color == .white) "white" else "black" });

    // Initial FEN
    var initial_fen: ?[]const u8 = null;
    if (!std.mem.eql(u8, game_full.initialFen, "startpos")) {
        initial_fen = try alloc.dupe(u8, game_full.initialFen);
    }

    // Process initial state
    tt.newSearch();
    processGameState(alloc, token, game_id, game_full.state, initial_fen, our_color, tt);

    // Read subsequent events
    while (running.load(.monotonic)) {
        const line = body_reader.takeDelimiter('\n') catch break orelse break;
        if (line.len == 0) continue;

        // Parse event type via JSON before dispatching
        const TypeOnly = struct { type: []const u8 = "" };
        const evt = std.json.parseFromSliceLeaky(TypeOnly, alloc, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;

        if (std.mem.eql(u8, evt.type, "opponentGone")) {
            std.debug.print("Opponent gone, attempting to claim victory/draw\n", .{});
            var claim_buf: [128]u8 = undefined;
            if (std.fmt.bufPrint(&claim_buf, "/api/bot/game/{s}/claim-victory", .{game_id})) |path| {
                _ = apiFetch(alloc, token, path, .POST, null) catch {};
            } else |_| {}
            if (std.fmt.bufPrint(&claim_buf, "/api/bot/game/{s}/draw/yes", .{game_id})) |path| {
                _ = apiFetch(alloc, token, path, .POST, null) catch {};
            } else |_| {}
            continue;
        }

        if (std.mem.eql(u8, evt.type, "chatLine")) continue;

        if (!std.mem.eql(u8, evt.type, "gameState")) {
            std.debug.print("Game {s}: ignoring unknown event type '{s}'\n", .{ game_id, evt.type });
            continue;
        }

        const state = std.json.parseFromSliceLeaky(GameStateEvent, alloc, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;

        if (!std.mem.eql(u8, state.status, "started") and !std.mem.eql(u8, state.status, "created")) {
            std.debug.print("Game {s} status: {s}\n", .{ game_id, state.status });
            break;
        }

        processGameState(alloc, token, game_id, state, initial_fen, our_color, tt);
    }
}

fn processGameState(
    alloc: std.mem.Allocator,
    token: []const u8,
    game_id: []const u8,
    state: GameStateEvent,
    initial_fen: ?[]const u8,
    our_color: types.Color,
    tt: *TranspositionTable,
) void {
    declineOffers(alloc, token, game_id, state, our_color);

    var board = boardFromMoves(initial_fen, state.moves) catch |err| {
        std.debug.print("Failed to reconstruct board: {}\n", .{err});
        return;
    };

    if (board.side_to_move != our_color) return;

    makeBotMove(alloc, token, game_id, &board, state, our_color, tt);
}

fn declineOffers(alloc: std.mem.Allocator, token: []const u8, game_id: []const u8, state: GameStateEvent, our_color: types.Color) void {
    const their_draw = if (our_color == .white) state.bdraw else state.wdraw;
    const their_takeback = if (our_color == .white) state.btakeback else state.wtakeback;

    if (their_draw orelse false) {
        std.debug.print("Declining draw offer\n", .{});
        var buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "/api/bot/game/{s}/draw/no", .{game_id}) catch return;
        _ = apiFetch(alloc, token, path, .POST, null) catch {};
    }

    if (their_takeback orelse false) {
        std.debug.print("Declining takeback offer\n", .{});
        var buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "/api/bot/game/{s}/takeback/no", .{game_id}) catch return;
        _ = apiFetch(alloc, token, path, .POST, null) catch {};
    }
}

fn boardFromMoves(initial_fen: ?[]const u8, moves_str: []const u8) !Board {
    var board = if (initial_fen) |fen|
        try Board.fromFen(fen)
    else
        Board.init();

    if (moves_str.len == 0) return board;

    var iter = std.mem.tokenizeScalar(u8, moves_str, ' ');
    while (iter.next()) |move_str| {
        const move = notation.parseMove(move_str, &board) orelse {
            std.debug.print("Invalid move in game state: {s}\n", .{move_str});
            return error.InvalidMove;
        };
        _ = board.makeMove(move);
    }

    return board;
}

fn makeBotMove(
    alloc: std.mem.Allocator,
    token: []const u8,
    game_id: []const u8,
    board: *Board,
    state: GameStateEvent,
    our_color: types.Color,
    tt: *TranspositionTable,
) void {
    // Check opening book first
    if (book.probe(board.hash)) |hit| {
        const candidate = hit.pickRandom();
        const legal = movegen.generateLegalMoves(board);
        for (legal.slice()) |m| {
            if (m.from == candidate.from and m.to == candidate.to and m.flags == candidate.flags) {
                sendMove(alloc, token, game_id, candidate);
                return;
            }
        }
    }

    // Compute time allocation
    const our_time = if (our_color == .white) state.wtime else state.btime;
    const our_inc = if (our_color == .white) state.winc else state.binc;

    var timeout_ns: ?u64 = null;
    if (our_time) |ot| {
        const inc = our_inc orelse 0;
        var alloc_ms: u64 = ot / 30 + inc * 3 / 4;
        const margin = @max(ot / 10, 10);
        if (ot > margin) {
            alloc_ms = @min(alloc_ms, ot - margin);
        } else {
            alloc_ms = 1;
        }
        alloc_ms = @max(1, alloc_ms);
        timeout_ns = alloc_ms * std.time.ns_per_ms;
    } else {
        timeout_ns = 10 * std.time.ns_per_s; // fallback 10s
    }

    const result = search_mod.searchIterative(board, .{
        .timeout_ns = timeout_ns,
    }, tt);

    const move = result.best_move orelse {
        std.debug.print("No legal move found!\n", .{});
        return;
    };

    std.debug.print("Playing move (depth={d}, score={d})\n", .{ result.depth, result.score });
    sendMove(alloc, token, game_id, move);
}

fn sendMove(alloc: std.mem.Allocator, token: []const u8, game_id: []const u8, move: Move) void {
    var move_buf: [6]u8 = undefined;
    const move_str = notation.moveToLongAlgebraic(move, &move_buf);

    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/api/bot/game/{s}/move/{s}", .{ game_id, move_str }) catch return;

    std.debug.print("Sending move: {s}\n", .{move_str});
    _ = apiFetch(alloc, token, path, .POST, null) catch |err| {
        std.debug.print("Failed to send move: {}\n", .{err});
    };
}

// --- HTTP helper ---

fn apiFetch(alloc: std.mem.Allocator, token: []const u8, path: []const u8, method: std.http.Method, body: ?[]const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var url_buf: [512]u8 = undefined;
    const url_str = std.fmt.bufPrint(&url_buf, "{s}{s}", .{ base_url, path }) catch return error.UrlTooLong;
    const uri = std.Uri.parse(url_str) catch return error.InvalidUri;

    var auth_buf: [256]u8 = undefined;
    const auth_value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch return error.AuthTooLong;

    var req = try client.request(method, uri, .{
        .headers = .{
            .authorization = .{ .override = auth_value },
            .content_type = if (body != null) .{ .override = "application/x-www-form-urlencoded" } else .default,
        },
        .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
        .keep_alive = false,
        .redirect_behavior = .unhandled,
    });
    defer req.deinit();

    if (method.requestHasBody()) {
        const b = body orelse "";
        req.transfer_encoding = .{ .content_length = b.len };
        var bw = try req.sendBodyUnflushed(&.{});
        if (b.len > 0) try bw.writer.writeAll(b);
        try bw.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buf: [1]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    if (response.head.status != .ok) {
        std.debug.print("API {s} returned status: {}\n", .{ path, response.head.status });
        if (response.head.status == .unauthorized) return error.Unauthorized;
        // Discard body to avoid connection issues
        var discard_buf: [64]u8 = undefined;
        const r = response.reader(&discard_buf);
        _ = r.discardRemaining() catch {};
        return error.ApiError;
    }

    if (method.responseHasBody()) {
        var transfer_buf: [64]u8 = undefined;
        const r = response.reader(&transfer_buf);
        return r.allocRemaining(alloc, .unlimited);
    }

    return "";
}
