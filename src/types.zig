pub const Color = enum(u1) {
    white = 0,
    black = 1,

    pub fn opponent(self: Color) Color {
        return @enumFromInt(@intFromEnum(self) ^ 1);
    }
};

pub const PieceType = enum(u3) {
    pawn = 0,
    knight = 1,
    bishop = 2,
    rook = 3,
    queen = 4,
    king = 5,
};

pub const Piece = struct {
    color: Color,
    piece_type: PieceType,
};

pub const CastlingRights = packed struct(u4) {
    white_king: bool = false,
    white_queen: bool = false,
    black_king: bool = false,
    black_queen: bool = false,

    pub const none: CastlingRights = .{};
    pub const all: CastlingRights = .{
        .white_king = true,
        .white_queen = true,
        .black_king = true,
        .black_queen = true,
    };

    pub fn toInt(self: CastlingRights) u4 {
        return @bitCast(self);
    }
};
