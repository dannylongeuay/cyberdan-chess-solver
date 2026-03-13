const std = @import("std");
const bb = @import("bitboard.zig");
const Bitboard = bb.Bitboard;
const Square = @import("square.zig").Square;

pub fn rookMask(sq_idx: u6) Bitboard {
    var attacks: Bitboard = 0;
    const r = @as(i8, sq_idx >> 3);
    const f = @as(i8, sq_idx & 7);

    var rr: i8 = r + 1;
    while (rr <= 6) : (rr += 1) attacks |= @as(u64, 1) << @intCast(rr * 8 + f);
    rr = r - 1;
    while (rr >= 1) : (rr -= 1) attacks |= @as(u64, 1) << @intCast(rr * 8 + f);
    var ff: i8 = f + 1;
    while (ff <= 6) : (ff += 1) attacks |= @as(u64, 1) << @intCast(r * 8 + ff);
    ff = f - 1;
    while (ff >= 1) : (ff -= 1) attacks |= @as(u64, 1) << @intCast(r * 8 + ff);

    return attacks;
}

pub fn bishopMask(sq_idx: u6) Bitboard {
    var attacks: Bitboard = 0;
    const r = @as(i8, sq_idx >> 3);
    const f = @as(i8, sq_idx & 7);

    var rr: i8 = r + 1;
    var ff: i8 = f + 1;
    while (rr <= 6 and ff <= 6) : ({
        rr += 1;
        ff += 1;
    }) attacks |= @as(u64, 1) << @intCast(rr * 8 + ff);

    rr = r + 1;
    ff = f - 1;
    while (rr <= 6 and ff >= 1) : ({
        rr += 1;
        ff -= 1;
    }) attacks |= @as(u64, 1) << @intCast(rr * 8 + ff);

    rr = r - 1;
    ff = f + 1;
    while (rr >= 1 and ff <= 6) : ({
        rr -= 1;
        ff += 1;
    }) attacks |= @as(u64, 1) << @intCast(rr * 8 + ff);

    rr = r - 1;
    ff = f - 1;
    while (rr >= 1 and ff >= 1) : ({
        rr -= 1;
        ff -= 1;
    }) attacks |= @as(u64, 1) << @intCast(rr * 8 + ff);

    return attacks;
}

pub fn rookAttacksSlow(sq_idx: u6, blockers: Bitboard) Bitboard {
    var attacks: Bitboard = 0;
    const r = @as(i8, sq_idx >> 3);
    const f = @as(i8, sq_idx & 7);

    var rr: i8 = r + 1;
    while (rr <= 7) : (rr += 1) {
        const bit = @as(u64, 1) << @intCast(rr * 8 + f);
        attacks |= bit;
        if (blockers & bit != 0) break;
    }
    rr = r - 1;
    while (rr >= 0) : (rr -= 1) {
        const bit = @as(u64, 1) << @intCast(rr * 8 + f);
        attacks |= bit;
        if (blockers & bit != 0) break;
    }
    var ff: i8 = f + 1;
    while (ff <= 7) : (ff += 1) {
        const bit = @as(u64, 1) << @intCast(r * 8 + ff);
        attacks |= bit;
        if (blockers & bit != 0) break;
    }
    ff = f - 1;
    while (ff >= 0) : (ff -= 1) {
        const bit = @as(u64, 1) << @intCast(r * 8 + ff);
        attacks |= bit;
        if (blockers & bit != 0) break;
    }

    return attacks;
}

pub fn bishopAttacksSlow(sq_idx: u6, blockers: Bitboard) Bitboard {
    var attacks: Bitboard = 0;
    const r = @as(i8, sq_idx >> 3);
    const f = @as(i8, sq_idx & 7);

    var rr: i8 = r + 1;
    var ff: i8 = f + 1;
    while (rr <= 7 and ff <= 7) : ({
        rr += 1;
        ff += 1;
    }) {
        const bit = @as(u64, 1) << @intCast(rr * 8 + ff);
        attacks |= bit;
        if (blockers & bit != 0) break;
    }

    rr = r + 1;
    ff = f - 1;
    while (rr <= 7 and ff >= 0) : ({
        rr += 1;
        ff -= 1;
    }) {
        const bit = @as(u64, 1) << @intCast(rr * 8 + ff);
        attacks |= bit;
        if (blockers & bit != 0) break;
    }

    rr = r - 1;
    ff = f + 1;
    while (rr >= 0 and ff <= 7) : ({
        rr -= 1;
        ff += 1;
    }) {
        const bit = @as(u64, 1) << @intCast(rr * 8 + ff);
        attacks |= bit;
        if (blockers & bit != 0) break;
    }

    rr = r - 1;
    ff = f - 1;
    while (rr >= 0 and ff >= 0) : ({
        rr -= 1;
        ff -= 1;
    }) {
        const bit = @as(u64, 1) << @intCast(rr * 8 + ff);
        attacks |= bit;
        if (blockers & bit != 0) break;
    }

    return attacks;
}

// Use plain/fancy hybrid: fixed max table size, one magic per square
// All squares use 12-bit index for rooks, 9-bit for bishops
const rook_shift: u6 = 52; // 64 - 12
const bishop_shift: u6 = 55; // 64 - 9
const rook_table_size = 4096; // 2^12
const bishop_table_size = 512; // 2^9

