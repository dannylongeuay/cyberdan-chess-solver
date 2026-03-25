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
- UCI (Universal Chess Interface) protocol for integration with chess GUIs
- Lichess bot mode for automated online play
- HTTP API server for FEN validation, legal move queries, move submission, and best-move search with CORS support

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
zig build run -- uci                  # start UCI protocol mode
zig build run -- lichess              # start Lichess bot mode
zig build run -- serve                # start HTTP API server
zig build run -- serve --port 3000    # start on custom port
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

### UCI

The engine supports the [UCI](https://www.chessprogramming.org/UCI) (Universal Chess Interface) protocol, allowing it to be used with any UCI-compatible GUI such as Arena, CuteChess, or Banksia.

```sh
zig build run -- uci
```

The engine identifies as **Cyberdan** by **Daniel** and supports the following UCI commands:

| Command | Description |
|---------|-------------|
| `uci` | Identify the engine and list options |
| `isready` | Synchronization ping (responds `readyok`) |
| `ucinewgame` | Reset the engine state for a new game |
| `position startpos [moves ...]` | Set the starting position, optionally with moves |
| `position fen <fen> [moves ...]` | Set a position from a FEN string, optionally with moves |
| `go depth <n>` | Search to a fixed depth |
| `go movetime <ms>` | Search for a fixed time in milliseconds |
| `go wtime/btime/winc/binc/movestogo` | Search with clock-based time management |
| `go infinite` | Search until `stop` is sent |
| `stop` | Stop the current search and return the best move found |
| `quit` | Exit the engine |

When clock information is provided (`wtime`/`btime`), the engine automatically allocates time based on remaining clock and increment values, with a safety margin to avoid flagging.

### Lichess Bot

Challenge the bot [here](https://lichess.org/?user=cyberdan-chess#friend)

The engine can run as a [Lichess bot](https://lichess.org/api#tag/Bot), connecting to Lichess to stream events, accept challenges, and play games automatically.

**Prerequisites:** A Lichess bot account and a personal API token with the `bot:play` scope. You can create a token from your Lichess account settings.

```sh
LICHESS_TOKEN=lip_xxx zig build run -- lichess
```

**Challenge acceptance:** The bot accepts challenges that are **unrated**, **standard** variant, and **bullet/blitz/rapid** time controls. It plays one game at a time and declines challenges while a game is in progress.

**Behaviors:**

- Sends "Good luck, have fun!" in chat at the start of each game
- Uses the opening book when a book move is available
- Automatically declines draw and takeback offers from the opponent
- Claims victory when the opponent disconnects
- Auto-reconnects to the event stream on connection errors (5-second backoff)

**Time management:** The bot allocates time from the remaining clock (`time / 30 + increment * 3/4`) with a safety margin to avoid flagging. Falls back to 10 seconds per move if no clock info is provided.

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

### Serve

Start the HTTP API server:

```sh
zig build run -- serve              # listen on 0.0.0.0:8080 (default)
zig build run -- serve --port 3000  # listen on a custom port
```

#### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check |
| `POST` | `/validmoves` | Get all legal moves for a position |
| `POST` | `/submitmove` | Apply a move and return the resulting position |
| `POST` | `/bestmove` | Find the best move for a position |
| `POST` | `/submitbestmove` | Find and play the best move, returning the new position |
| `OPTIONS` | `*` | CORS preflight |

#### GET /health

Returns a simple health check.

**Response:**
```json
{"status": "ok"}
```

#### POST /validmoves

Returns all legal moves for a given FEN position along with game status.

**Request body:**
```json
{"fen": "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"}
```

**Response body:**
```json
{
  "fen": "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",
  "side_to_move": "black",
  "status": "ongoing",
  "move_count": 20,
  "moves": [
    {
      "uci": "b8a6",
      "san": "Na6",
      "from": "b8",
      "to": "a6",
      "capture": false,
      "promotion": null,
      "castling": false,
      "check": false
    }
  ]
}
```

The `status` field is one of: `ongoing`, `checkmate`, `stalemate`, `fifty_move_rule`, `insufficient_material`.

The `promotion` field is `null` or one of: `queen`, `rook`, `bishop`, `knight`.

#### POST /submitmove

Apply a move (in UCI or SAN notation) and return the resulting position.

**Request body:**
```json
{"fen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", "move": "e2e4"}
```

**Response body:**
```json
{
  "uci": "e2e4",
  "san": "e4",
  "from": "e2",
  "to": "e4",
  "fen": "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",
  "status": "ongoing",
  "side_to_move": "black",
  "move_count": 20,
  "moves": [
    {
      "uci": "b8a6",
      "san": "Na6",
      "from": "b8",
      "to": "a6",
      "capture": false,
      "promotion": null,
      "castling": false,
      "check": false
    }
  ]
}
```

The response includes all legal moves for the resulting position, matching the format from `/validmoves`. This eliminates the need for a separate `/validmoves` call after each move.

#### POST /bestmove

Find the best move for a given position using iterative deepening search with alpha-beta pruning.

**Request body:**
```json
{"fen": "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1", "depth": 10, "timeout_ms": 2000}
```

Both `depth` and `timeout_ms` are optional. Search behavior depends on which fields are provided:

| Fields provided | Behavior |
|-----------------|----------|
| `timeout_ms` | Timed search; `depth` acts as a cap (default 100) |
| `depth` only | Fixed-depth search, capped at 20 |
| Neither | Default 5-second timeout |

**Response body:**
```json
{
  "fen": "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",
  "depth": 10,
  "uci": "c7c5",
  "san": "c5",
  "from": "c7",
  "to": "c5",
  "score": 15,
  "nodes": 482370,
  "source": "search"
}
```

`uci`, `san`, `from`, and `to` are `null` when no legal moves exist (checkmate/stalemate).

The `source` field is `"book"` when the move came from the opening book (with `depth`, `score`, and `nodes` all `0`), or `"search"` when it came from the search algorithm.

#### POST /submitbestmove

Find the best move for a position, play it, and return the resulting position with all legal moves.

**Request body:**
```json
{"fen": "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1", "depth": 10, "timeout_ms": 2000}
```

Search options behave the same as [`/bestmove`](#post-bestmove).

**Response body:**
```json
{
  "uci": "c7c5",
  "san": "c5",
  "from": "c7",
  "to": "c5",
  "fen": "rnbqkbnr/pppppppp/8/8/4P3/4p3/PPPP1PPP/RNBQKBNR w KQkq c6 0 2",
  "status": "ongoing",
  "side_to_move": "white",
  "move_count": 29,
  "moves": [
    {
      "uci": "b1a3",
      "san": "Na3",
      "from": "b1",
      "to": "a3",
      "capture": false,
      "promotion": null,
      "castling": false,
      "check": false
    }
  ],
  "depth": 10,
  "score": -15,
  "nodes": 482370,
  "source": "search"
}
```

The response combines the move result (same structure as `/submitmove`) with search metadata (`depth`, `score`, `nodes`, `source`). Returns a `no_moves` error if the position has no legal moves (checkmate/stalemate). See [`/bestmove`](#post-bestmove) for details on the `source` field.

#### Error Responses

All errors return JSON with an `error` code and human-readable `message`:

```json
{"error": "invalid_fen", "message": "The provided FEN string is invalid"}
```

| Error Code | HTTP Status | Description |
|------------|-------------|-------------|
| `invalid_request` | 400 | Failed to read request body |
| `invalid_json` | 400 | Request body is not valid JSON |
| `invalid_fen` | 400 | The FEN string could not be parsed |
| `invalid_move` | 400 | The move is not legal in the given position |
| `no_moves` | 400 | No legal moves available in this position |
| `not_found` | 404 | Unknown endpoint |
| `method_not_allowed` | 405 | Wrong HTTP method for the endpoint |

#### CORS

All responses include CORS headers. The default allowed origin is `https://chess.cyberdan.dev`. Set the `CORS_PERMISSIVE=1` environment variable to allow all origins (`*`). The server handles `OPTIONS` preflight requests with `Access-Control-Allow-Methods: GET, POST, OPTIONS` and `Access-Control-Allow-Headers: Content-Type`.

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

### Search

The engine uses **iterative deepening** with timeout support, progressively searching deeper until time runs out or a maximum depth is reached. Each iteration uses **negamax with alpha-beta pruning** enhanced by several techniques:

- **Transposition table** &mdash; hash-indexed cache storing exact, upper, and lower bound scores along with the best move. Uses age-based replacement (stale entries from previous searches are overwritten first) and adjusts mate scores by ply distance for correct storage/retrieval across different tree depths
- **Null move pruning** &mdash; skips a turn and searches at reduced depth (`r = 2 + depth/6`) with a zero-window to detect positions where the opponent can't improve even with a free move. Disabled when in check or in pawn endgames (high zugzwang risk)
- **Late move reductions (LMR)** &mdash; searches later quiet moves at reduced depth using a log-based reduction table (`0.75 + ln(depth) * ln(moveIndex) / 2.25`). Applied at depth >= 3 after the first 3 moves, excluding captures, promotions, and moves that give check. Re-searches at full depth if the reduced search improves alpha
- **Quiescence search** &mdash; extends the search at leaf nodes by examining captures only (with stand-pat pruning) to avoid the horizon effect. When in check, searches all evasions and detects checkmate
- **Aspiration windows** &mdash; iterative deepening uses a narrow initial window (&plusmn;25 cp) that expands exponentially on fail-high/fail-low, falling back to a full window if delta exceeds &plusmn;500 cp
- **Principal variation search (PVS)** &mdash; first move searched with full window; subsequent moves use a null window [&alpha;, &alpha;+1] and re-search with full window only if they improve alpha
- **Check extensions** &mdash; extends search by 1 ply when a move gives check, limited to `ply < 2 * nominal_depth` to prevent explosion
- **Reverse futility pruning** &mdash; at depth &le; 6, prunes if `static_eval - 80 * depth >= beta` (not in check)
- **Futility pruning** &mdash; at depths 1&ndash;3, skips quiet non-checking moves if `static_eval + margin < alpha` (margins: 200/350/500 cp by depth)
- **Static exchange evaluation (SEE)** &mdash; full capture-sequence evaluation used for move ordering (winning captures scored above killers, losing captures below) and pruning (captures with `SEE < -50 * depth` skipped in main search; losing captures skipped in quiescence)
- **Delta pruning** &mdash; in quiescence, skips captures where `stand_pat + captured_piece_value + 200 < alpha` (unless promotion)
- **Move ordering**: TT move > captures (MVV-LVA, SEE-partitioned) > killer moves (2 per ply) > history heuristic. History scores use gravity clamping (`bonus - |entry| * bonus / max`), are aged (halved) between iterations, and quiet moves that fail to cause a beta cutoff receive a malus

### Evaluation

The engine uses **tapered evaluation**, interpolating between middlegame (MG) and endgame (EG) scores based on remaining material:

- **Phase calculation** &mdash; each piece type has a phase weight (knight/bishop = 1, rook = 2, queen = 4; max phase = 24). The final score blends MG and EG proportionally: `(mg * phase + eg * (24 - phase)) / 24`
- **Material values** &mdash; separate MG and EG values per piece type. Pawns are worth more in endgames (120 vs 100 centipawns); minor pieces slightly less (300/310 vs 320/330)
- **Piece-square tables** &mdash; separate 64-entry MG and EG tables for all six piece types. Key differences: MG king tables reward castled positions while EG tables reward centralization; EG pawn tables strongly reward advancement. Black uses vertically mirrored tables (`sq ^ 56`)
- **Pawn structure** &mdash; doubled pawns (&minus;10 MG, &minus;15 EG per extra pawn per file), isolated pawns (&minus;15 MG, &minus;20 EG), and passed pawns with rank-scaled bonuses (up to +100 MG / +200 EG on the 7th rank)
- **Mobility** &mdash; per-piece bonuses for knights, bishops, rooks, and queens based on safe squares above a baseline (e.g. knight baseline 4, bishop 7, rook 7, queen 14), excluding squares attacked by enemy pawns
- **King safety** &mdash; pawn shield bonus (+10 per friendly pawn ahead of king) and open file penalty (&minus;15 per open file near king), evaluated in middlegame only
- **Bishop pair** &mdash; +30 MG / +45 EG bonus when a side has two or more bishops

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
| `eval.zig` | Tapered evaluation, material values, piece-square tables |
| `search.zig` | Iterative deepening, alpha-beta, NMP, LMR, move ordering |
| `tt.zig` | Transposition table with age-based replacement |
| `book.zig` | Opening book lookup |
| `opening_parser.zig` | Opening book data parsing |
| `random.zig` | Random move selection (for computer opponent) |
| `uci.zig` | UCI protocol handler for GUI integration |
| `lichess.zig` | Lichess bot: event streaming, challenge handling, game play |
| `server.zig` | HTTP API server with move validation and game state endpoints |
