# select-mate.sh

`select-mate.sh` is a terminal chess game backed by SQLite. It uses [`gum`](https://github.com/charmbracelet/gum) for the interactive picker UI, stores game state on disk, supports named identities, and can point at a board/database URI from stdin. The fun part is that two players can open the same `game.db` from different terminals, or even different machines, as long as they both see the same shared filesystem path.

## Requirements

- `bash`
- `sqlite3`
- `curl` if you want to run it directly from `https://select-mate.sh`
- `gum` for the richer picker UI, optional

On macOS with Homebrew:

```bash
brew install sqlite gum
```

If you skip `gum`, the game falls back to plain terminal prompts and numbered menus.

## Quick Start

Run the hosted script in one shot:

```bash
curl -fsSL https://select-mate.sh | bash
```

The URL should serve the actual released `select-mate.sh` script. When launched this way, the script reattaches to your terminal for prompts, asks for your identity, and then lets you choose between a multiplayer game and a local-only game.

Make sure the script is executable:

```bash
chmod +x ./select-mate.sh
```

Start or resume the active game:

```bash
./select-mate.sh
```

Set a default identity in standard XDG config:

```bash
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}"
printf 'identity=alice\n' > "${XDG_CONFIG_HOME:-$HOME/.config}/select-mate.conf"
```

Print the currently selected identity:

```bash
./select-mate.sh --whoami
```

Start a fresh multiplayer game:

```bash
./select-mate.sh --new
```

Start a fresh local game where one identity controls both sides:

```bash
./select-mate.sh --local
```

Show the move history for the active game:

```bash
./select-mate.sh --moves
```

Target a specific board/database by piping a URI on stdin:

```bash
printf 'file:/tmp/select-mate.db?mode=rwc\n' | ./select-mate.sh --whoami
```

Show CLI help:

```bash
./select-mate.sh --help
```

If you are hosting the curl entrypoint yourself, serve the exact released `select-mate.sh` script at `https://select-mate.sh`.

For a shared live-test setup with two terminals:

```bash
make alice
make bob
```

## Identity Selection

Identity comes from the first available source in this order:

- `--identity NAME`
- `${XDG_CONFIG_HOME:-$HOME/.config}/select-mate.conf`
- the selected identity already remembered in the active board database

When an identity is provided explicitly or via config, it is used for the current client session without rewriting the board's remembered identity. If you use the in-app identity picker, that choice is remembered in the board database and reused on the next launch when no `--identity` or config override is supplied.

Config format is a single key/value entry:

```bash
identity=alice
```

If you do not pipe a board URI on stdin, game state is stored next to the config file by default:

```bash
${XDG_CONFIG_HOME:-$HOME/.config}/game.db
```

If you want an isolated game state for testing, point `XDG_CONFIG_HOME` somewhere else:

```bash
XDG_CONFIG_HOME="$(mktemp -d)" ./select-mate.sh
```

## Multiplayer

Multiplayer is board/database based: Alice and Bob can both point at the same SQLite `game.db` and watch turn ownership switch live.

The main flow to show off is a shared database on a network-mounted folder. This is still SQLite, not a separate server process, so both machines need the same shared filesystem and working SQLite file locks.

Example shared location:

```bash
/Volumes/chess-share/select-mate/game.db
```

Alice on one machine:

```bash
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}"
printf 'identity=alice\n' > "${XDG_CONFIG_HOME:-$HOME/.config}/select-mate.conf"
printf 'file:/Volumes/chess-share/select-mate/game.db?mode=rwc\n' | ./select-mate.sh --new
```

Bob on another machine with the same network share mounted:

```bash
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}"
printf 'identity=bob\n' > "${XDG_CONFIG_HOME:-$HOME/.config}/select-mate.conf"
printf 'file:/Volumes/chess-share/select-mate/game.db?mode=rwc\n' | ./select-mate.sh
```

What that looks like in practice:

- Alice starts a new multiplayer game and assigns `alice` / `bob`.
- Bob opens the same shared `game.db` and immediately lands in the same match.
- The side to move gets the writable action list.
- The other player sees a read-only waiting screen, but can refresh and inspect moves.
- After each move, the other terminal can refresh and take over from the same shared board state.
- You can keep both terminals open the whole time, which makes the turn handoff very visible.

If you want to demo the same idea on one machine first, the repo includes a `Makefile` that pins both players to the same board URI under `/tmp/select-mate-live`:

```bash
make alice
make bob
```

Recommended live-test flow:

- Run `make alice` in one terminal.
- Run `make bob` in a second terminal.
- Start a new multiplayer game from one side and assign `alice` / `bob`.
- Keep both terminals open to see writable vs read-only mode change live after each move.

Helper targets:

- `make test-prepare` creates the shared board/config layout.
- `make test-board-uri` prints the shared board URI.
- `make test-reset` removes the shared `/tmp/select-mate-live` test area.

For multiplayer with separate config homes or identities, pipe the shared board URI on stdin:

```bash
printf 'file:/tmp/select-mate-shared/game.db?mode=rwc\n' | ./select-mate.sh --identity alice
printf 'file:/tmp/select-mate-shared/game.db?mode=rwc\n' | ./select-mate.sh --identity bob
```

Recommended flow:

- One player starts the game with `./select-mate.sh --new` and assigns white/black identities.
- Both players open the same board path.
- Only the identity assigned to the side to move gets write actions.
- The other identity sees a read-only waiting view and can still refresh and inspect moves.
- Choose the player identity up front with `--identity NAME` before joining a multiplayer board.

Current limitations:

- Avoid trying to make moves at the same time from two terminals.
- The stdin contract is one raw board URI line, not JSON or key/value input.
