# cyberdan-chess-solver

A bitboard-based chess engine written in Zig. Supports interactive play, full legal move generation, and perft testing.

## Features

- Full legal move generation including castling, en passant, and promotions
- Interactive play: Human vs Human and Human vs Computer modes
- Perft testing with optional per-move divide breakdown
- FEN import/export for arbitrary positions
- SAN (Standard Algebraic Notation) and long algebraic move input
- Game-ending detection: checkmate, stalemate, threefold repetition, fifty-move rule, insufficient material
- Zobrist hashing with incremental updates for fast position comparison

## Getting Started

### Prerequisites

Either:
- [Nix](https://nixos.org/) with flakes enabled (recommended), or
- [Zig](https://ziglang.org/) 0.15.x installed manually

### Setup

```sh
# With Nix (provides zig, zls, lldb)
nix develop

# Or verify your Zig version
zig version  # should be 0.15.x
```

### Build & Run

```sh
zig build run                         # build and launch (play mode, default)
zig build test                        # run all tests
zig build test-perft                  # run deep perft tests
zig build run -Doptimize=ReleaseFast  # optimized build
```

## Usage

### Play

Start an interactive game:

```sh
# Human vs Human (default)
zig build run

# Human vs Computer
zig build run -- play --mode hvc

# Start from a specific position
zig build run -- play --fen "r1bqkbnr/pppppppp/2n5/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 1 2"
```

Moves can be entered in long algebraic (`e2e4`, `e7e8q`) or SAN (`Nf3`, `O-O`, `exd5`).

In-game commands:

| Command | Description |
|---------|-------------|
| `moves` | List all legal moves |
| `fen`   | Print the current FEN string |
| `undo`  | Undo the last move (undoes both moves in HvC mode) |
| `quit`  | Exit the game |

### Perft

Run a [perft](https://www.chessprogramming.org/Perft) node count to verify move generation correctness:

```sh
# Perft depth 5 from starting position
zig build run -- perft 5

# Perft with per-move breakdown
zig build run -- perft 4 --divide

# Perft from a custom position
zig build run -- perft 3 --fen "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -"
```

## Architecture

### Board Representation

The board uses a [LERF](https://www.chessprogramming.org/Square_Mapping_Considerations#Little-Endian_Rank-File_Mapping)
(Little-Endian Rank-File) bitboard layout where a1=0 and h8=63. The `Board` struct maintains:

- `pieces[2][6]` &mdash; one `u64` bitboard per color per piece type
- `occupancy[2]` &mdash; per-color union bitboards
- `all_occupancy` &mdash; full-board union bitboard
- Side to move, castling rights (`packed struct(u4)`), en passant square, halfmove clock, fullmove number

### Magic Bitboards

Sliding piece (bishop/rook) attack generation uses [magic bitboards](https://www.chessprogramming.org/Magic_Bitboards).
Magic numbers are hardcoded in `magics.zig` and the full lookup tables (64 squares x up to 4096 
occupancy patterns) are built at comptime in a single pass. No runtime 
initialization is needed.

### Move Generation

Moves are generated in two stages:

1. **Pseudo-legal generation** &mdash; produces all candidate moves (piece moves, pawn pushes/captures, castling, en passant, promotions)
2. **Legality filtering** &mdash; each candidate move is played on the board and rejected if it leaves the king in check

### Zobrist Hashing

Every board position has a `u64` hash composed of XOR'd keys for:

- Each piece on each square (`piece_keys[color][piece_type][square]`)
- Castling rights (`castling_keys[16]`)
- En passant file (`en_passant_keys[8]`)
- Side to move (`side_key`)

The hash is updated incrementally during `makeMove`/`unmakeMove`, avoiding full 
recomputation. All Zobrist keys are generated at comptime via a seeded 
xorshift64 PRNG.

### Game State

`GameState` wraps `Board` with a 1024-entry history array tracking each move's hash, move, and undo info. This enables:

- **Threefold repetition** detection by comparing Zobrist hashes (only checking same-side positions back to the last irreversible move)
- **Fifty-move rule** via the halfmove clock
- **Insufficient material** detection (K vs K, K+B vs K, K+N vs K, K+B vs K+B same color)
- **Move undo** by restoring captured pieces, castling rights, en passant, and hash from `UndoInfo`

## Project Structure

| File | Responsibility |
|------|---------------|
| `main.zig` | CLI entry point, argument parsing, game loop |
| `types.zig` | Core types: `Color`, `PieceType`, `Piece`, `CastlingRights` |
| `square.zig` | Square representation and coordinate conversions |
| `bitboard.zig` | Bitboard operations (popcount, LSB, shifts, masks) |
| `attacks.zig` | Non-sliding piece attack tables (pawn, knight, king) |
| `magics.zig` | Magic numbers and comptime sliding attack lookup tables |
| `board.zig` | Board state, FEN parsing, Zobrist hashing, make/unmake |
| `moves.zig` | Move encoding (`Move` struct with from/to/flags) |
| `movegen.zig` | Pseudo-legal and legal move generation |
| `perft.zig` | Perft and divide testing |
| `game.zig` | Game state, history, draw/checkmate detection |
| `display.zig` | Board display for terminal output |
| `notation.zig` | SAN and long algebraic notation parsing/formatting |
| `random.zig` | Random move selection (for computer opponent) |
