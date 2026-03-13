const std = @import("std");
const Square = @import("square.zig").Square;
const PieceType = @import("types.zig").PieceType;

pub const MoveFlags = enum(u4) {
    quiet = 0,
    double_pawn_push = 1,
    king_castle = 2,
    queen_castle = 3,
    capture = 4,
    ep_capture = 5,
    // 6, 7 unused
    knight_promotion = 8,
    bishop_promotion = 9,
    rook_promotion = 10,
    queen_promotion = 11,
    knight_promo_capture = 12,
    bishop_promo_capture = 13,
    rook_promo_capture = 14,
    queen_promo_capture = 15,

    pub fn isCapture(self: MoveFlags) bool {
        return (@intFromEnum(self) & 4) != 0;
    }

    pub fn isPromotion(self: MoveFlags) bool {
        return (@intFromEnum(self) & 8) != 0;
    }

    pub fn promotionPieceType(self: MoveFlags) ?PieceType {
        if (!self.isPromotion()) return null;
        return switch (self) {
            .knight_promotion, .knight_promo_capture => .knight,
            .bishop_promotion, .bishop_promo_capture => .bishop,
            .rook_promotion, .rook_promo_capture => .rook,
            .queen_promotion, .queen_promo_capture => .queen,
            else => null,
        };
    }
};

pub const Move = packed struct(u16) {
    from: u6,
    to: u6,
    flags: MoveFlags,

    pub fn toLongAlgebraic(self: Move) [5]u8 {
        const from_sq: Square = @enumFromInt(self.from);
        const to_sq: Square = @enumFromInt(self.to);
        const f = from_sq.toString();
        const t = to_sq.toString();
        var result: [5]u8 = .{ f[0], f[1], t[0], t[1], 0 };
        if (self.flags.isPromotion()) {
            result[4] = switch (self.flags.promotionPieceType().?) {
                .knight => 'n',
                .bishop => 'b',
                .rook => 'r',
                .queen => 'q',
                else => 0,
            };
        }
        return result;
    }

};

pub const MoveList = struct {
    moves: [256]Move,
    count: usize,

    pub fn init() MoveList {
        return .{
            .moves = undefined,
            .count = 0,
        };
    }

    pub fn add(self: *MoveList, move: Move) void {
        self.moves[self.count] = move;
        self.count += 1;
    }

    pub fn slice(self: *const MoveList) []const Move {
        return self.moves[0..self.count];
    }
};

test "move flags" {
    try std.testing.expect(MoveFlags.capture.isCapture());
    try std.testing.expect(MoveFlags.ep_capture.isCapture());
    try std.testing.expect(!MoveFlags.quiet.isCapture());
    try std.testing.expect(MoveFlags.queen_promotion.isPromotion());
    try std.testing.expect(MoveFlags.knight_promo_capture.isPromotion());
    try std.testing.expect(!MoveFlags.quiet.isPromotion());
}
