const std = @import("std");
const moves_mod = @import("moves.zig");
const eval_mod = @import("eval.zig");

const Move = moves_mod.Move;
const Allocator = std.mem.Allocator;

pub const TTFlag = enum(u2) {
    none = 0,
    exact = 1,
    alpha = 2, // upper bound (failed low)
    beta = 3, // lower bound (failed high)
};

pub const TTEntry = struct {
    key: u32 = 0, // upper 32 bits of hash (lower bits = index)
    best_move: u16 = 0, // raw @bitCast of Move (0 = no move)
    score: i16 = 0,
    depth: i8 = 0,
    flag: TTFlag = .none,
    age: u8 = 0,
};

pub const TranspositionTable = struct {
    entries: []TTEntry,
    mask: u64, // size - 1 (power-of-2 for fast AND indexing)
    age: u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, size_mb: u32) !TranspositionTable {
        const entry_size = @sizeOf(TTEntry);
        const num_entries_raw = @as(u64, size_mb) * 1024 * 1024 / entry_size;
        // Round down to power of 2
        const num_entries = blk: {
            var n = num_entries_raw;
            n |= n >> 1;
            n |= n >> 2;
            n |= n >> 4;
            n |= n >> 8;
            n |= n >> 16;
            n |= n >> 32;
            break :blk (n >> 1) + 1;
        };

        const entries = try allocator.alloc(TTEntry, num_entries);
        @memset(entries, TTEntry{});

        return .{
            .entries = entries,
            .mask = num_entries - 1,
            .age = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TranspositionTable) void {
        self.allocator.free(self.entries);
    }

    pub fn newSearch(self: *TranspositionTable) void {
        self.age +%= 1;
    }

    pub fn probe(self: *const TranspositionTable, hash: u64) ?TTEntry {
        const index = hash & self.mask;
        const entry = self.entries[index];
        const key: u32 = @truncate(hash >> 32);
        if (entry.flag != .none and entry.key == key) {
            return entry;
        }
        return null;
    }

    pub fn store(self: *TranspositionTable, hash: u64, depth: i8, score: i16, flag: TTFlag, best_move: u16) void {
        const index = hash & self.mask;
        const key: u32 = @truncate(hash >> 32);
        const existing = &self.entries[index];

        // Replace if: empty, stale age, or new depth >= stored depth
        if (existing.flag == .none or existing.age != self.age or depth >= existing.depth) {
            existing.* = .{
                .key = key,
                .best_move = best_move,
                .score = score,
                .depth = depth,
                .flag = flag,
                .age = self.age,
            };
        }
    }

    pub fn clear(self: *TranspositionTable) void {
        @memset(self.entries, TTEntry{});
    }
};

/// Adjust mate scores for TT storage: remove ply distance so stored score is
/// "mate in N from root" rather than "mate in N from this node".
pub fn scoreToTT(score: i32, ply: u32) i16 {
    const ply_i: i32 = @intCast(ply);
    var s = score;
    if (s >= eval_mod.CHECKMATE_SCORE - 256) {
        s += ply_i;
    } else if (s <= -eval_mod.CHECKMATE_SCORE + 256) {
        s -= ply_i;
    }
    return @intCast(std.math.clamp(s, -32000, 32000));
}

/// Reverse the mate score adjustment when retrieving from TT.
pub fn scoreFromTT(score: i16, ply: u32) i32 {
    const ply_i: i32 = @intCast(ply);
    var s: i32 = score;
    if (s >= eval_mod.CHECKMATE_SCORE - 256) {
        s -= ply_i;
    } else if (s <= -eval_mod.CHECKMATE_SCORE + 256) {
        s += ply_i;
    }
    return s;
}

test "TT store and probe" {
    var tt = try TranspositionTable.init(std.testing.allocator, 1);
    defer tt.deinit();

    const hash: u64 = 0xDEADBEEF12345678;
    const move_raw: u16 = 0x1234;

    tt.store(hash, 5, 100, .exact, move_raw);

    const entry = tt.probe(hash);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(i16, 100), entry.?.score);
    try std.testing.expectEqual(@as(i8, 5), entry.?.depth);
    try std.testing.expectEqual(TTFlag.exact, entry.?.flag);
    try std.testing.expectEqual(@as(u16, 0x1234), entry.?.best_move);
}

test "TT probe miss returns null" {
    var tt = try TranspositionTable.init(std.testing.allocator, 1);
    defer tt.deinit();

    const entry = tt.probe(0x1234567890ABCDEF);
    try std.testing.expectEqual(@as(?TTEntry, null), entry);
}

test "mate score TT roundtrip" {
    const mate_score = eval_mod.CHECKMATE_SCORE - 5; // mate in 5
    const ply: u32 = 3;

    const tt_score = scoreToTT(mate_score, ply);
    const restored = scoreFromTT(tt_score, ply);

    try std.testing.expectEqual(mate_score, restored);
}

test "negative mate score TT roundtrip" {
    const mate_score = -eval_mod.CHECKMATE_SCORE + 7; // mated in 7
    const ply: u32 = 2;

    const tt_score = scoreToTT(mate_score, ply);
    const restored = scoreFromTT(tt_score, ply);

    try std.testing.expectEqual(mate_score, restored);
}

test "TT newSearch increments age" {
    var tt = try TranspositionTable.init(std.testing.allocator, 1);
    defer tt.deinit();

    try std.testing.expectEqual(@as(u8, 0), tt.age);
    tt.newSearch();
    try std.testing.expectEqual(@as(u8, 1), tt.age);
}