// Runtime state
var rook_masks_arr: [64]Bitboard = undefined;
var bishop_masks_arr: [64]Bitboard = undefined;
var rook_magic_arr: [64]u64 = undefined;
var bishop_magic_arr: [64]u64 = undefined;
var rook_table: [64][rook_table_size]Bitboard = undefined;
var bishop_table: [64][bishop_table_size]Bitboard = undefined;
var initialized = false;

fn tryMagic(magic: u64, mask: Bitboard, sq_idx: u6, comptime is_bishop: bool, table: []Bitboard) bool {
    const table_size = if (is_bishop) bishop_table_size else rook_table_size;
    const shift = if (is_bishop) bishop_shift else rook_shift;

    // Clear table
    for (0..table_size) |i| table[i] = 0;

    // Use a separate "used" tracker via a flag approach:
    // We store attacks+1 (since attacks can be 0 for edge cases? no, never 0).
    // Actually, real attacks are never 0 for rook/bishop. Let's use a separate array.
    var used = [_]bool{false} ** 4096;

    var occ: Bitboard = 0;
    while (true) {
        const attacks_val = if (is_bishop) bishopAttacksSlow(sq_idx, occ) else rookAttacksSlow(sq_idx, occ);
        const index = @as(usize, (occ *% magic) >> shift);
        if (index >= table_size) return false;

        if (used[index]) {
            if (table[index] != attacks_val) return false; // Destructive collision
        } else {
            used[index] = true;
            table[index] = attacks_val;
        }

        occ = (occ -% mask) & mask;
        if (occ == 0) break;
    }

    return true;
}

fn findMagic(sq_idx: u6, comptime is_bishop: bool, table: []Bitboard) u64 {
    const mask = if (is_bishop) bishopMask(sq_idx) else rookMask(sq_idx);

    // Use a simple PRNG for magic candidate generation
    var state: u64 = @as(u64, sq_idx) *% 6364136223846793005 +% 1442695040888963407;
    if (is_bishop) state +%= 0x12345678;

    var attempts: u32 = 0;
    while (attempts < 100_000_000) : (attempts += 1) {
        // Generate sparse random number (AND three randoms together)
        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        const r1 = state *% 0x2545F4914F6CDD1D;
        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        const r2 = state *% 0x2545F4914F6CDD1D;
        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        const r3 = state *% 0x2545F4914F6CDD1D;

        const magic = r1 & r2 & r3;

        // Quick rejection: magic should map mask bits to top bits
        if (@popCount((mask *% magic) & 0xFF00000000000000) < 6) continue;

        if (tryMagic(magic, mask, sq_idx, is_bishop, table)) {
            return magic;
        }
    }

    unreachable; // Should always find a magic
}

pub fn init() void {
    if (initialized) return;

    for (0..64) |sq| {
        const sq_idx: u6 = @intCast(sq);
        rook_masks_arr[sq] = rookMask(sq_idx);
        bishop_masks_arr[sq] = bishopMask(sq_idx);

        rook_magic_arr[sq] = findMagic(sq_idx, false, &rook_table[sq]);
        bishop_magic_arr[sq] = findMagic(sq_idx, true, &bishop_table[sq]);
    }

    initialized = true;
}

pub inline fn getRookAttacks(sq: u6, occupancy: Bitboard) Bitboard {
    const masked = occupancy & rook_masks_arr[sq];
    const index = (masked *% rook_magic_arr[sq]) >> rook_shift;
    return rook_table[sq][index];
}

pub inline fn getBishopAttacks(sq: u6, occupancy: Bitboard) Bitboard {
    const masked = occupancy & bishop_masks_arr[sq];
    const index = (masked *% bishop_magic_arr[sq]) >> bishop_shift;
    return bishop_table[sq][index];
}

test "slow attack functions" {
    const e4_bishop_slow = bishopAttacksSlow(28, 0);
    try std.testing.expect(e4_bishop_slow & Square.b1.toBitboard() != 0);
    try std.testing.expect(e4_bishop_slow & Square.h1.toBitboard() != 0);
    try std.testing.expect(e4_bishop_slow & Square.a8.toBitboard() != 0);
    try std.testing.expect(e4_bishop_slow & Square.h7.toBitboard() != 0);
}

test "magic bitboards init and lookup" {
    init();

    // Rook on e4 with no blockers
    const e4_rook = getRookAttacks(@intFromEnum(Square.e4), 0);
    try std.testing.expect(e4_rook & Square.e1.toBitboard() != 0);
    try std.testing.expect(e4_rook & Square.e8.toBitboard() != 0);
    try std.testing.expect(e4_rook & Square.a4.toBitboard() != 0);
    try std.testing.expect(e4_rook & Square.h4.toBitboard() != 0);
    try std.testing.expect(e4_rook & Square.e4.toBitboard() == 0);

    // Bishop on e4 with no blockers
    const e4_bishop = getBishopAttacks(@intFromEnum(Square.e4), 0);
    try std.testing.expect(e4_bishop & Square.a8.toBitboard() != 0);
    try std.testing.expect(e4_bishop & Square.h7.toBitboard() != 0);
    try std.testing.expect(e4_bishop & Square.h1.toBitboard() != 0);
    try std.testing.expect(e4_bishop & Square.b1.toBitboard() != 0);

    // Bishop on e4 with blocker on c2
    const e4_bishop_blocked = getBishopAttacks(@intFromEnum(Square.e4), Square.c2.toBitboard());
    try std.testing.expect(e4_bishop_blocked & Square.c2.toBitboard() != 0);
    try std.testing.expect(e4_bishop_blocked & Square.b1.toBitboard() == 0);
}
