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

// Pre-computed magic numbers (deterministic PRNG output, hardcoded to avoid
// expensive trial-and-error search at comptime)
const rook_magic_numbers = [64]u64{
    0x2080002880104000, 0x0004401001482004, 0x1002040100500014, 0x4008000902041018,
    0x40400b8040081214, 0x914006a002140001, 0x0100240906420180, 0x0100010010804322,
    0x1202480040003001, 0x0210291014008008, 0x1080081004200200, 0x5300700018403002,
    0x0000180048040101, 0x0008100ac0808003, 0x00480305001400e2, 0x0000208100024a08,
    0x8490100901008000, 0x000c208828095009, 0x0004129000540041, 0x8400180100480080,
    0x0080200200110054, 0x200161800e000104, 0x000000a002000119, 0x900100a0049002c1,
    0x6214200040044018, 0x5040002020001000, 0x4900180480080580, 0x0401002220040080,
    0x2400029401004220, 0x010099001a040004, 0x2020008400030610, 0x44009806c0048a20,
    0x0000102120080020, 0x0802003802010080, 0x00080082106c0400, 0x00d6020011010008,
    0x1440288002081081, 0x8220400200400100, 0x8000128008410021, 0x3008804600210808,
    0x0040040280022800, 0x80a1024010400808, 0x0810000400900211, 0x9102822009920004,
    0x4840010008301811, 0x0003000800820404, 0x08000b0200004ca1, 0x1000423000e00c01,
    0x0050004021002018, 0x0244080081015024, 0x09d0002000124050, 0x0800020040842009,
    0x01484c0480020700, 0x0000008040221004, 0x00180402b8910c00, 0x200002290cac0200,
    0x0400810410402202, 0x020010204000801d, 0x0110040840902081, 0x0210084200852002,
    0x1088410804106042, 0x2400020428009041, 0x010081020048028c, 0x004000408024110a,
};

const bishop_magic_numbers = [64]u64{
    0x0088200282011402, 0x4080220a22002000, 0x02010044058050c0, 0x8004010222002002,
    0x00401c2100210021, 0x01044480720a25c4, 0x0022001082090d88, 0x8c60401011002000,
    0x0022010a30040081, 0x000429006a140852, 0x0101324083020201, 0x00000040882144c0,
    0x0080102824080000, 0x4080004012400204, 0x0260816008010788, 0x8203c10021002808,
    0x0888004000958414, 0x0800420200424205, 0x7000840800840088, 0x0000210042104102,
    0x915080a808604020, 0x20a1000010021010, 0x00090208240200a0, 0x8800050250040100,
    0x5230402204080ec0, 0x1590002090808108, 0x4cc1298045a06200, 0x0004010100200880,
    0x0801001001004004, 0x4110008000120080, 0x044800a000054214, 0x0020080820622100,
    0x4400201a82220021, 0x3188080824818110, 0x0220420040020012, 0x8048208020880201,
    0x0844008200040104, 0x00b0008b08180303, 0x0129000c08106060, 0x0052008200044948,
    0x3040228941001020, 0x0884800920000180, 0x2200200828011008, 0xc981200221040080,
    0x5000010102002108, 0x0002320200080200, 0x42e80a0080101004, 0x00004102a0200006,
    0x000a002200420000, 0x0050219008200002, 0x1040104808240042, 0x0020000005010040,
    0x0484088086009000, 0x04050c0020990180, 0x204118a011602010, 0x261001209c088070,
    0x5810202429011200, 0x00c10c0300c61000, 0xf501130050101000, 0x0840004051209100,
    0x0520020000814410, 0x2000804008810410, 0x8000288150008048, 0x1004430408014009,
};

// Build a single square's lookup table using a known-good magic number (single pass, no search)
fn buildTable(sq_idx: u6, magic: u64, mask: Bitboard, comptime is_bishop: bool) [if (is_bishop) bishop_table_size else rook_table_size]Bitboard {
    const table_size = if (is_bishop) bishop_table_size else rook_table_size;
    const shift = if (is_bishop) bishop_shift else rook_shift;
    var table = [_]Bitboard{0} ** table_size;

    // Enumerate all subsets of mask (carry-rippler)
    var occ: Bitboard = 0;
    while (true) {
        const attacks_val = if (is_bishop) bishopAttacksSlow(sq_idx, occ) else rookAttacksSlow(sq_idx, occ);
        const index = @as(usize, (occ *% magic) >> shift);
        if (table[index] != 0 and table[index] != attacks_val) {
            unreachable; // destructive collision — bad magic number
        }
        table[index] = attacks_val;

        occ = (occ -% mask) & mask;
        if (occ == 0) break;
    }

    return table;
}

// Precomputed masks
const rook_masks: [64]Bitboard = blk: {
    var table: [64]Bitboard = undefined;
    for (0..64) |sq| table[sq] = rookMask(@intCast(sq));
    break :blk table;
};

const bishop_masks: [64]Bitboard = blk: {
    var table: [64]Bitboard = undefined;
    for (0..64) |sq| table[sq] = bishopMask(@intCast(sq));
    break :blk table;
};

// Precomputed lookup tables (built at comptime using hardcoded magic numbers)
const rook_table: [64][rook_table_size]Bitboard = blk: {
    @setEvalBranchQuota(10_000_000);
    var table: [64][rook_table_size]Bitboard = undefined;
    for (0..64) |sq| {
        table[sq] = buildTable(@intCast(sq), rook_magic_numbers[sq], rook_masks[sq], false);
    }
    break :blk table;
};

const bishop_table: [64][bishop_table_size]Bitboard = blk: {
    @setEvalBranchQuota(10_000_000);
    var table: [64][bishop_table_size]Bitboard = undefined;
    for (0..64) |sq| {
        table[sq] = buildTable(@intCast(sq), bishop_magic_numbers[sq], bishop_masks[sq], true);
    }
    break :blk table;
};

pub inline fn getRookAttacks(sq: u6, occupancy: Bitboard) Bitboard {
    const masked = occupancy & rook_masks[sq];
    const index = (masked *% rook_magic_numbers[sq]) >> rook_shift;
    return rook_table[sq][index];
}

pub inline fn getBishopAttacks(sq: u6, occupancy: Bitboard) Bitboard {
    const masked = occupancy & bishop_masks[sq];
    const index = (masked *% bishop_magic_numbers[sq]) >> bishop_shift;
    return bishop_table[sq][index];
}

test "slow attack functions" {
    const e4_bishop_slow = bishopAttacksSlow(28, 0);
    try std.testing.expect(e4_bishop_slow & Square.b1.toBitboard() != 0);
    try std.testing.expect(e4_bishop_slow & Square.h1.toBitboard() != 0);
    try std.testing.expect(e4_bishop_slow & Square.a8.toBitboard() != 0);
    try std.testing.expect(e4_bishop_slow & Square.h7.toBitboard() != 0);
}

test "magic bitboards lookup" {
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
