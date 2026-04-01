#!/usr/bin/env bash

set -euo pipefail

APP_NAME="select-mate"
APP_TITLE="select-mate.sh"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}"
APP_STATE_DIR="$STATE_ROOT/$APP_NAME"
DEFAULT_DB_PATH="$APP_STATE_DIR/game.db"
DB_PATH="$DEFAULT_DB_PATH"
CONFIG_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/select-mate.conf"
SESSION_IDENTITY_ID=""
SESSION_IDENTITY_NAME=""

usage() {
  cat <<'EOF'
Usage: select-mate.sh [--identity NAME] [--new | --local | --moves | --whoami | --help]

Commands:
  --identity NAME  Select or create an identity before running the command.
  --new            Start a fresh multiplayer game after confirmation.
  --local          Start a fresh local-only game using the selected identity for both sides.
  --moves          Show move history for the active game and exit.
  --whoami         Print the currently selected identity and exit.
  --help           Show this help text and exit.

Startup defaults:
  - Identity config: ${XDG_CONFIG_HOME:-$HOME/.config}/select-mate.conf
    Example: identity=alice
  - Board URI from stdin when stdin is not a TTY
    Example: printf 'file:/tmp/select-mate.db?mode=rwc\n' | ./select-mate.sh --whoami
EOF
}

sql_quote() {
  printf "%s" "$1" | sed "s/'/''/g"
}

trim_string() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

dbq() {
  sqlite3 -batch -noheader "$DB_PATH" "$1"
}

dbqt() {
  sqlite3 -batch -noheader -tabs "$DB_PATH" "$1"
}

require_sqlite() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    printf 'sqlite3 is required.\n' >&2
    exit 1
  fi
}

require_gum() {
  if ! command -v gum >/dev/null 2>&1; then
    printf 'gum is required to play interactively. Install it from https://github.com/charmbracelet/gum.\n' >&2
    exit 1
  fi
}

has_full_tty() {
  [[ -t 0 && -t 1 && "${TERM:-}" != "dumb" ]]
}

clear_screen() {
  if has_full_tty && command -v clear >/dev/null 2>&1; then
    clear || true
  fi
}

show_in_pager() {
  local content=$1

  # `less` behaves better than `gum pager` in tight terminals and falls back
  # cleanly when the command is used from pipes or automation.
  if has_full_tty && command -v less >/dev/null 2>&1; then
    less -RFX <<<"$content"
    return 0
  fi

  printf '%s\n' "$content"
}

db_parent_dir() {
  local target=$1
  local path_without_query

  if [[ "$target" == file:* ]]; then
    path_without_query=${target#file:}
    path_without_query=${path_without_query%%\?*}
    if [[ -z "$path_without_query" || "$path_without_query" == ':memory:' ]]; then
      return 1
    fi
    dirname "$path_without_query"
    return 0
  fi

  dirname "$target"
}

ensure_state_dir() {
  local parent_dir
  if parent_dir=$(db_parent_dir "$DB_PATH"); then
    mkdir -p "$parent_dir"
  fi
}

init_db() {
  ensure_state_dir
  if [[ "$DB_PATH" == file:* ]]; then
    sqlite3 "$DB_PATH" <<'SQL'
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS games (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  status TEXT NOT NULL DEFAULT 'active',
  turn TEXT NOT NULL CHECK (turn IN ('white', 'black')),
  winner TEXT,
  note TEXT,
  en_passant_file INTEGER,
  en_passant_rank INTEGER,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS pieces (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  game_id INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
  file INTEGER NOT NULL CHECK (file BETWEEN 1 AND 8),
  rank INTEGER NOT NULL CHECK (rank BETWEEN 1 AND 8),
  piece TEXT NOT NULL,
  color TEXT NOT NULL CHECK (color IN ('white', 'black')),
  kind TEXT NOT NULL CHECK (kind IN ('king', 'queen', 'rook', 'bishop', 'knight', 'pawn')),
  has_moved INTEGER NOT NULL DEFAULT 0 CHECK (has_moved IN (0, 1)),
  UNIQUE (game_id, file, rank)
);

CREATE INDEX IF NOT EXISTS idx_pieces_game_color ON pieces(game_id, color);
CREATE INDEX IF NOT EXISTS idx_pieces_game_square ON pieces(game_id, file, rank);

CREATE TABLE IF NOT EXISTS moves (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  game_id INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
  ply INTEGER NOT NULL,
  from_sq TEXT NOT NULL,
  to_sq TEXT NOT NULL,
  piece TEXT NOT NULL,
  capture TEXT,
  promotion TEXT,
  notation TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (game_id, ply)
);

CREATE INDEX IF NOT EXISTS idx_moves_game_ply ON moves(game_id, ply);

CREATE TABLE IF NOT EXISTS identities (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_used_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS game_players (
  game_id INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
  color TEXT NOT NULL CHECK (color IN ('white', 'black')),
  identity_id INTEGER NOT NULL REFERENCES identities(id) ON DELETE CASCADE,
  PRIMARY KEY (game_id, color)
);

CREATE TABLE IF NOT EXISTS app_state (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_identities_last_used ON identities(last_used_at DESC, name ASC);
CREATE INDEX IF NOT EXISTS idx_game_players_identity ON game_players(identity_id);
SQL
    return
  fi

  sqlite3 "$DB_PATH" <<'SQL'
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS games (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  status TEXT NOT NULL DEFAULT 'active',
  turn TEXT NOT NULL CHECK (turn IN ('white', 'black')),
  winner TEXT,
  note TEXT,
  en_passant_file INTEGER,
  en_passant_rank INTEGER,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS pieces (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  game_id INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
  file INTEGER NOT NULL CHECK (file BETWEEN 1 AND 8),
  rank INTEGER NOT NULL CHECK (rank BETWEEN 1 AND 8),
  piece TEXT NOT NULL,
  color TEXT NOT NULL CHECK (color IN ('white', 'black')),
  kind TEXT NOT NULL CHECK (kind IN ('king', 'queen', 'rook', 'bishop', 'knight', 'pawn')),
  has_moved INTEGER NOT NULL DEFAULT 0 CHECK (has_moved IN (0, 1)),
  UNIQUE (game_id, file, rank)
);

CREATE INDEX IF NOT EXISTS idx_pieces_game_color ON pieces(game_id, color);
CREATE INDEX IF NOT EXISTS idx_pieces_game_square ON pieces(game_id, file, rank);

CREATE TABLE IF NOT EXISTS moves (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  game_id INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
  ply INTEGER NOT NULL,
  from_sq TEXT NOT NULL,
  to_sq TEXT NOT NULL,
  piece TEXT NOT NULL,
  capture TEXT,
  promotion TEXT,
  notation TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (game_id, ply)
);

CREATE INDEX IF NOT EXISTS idx_moves_game_ply ON moves(game_id, ply);

CREATE TABLE IF NOT EXISTS identities (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_used_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS game_players (
  game_id INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
  color TEXT NOT NULL CHECK (color IN ('white', 'black')),
  identity_id INTEGER NOT NULL REFERENCES identities(id) ON DELETE CASCADE,
  PRIMARY KEY (game_id, color)
);

CREATE TABLE IF NOT EXISTS app_state (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_identities_last_used ON identities(last_used_at DESC, name ASC);
CREATE INDEX IF NOT EXISTS idx_game_players_identity ON game_players(identity_id);
SQL
}

piece_symbol() {
  local color=$1
  local kind=$2
  case "$color:$kind" in
    white:king) printf 'K' ;;
    white:queen) printf 'Q' ;;
    white:rook) printf 'R' ;;
    white:bishop) printf 'B' ;;
    white:knight) printf 'N' ;;
    white:pawn) printf 'P' ;;
    black:king) printf 'k' ;;
    black:queen) printf 'q' ;;
    black:rook) printf 'r' ;;
    black:bishop) printf 'b' ;;
    black:knight) printf 'n' ;;
    black:pawn) printf 'p' ;;
    *) printf '?' ;;
  esac
}

opposite_color() {
  if [[ "$1" == "white" ]]; then
    printf 'black'
  else
    printf 'white'
  fi
}

file_to_letter() {
  case "$1" in
    1) printf 'a' ;;
    2) printf 'b' ;;
    3) printf 'c' ;;
    4) printf 'd' ;;
    5) printf 'e' ;;
    6) printf 'f' ;;
    7) printf 'g' ;;
    8) printf 'h' ;;
    *) return 1 ;;
  esac
}

letter_to_file() {
  case "$1" in
    a|A) printf '1' ;;
    b|B) printf '2' ;;
    c|C) printf '3' ;;
    d|D) printf '4' ;;
    e|E) printf '5' ;;
    f|F) printf '6' ;;
    g|G) printf '7' ;;
    h|H) printf '8' ;;
    *) return 1 ;;
  esac
}

coords_to_square() {
  printf '%s%s' "$(file_to_letter "$1")" "$2"
}

square_to_coords() {
  local square=$1
  local file_letter rank
  file_letter=${square%${square#?}}
  rank=${square#?}
  printf '%s|%s' "$(letter_to_file "$file_letter")" "$rank"
}

is_on_board() {
  local file=$1
  local rank=$2
  [[ "$file" -ge 1 && "$file" -le 8 && "$rank" -ge 1 && "$rank" -le 8 ]]
}

current_game_id() {
  dbq "SELECT id FROM games WHERE status = 'active' ORDER BY updated_at DESC, id DESC LIMIT 1;"
}

game_turn() {
  dbq "SELECT turn FROM games WHERE id = $1;"
}

game_status() {
  dbq "SELECT status FROM games WHERE id = $1;"
}

game_note() {
  dbq "SELECT COALESCE(note, '') FROM games WHERE id = $1;"
}

game_is_local() {
  dbq "
    SELECT CASE WHEN COUNT(DISTINCT identity_id) = 1 THEN 1 ELSE 0 END
    FROM game_players
    WHERE game_id = $1;"
}

game_en_passant() {
  dbq "SELECT COALESCE(en_passant_file, 0) || '|' || COALESCE(en_passant_rank, 0) FROM games WHERE id = $1;"
}

piece_info() {
  dbqt "SELECT id, file, rank, color, kind, has_moved FROM pieces WHERE id = $1;"
}

piece_id_at() {
  dbq "SELECT id FROM pieces WHERE game_id = $1 AND file = $2 AND rank = $3;"
}

occupant_data() {
  dbqt "SELECT id, color, kind, piece FROM pieces WHERE game_id = $1 AND file = $2 AND rank = $3;"
}

occupied_color() {
  dbq "SELECT color FROM pieces WHERE game_id = $1 AND file = $2 AND rank = $3;"
}

count_lines() {
  local count=0 line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    count=$((count + 1))
  done
  printf '%s' "$count"
}

confirm_action() {
  local prompt=$1
  if command -v gum >/dev/null 2>&1; then
    gum confirm "$prompt"
    return $?
  fi
  printf '%s [y/N] ' "$prompt"
  read -r reply
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

list_identity_names() {
  dbq "SELECT name FROM identities ORDER BY last_used_at DESC, name ASC;"
}

identity_name_by_id() {
  dbq "SELECT name FROM identities WHERE id = $1;"
}

selected_identity_id() {
  if [[ -n "$SESSION_IDENTITY_ID" ]]; then
    printf '%s' "$SESSION_IDENTITY_ID"
    return 0
  fi
  dbq "SELECT value FROM app_state WHERE key = 'selected_identity_id' LIMIT 1;"
}

selected_identity_name() {
  if [[ -n "$SESSION_IDENTITY_NAME" ]]; then
    printf '%s' "$SESSION_IDENTITY_NAME"
    return 0
  fi
  local identity_id
  identity_id=$(selected_identity_id)
  if [[ -z "$identity_id" ]]; then
    return 0
  fi
  identity_name_by_id "$identity_id"
}

config_identity_name() {
  local line trimmed_line key value

  if [[ ! -f "$CONFIG_PATH" ]]; then
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed_line=$(trim_string "$line")
    [[ -n "$trimmed_line" ]] || continue
    [[ "${trimmed_line#\#}" != "$trimmed_line" ]] && continue
    key=${trimmed_line%%=*}
    value=${trimmed_line#*=}
    key=$(trim_string "$key")
    value=$(trim_string "$value")
    if [[ "$key" == "identity" && -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done <"$CONFIG_PATH"
}

stdin_board_uri() {
  local uri=''

  if [[ -t 0 ]]; then
    return 0
  fi

  IFS= read -r uri || true
  trim_string "$uri"
}

ensure_identity() {
  local raw_name=$1
  local name safe_name
  name=$(trim_string "$raw_name")
  if [[ -z "$name" ]]; then
    return 1
  fi
  safe_name=$(sql_quote "$name")
  if [[ "$DB_PATH" == file:* ]]; then
    sqlite3 -batch -noheader "$DB_PATH" <<SQL
PRAGMA foreign_keys = ON;
BEGIN;
INSERT INTO identities(name, created_at, updated_at, last_used_at)
SELECT '$safe_name', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
WHERE NOT EXISTS (
  SELECT 1 FROM identities WHERE name = '$safe_name'
);
UPDATE identities
SET updated_at = CURRENT_TIMESTAMP,
    last_used_at = CURRENT_TIMESTAMP
WHERE name = '$safe_name';
SELECT id FROM identities WHERE name = '$safe_name';
COMMIT;
SQL
    return
  fi

  sqlite3 -batch -noheader "$DB_PATH" <<SQL
PRAGMA foreign_keys = ON;
BEGIN;
INSERT INTO identities(name, created_at, updated_at, last_used_at)
SELECT '$safe_name', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
WHERE NOT EXISTS (
  SELECT 1 FROM identities WHERE name = '$safe_name'
);
UPDATE identities
SET updated_at = CURRENT_TIMESTAMP,
    last_used_at = CURRENT_TIMESTAMP
WHERE name = '$safe_name';
SELECT id FROM identities WHERE name = '$safe_name';
COMMIT;
SQL
}

set_selected_identity_id() {
  dbq "
    INSERT INTO app_state(key, value)
    VALUES('selected_identity_id', '$1')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;"
}

set_selected_identity() {
  local identity_id
  local persist_selection=${2:-0}
  identity_id=$(ensure_identity "$1") || return 1
  SESSION_IDENTITY_ID=$identity_id
  SESSION_IDENTITY_NAME=$(identity_name_by_id "$identity_id")
  if [[ "$persist_selection" -eq 1 ]]; then
    set_selected_identity_id "$identity_id"
  fi
  printf '%s' "$identity_id"
}

turn_identity_id() {
  local game_id=$1
  dbq "
    SELECT gp.identity_id
    FROM games g
    LEFT JOIN game_players gp
      ON gp.game_id = g.id
     AND gp.color = g.turn
    WHERE g.id = $game_id
    LIMIT 1;"
}

turn_identity_name() {
  local identity_id
  identity_id=$(turn_identity_id "$1")
  if [[ -z "$identity_id" ]]; then
    return 0
  fi
  identity_name_by_id "$identity_id"
}

can_selected_identity_write() {
  local game_id=${1:-}
  local selected_id turn_id

  if [[ -z "$game_id" ]]; then
    printf '1'
    return 0
  fi

  selected_id=$(selected_identity_id)
  turn_id=$(turn_identity_id "$game_id")
  if [[ -n "$selected_id" && -n "$turn_id" && "$selected_id" == "$turn_id" ]]; then
    printf '1'
  else
    printf '0'
  fi
}

can_selected_identity_move() {
  can_selected_identity_write "$1"
}

require_write_access() {
  if [[ "$(can_selected_identity_write "${1:-}")" -eq 1 ]]; then
    return 0
  fi
  return 1
}

prompt_text_input() {
  local prompt=$1
  local default_value=${2:-}
  local reply

  if command -v gum >/dev/null 2>&1; then
    if [[ -n "$default_value" ]]; then
      reply=$(gum input --prompt "$prompt: " --value "$default_value") || return 1
    else
      reply=$(gum input --prompt "$prompt: ") || return 1
    fi
    printf '%s' "$reply"
    return 0
  fi

  printf '%s: ' "$prompt"
  read -r reply || return 1
  if [[ -z "$reply" && -n "$default_value" ]]; then
    reply=$default_value
  fi
  printf '%s' "$reply"
}

pick_option() {
  local header=$1
  shift
  if [[ "$#" -eq 0 ]]; then
    return 1
  fi
  printf '%s\n' "$@" | gum choose --header "$header"
}

prompt_for_identity_name() {
  local prompt=$1
  local default_name=${2:-}
  local choice name
  local options=()

  if command -v gum >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      options[${#options[@]}]=$line
    done <<EOF
$(list_identity_names)
EOF
    if [[ "${#options[@]}" -gt 0 ]]; then
      options[${#options[@]}]='create new identity'
      choice=$(pick_option "$prompt" "${options[@]}") || return 1
      if [[ "$choice" != 'create new identity' ]]; then
        printf '%s' "$choice"
        return 0
      fi
    fi
  fi

  while :; do
    name=$(prompt_text_input "$prompt" "$default_name") || return 1
    name=$(trim_string "$name")
    if [[ -n "$name" ]]; then
      printf '%s' "$name"
      return 0
    fi
    printf 'Identity name cannot be empty.\n' >&2
  done
}

switch_identity_interactively() {
  local game_id
  local name

  game_id=$(current_game_id)
  if [[ -n "$game_id" && "$(game_is_local "$game_id")" -ne 1 ]]; then
    printf 'Identity switching is disabled after a multiplayer game starts. Use --identity before joining, or use --local for shared-device play.\n' >&2
    return 1
  fi

  name=$(prompt_for_identity_name "Select identity" "$(selected_identity_name)") || return 1
  set_selected_identity "$name" 1 >/dev/null
}

ensure_selected_identity_for_interactive() {
  local current_name
  current_name=$(selected_identity_name)
  if [[ -n "$current_name" ]]; then
    return 0
  fi
  switch_identity_interactively
}

seed_new_game() {
  local white_identity_id=$1
  local black_identity_id=$2
  dbq "
    BEGIN;
    UPDATE games SET status = 'archived', updated_at = CURRENT_TIMESTAMP
    WHERE status = 'active';
    INSERT INTO games(status, turn, winner, note, en_passant_file, en_passant_rank)
    VALUES('active', 'white', NULL, NULL, NULL, NULL);
    INSERT INTO pieces(game_id, file, rank, piece, color, kind, has_moved)
    SELECT game_id, file, rank, piece, color, kind, has_moved
    FROM (
      SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1) AS game_id, 1 AS file, 1 AS rank, 'R' AS piece, 'white' AS color, 'rook' AS kind, 0 AS has_moved
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 2, 1, 'N', 'white', 'knight', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 3, 1, 'B', 'white', 'bishop', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 4, 1, 'Q', 'white', 'queen', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 5, 1, 'K', 'white', 'king', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 6, 1, 'B', 'white', 'bishop', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 7, 1, 'N', 'white', 'knight', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 8, 1, 'R', 'white', 'rook', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 1, 2, 'P', 'white', 'pawn', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 2, 2, 'P', 'white', 'pawn', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 3, 2, 'P', 'white', 'pawn', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 4, 2, 'P', 'white', 'pawn', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 5, 2, 'P', 'white', 'pawn', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 6, 2, 'P', 'white', 'pawn', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 7, 2, 'P', 'white', 'pawn', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 8, 2, 'P', 'white', 'pawn', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 1, 8, 'r', 'black', 'rook', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 2, 8, 'n', 'black', 'knight', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 3, 8, 'b', 'black', 'bishop', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 4, 8, 'q', 'black', 'queen', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 5, 8, 'k', 'black', 'king', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 6, 8, 'b', 'black', 'bishop', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 7, 8, 'n', 'black', 'knight', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 8, 8, 'r', 'black', 'rook', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 1, 7, 'p', 'black', 'pawn', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 2, 7, 'p', 'black', 'pawn', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 3, 7, 'p', 'black', 'pawn', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 4, 7, 'p', 'black', 'pawn', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 5, 7, 'p', 'black', 'pawn', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 6, 7, 'p', 'black', 'pawn', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 7, 7, 'p', 'black', 'pawn', 0
      UNION ALL SELECT (SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 8, 7, 'p', 'black', 'pawn', 0
    );
    INSERT INTO game_players(game_id, color, identity_id)
    VALUES
      ((SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 'white', $white_identity_id),
      ((SELECT id FROM games WHERE status = 'active' ORDER BY id DESC LIMIT 1), 'black', $black_identity_id);
    COMMIT;"
}

start_new_game_flow() {
  local mode=$1
  local selected_name white_name black_name white_identity_id black_identity_id game_id

  selected_name=$(selected_identity_name)
  if [[ "$mode" == "local" ]]; then
    if [[ -z "$selected_name" ]]; then
      return 1
    fi
    white_identity_id=$(ensure_identity "$selected_name") || return 1
    black_identity_id=$white_identity_id
  else
    while :; do
      white_name=$(prompt_for_identity_name "White player" "$selected_name") || return 1
      black_name=$(prompt_for_identity_name "Black player") || return 1
      white_identity_id=$(ensure_identity "$white_name") || continue
      black_identity_id=$(ensure_identity "$black_name") || continue
      if [[ "$white_identity_id" == "$black_identity_id" ]]; then
        printf 'Use --local if one identity should control both colors.\n' >&2
        continue
      fi
      break
    done
  fi

  seed_new_game "$white_identity_id" "$black_identity_id"
  game_id=$(current_game_id)
  if [[ -n "$game_id" ]]; then
    update_game_state "$game_id"
  fi
}

ensure_active_game() {
  current_game_id
}

attack_query_for_square() {
  local game_id=$1
  local attacker_color=$2
  local target_file=$3
  local target_rank=$4
  cat <<SQL
WITH RECURSIVE
occupied AS (
  SELECT file, rank, color, kind
  FROM pieces
  WHERE game_id = $game_id
),
attackers AS (
  SELECT id, file, rank, color, kind
  FROM pieces
  WHERE game_id = $game_id
    AND color = '$attacker_color'
),
dirs(df, dr) AS (
  VALUES
    (1, 0), (-1, 0), (0, 1), (0, -1),
    (1, 1), (1, -1), (-1, 1), (-1, -1)
),
ray(id, kind, file, rank, df, dr) AS (
  SELECT a.id, a.kind, a.file + d.df, a.rank + d.dr, d.df, d.dr
  FROM attackers a
  JOIN dirs d
    ON (
      (a.kind = 'bishop' AND abs(d.df) = 1 AND abs(d.dr) = 1) OR
      (a.kind = 'rook' AND ((abs(d.df) = 1 AND d.dr = 0) OR (d.df = 0 AND abs(d.dr) = 1))) OR
      (a.kind = 'queen')
    )
  WHERE a.kind IN ('bishop', 'rook', 'queen')
    AND a.file + d.df BETWEEN 1 AND 8
    AND a.rank + d.dr BETWEEN 1 AND 8

  UNION ALL

  SELECT id, kind, file + df, rank + dr, df, dr
  FROM ray
  WHERE NOT EXISTS (
      SELECT 1
      FROM occupied o
      WHERE o.file = ray.file
        AND o.rank = ray.rank
    )
    AND file + df BETWEEN 1 AND 8
    AND rank + dr BETWEEN 1 AND 8
),
hits AS (
  SELECT 1
  FROM attackers a
  WHERE a.kind = 'knight'
    AND (
      (a.file + 1 = $target_file AND a.rank + 2 = $target_rank) OR
      (a.file + 2 = $target_file AND a.rank + 1 = $target_rank) OR
      (a.file + 2 = $target_file AND a.rank - 1 = $target_rank) OR
      (a.file + 1 = $target_file AND a.rank - 2 = $target_rank) OR
      (a.file - 1 = $target_file AND a.rank - 2 = $target_rank) OR
      (a.file - 2 = $target_file AND a.rank - 1 = $target_rank) OR
      (a.file - 2 = $target_file AND a.rank + 1 = $target_rank) OR
      (a.file - 1 = $target_file AND a.rank + 2 = $target_rank)
    )

  UNION ALL

  SELECT 1
  FROM attackers a
  WHERE a.kind = 'king'
    AND abs(a.file - $target_file) <= 1
    AND abs(a.rank - $target_rank) <= 1

  UNION ALL

  SELECT 1
  FROM attackers a
  WHERE a.kind = 'pawn'
    AND (
      (a.color = 'white' AND (
        (a.file + 1 = $target_file AND a.rank + 1 = $target_rank) OR
        (a.file - 1 = $target_file AND a.rank + 1 = $target_rank)
      )) OR
      (a.color = 'black' AND (
        (a.file + 1 = $target_file AND a.rank - 1 = $target_rank) OR
        (a.file - 1 = $target_file AND a.rank - 1 = $target_rank)
      ))
    )

  UNION ALL

  SELECT 1
  FROM ray
  WHERE ray.file = $target_file
    AND ray.rank = $target_rank
)
SELECT CASE WHEN EXISTS(SELECT 1 FROM hits) THEN 1 ELSE 0 END;
SQL
}

square_attacked_by() {
  local game_id=$1 attacker_color=$2 target_file=$3 target_rank=$4
  dbq "$(attack_query_for_square "$game_id" "$attacker_color" "$target_file" "$target_rank")"
}

is_in_check() {
  local game_id=$1 color=$2 attacker king_square king_file king_rank
  attacker=$(opposite_color "$color")
  king_square=$(dbqt "SELECT file, rank FROM pieces WHERE game_id = $game_id AND color = '$color' AND kind = 'king' LIMIT 1;")
  if [[ -z "$king_square" ]]; then
    printf '1'
    return
  fi
  IFS=$'\t' read -r king_file king_rank <<EOF
$king_square
EOF
  square_attacked_by "$game_id" "$attacker" "$king_file" "$king_rank"
}

simulate_move_batch() {
  local game_id=$1
  local piece_id=$2
  local src_file=$3
  local src_rank=$4
  local color=$5
  local kind=$6
  local dest_file=$7
  local dest_rank=$8
  local special=$9
  local capture_rank=$src_rank
  local promoted_symbol

  promoted_symbol=$(piece_symbol "$color" "queen")

  case "$special" in
    normal|capture)
      cat <<SQL
DELETE FROM pieces WHERE game_id = $game_id AND file = $dest_file AND rank = $dest_rank;
UPDATE pieces
SET file = $dest_file, rank = $dest_rank, has_moved = 1
WHERE id = $piece_id;
SQL
      ;;
    promotion|promotion_capture)
      cat <<SQL
DELETE FROM pieces WHERE game_id = $game_id AND file = $dest_file AND rank = $dest_rank;
UPDATE pieces
SET file = $dest_file,
    rank = $dest_rank,
    has_moved = 1,
    kind = 'queen',
    piece = '$promoted_symbol'
WHERE id = $piece_id;
SQL
      ;;
    en_passant)
      if [[ "$color" == "white" ]]; then
        capture_rank=$((dest_rank - 1))
      else
        capture_rank=$((dest_rank + 1))
      fi
      cat <<SQL
DELETE FROM pieces WHERE game_id = $game_id AND file = $dest_file AND rank = $capture_rank;
UPDATE pieces
SET file = $dest_file, rank = $dest_rank, has_moved = 1
WHERE id = $piece_id;
SQL
      ;;
    castle_kingside)
      cat <<SQL
UPDATE pieces
SET file = 7, rank = $src_rank, has_moved = 1
WHERE id = $piece_id;
UPDATE pieces
SET file = 6, rank = $src_rank, has_moved = 1
WHERE game_id = $game_id AND color = '$color' AND kind = 'rook' AND file = 8 AND rank = $src_rank;
SQL
      ;;
    castle_queenside)
      cat <<SQL
UPDATE pieces
SET file = 3, rank = $src_rank, has_moved = 1
WHERE id = $piece_id;
UPDATE pieces
SET file = 4, rank = $src_rank, has_moved = 1
WHERE game_id = $game_id AND color = '$color' AND kind = 'rook' AND file = 1 AND rank = $src_rank;
SQL
      ;;
    *)
      return 1
      ;;
  esac
}

is_move_safe() {
  local game_id=$1 piece_id=$2 src_file=$3 src_rank=$4 color=$5 kind=$6 dest_file=$7 dest_rank=$8 special=$9
  local opponent
  opponent=$(opposite_color "$color")
  dbq "$(cat <<SQL
BEGIN;
$(simulate_move_batch "$game_id" "$piece_id" "$src_file" "$src_rank" "$color" "$kind" "$dest_file" "$dest_rank" "$special")
WITH king_square AS (
  SELECT file, rank
  FROM pieces
  WHERE game_id = $game_id
    AND color = '$color'
    AND kind = 'king'
  LIMIT 1
),
occupied AS (
  SELECT file, rank, color, kind
  FROM pieces
  WHERE game_id = $game_id
),
attackers AS (
  SELECT id, file, rank, color, kind
  FROM pieces
  WHERE game_id = $game_id
    AND color = '$opponent'
),
dirs(df, dr) AS (
  VALUES
    (1, 0), (-1, 0), (0, 1), (0, -1),
    (1, 1), (1, -1), (-1, 1), (-1, -1)
),
ray(id, kind, file, rank, df, dr) AS (
  SELECT a.id, a.kind, a.file + d.df, a.rank + d.dr, d.df, d.dr
  FROM attackers a
  JOIN dirs d
    ON (
      (a.kind = 'bishop' AND abs(d.df) = 1 AND abs(d.dr) = 1) OR
      (a.kind = 'rook' AND ((abs(d.df) = 1 AND d.dr = 0) OR (d.df = 0 AND abs(d.dr) = 1))) OR
      (a.kind = 'queen')
    )
  WHERE a.kind IN ('bishop', 'rook', 'queen')
    AND a.file + d.df BETWEEN 1 AND 8
    AND a.rank + d.dr BETWEEN 1 AND 8

  UNION ALL

  SELECT id, kind, file + df, rank + dr, df, dr
  FROM ray
  WHERE NOT EXISTS (
      SELECT 1
      FROM occupied o
      WHERE o.file = ray.file
        AND o.rank = ray.rank
    )
    AND file + df BETWEEN 1 AND 8
    AND rank + dr BETWEEN 1 AND 8
),
hits AS (
  SELECT 1
  FROM attackers a, king_square k
  WHERE a.kind = 'knight'
    AND (
      (a.file + 1 = k.file AND a.rank + 2 = k.rank) OR
      (a.file + 2 = k.file AND a.rank + 1 = k.rank) OR
      (a.file + 2 = k.file AND a.rank - 1 = k.rank) OR
      (a.file + 1 = k.file AND a.rank - 2 = k.rank) OR
      (a.file - 1 = k.file AND a.rank - 2 = k.rank) OR
      (a.file - 2 = k.file AND a.rank - 1 = k.rank) OR
      (a.file - 2 = k.file AND a.rank + 1 = k.rank) OR
      (a.file - 1 = k.file AND a.rank + 2 = k.rank)
    )

  UNION ALL

  SELECT 1
  FROM attackers a, king_square k
  WHERE a.kind = 'king'
    AND abs(a.file - k.file) <= 1
    AND abs(a.rank - k.rank) <= 1

  UNION ALL

  SELECT 1
  FROM attackers a, king_square k
  WHERE a.kind = 'pawn'
    AND (
      (a.color = 'white' AND (
        (a.file + 1 = k.file AND a.rank + 1 = k.rank) OR
        (a.file - 1 = k.file AND a.rank + 1 = k.rank)
      )) OR
      (a.color = 'black' AND (
        (a.file + 1 = k.file AND a.rank - 1 = k.rank) OR
        (a.file - 1 = k.file AND a.rank - 1 = k.rank)
      ))
    )

  UNION ALL

  SELECT 1
  FROM ray, king_square k
  WHERE ray.file = k.file
    AND ray.rank = k.rank
)
SELECT CASE WHEN EXISTS(SELECT 1 FROM hits) THEN 0 ELSE 1 END;
ROLLBACK;
SQL
)"
}

sliding_moves() {
  local game_id=$1 src_file=$2 src_rank=$3 color=$4 directions=$5
  local dir token df dr file rank occupant
  for dir in $directions; do
    df=${dir%:*}
    dr=${dir#*:}
    file=$((src_file + df))
    rank=$((src_rank + dr))
    while is_on_board "$file" "$rank"; do
      occupant=$(occupant_data "$game_id" "$file" "$rank")
      if [[ -z "$occupant" ]]; then
        printf '%s|%s|normal\n' "$file" "$rank"
      else
        IFS=$'\t' read -r _ target_color _ _ <<EOF
$occupant
EOF
        if [[ "$target_color" != "$color" ]]; then
          printf '%s|%s|capture\n' "$file" "$rank"
        fi
        break
      fi
      file=$((file + df))
      rank=$((rank + dr))
    done
  done
}

pseudo_moves_for_piece() {
  local game_id=$1 piece_id=$2
  local piece_data src_file src_rank color kind has_moved
  local dir start_rank last_rank next_rank two_rank file rank occupant target_color
  local en_passant_data en_passant_file en_passant_rank

  piece_data=$(piece_info "$piece_id")
  if [[ -z "$piece_data" ]]; then
    return 0
  fi

  IFS=$'\t' read -r _ src_file src_rank color kind has_moved <<EOF
$piece_data
EOF

  en_passant_data=$(game_en_passant "$game_id")
  IFS='|' read -r en_passant_file en_passant_rank <<EOF
$en_passant_data
EOF

  case "$kind" in
    pawn)
      if [[ "$color" == "white" ]]; then
        dir=1
        start_rank=2
        last_rank=8
      else
        dir=-1
        start_rank=7
        last_rank=1
      fi

      next_rank=$((src_rank + dir))
      if is_on_board "$src_file" "$next_rank" && [[ -z "$(occupant_data "$game_id" "$src_file" "$next_rank")" ]]; then
        if [[ "$next_rank" -eq "$last_rank" ]]; then
          printf '%s|%s|promotion\n' "$src_file" "$next_rank"
        else
          printf '%s|%s|normal\n' "$src_file" "$next_rank"
        fi
        two_rank=$((src_rank + (2 * dir)))
        if [[ "$src_rank" -eq "$start_rank" ]] && [[ -z "$(occupant_data "$game_id" "$src_file" "$two_rank")" ]]; then
          printf '%s|%s|normal\n' "$src_file" "$two_rank"
        fi
      fi

      for file in $((src_file - 1)) $((src_file + 1)); do
        rank=$((src_rank + dir))
        if ! is_on_board "$file" "$rank"; then
          continue
        fi
        occupant=$(occupant_data "$game_id" "$file" "$rank")
        if [[ -n "$occupant" ]]; then
          IFS=$'\t' read -r _ target_color _ _ <<EOF
$occupant
EOF
          if [[ "$target_color" != "$color" ]]; then
            if [[ "$rank" -eq "$last_rank" ]]; then
              printf '%s|%s|promotion_capture\n' "$file" "$rank"
            else
              printf '%s|%s|capture\n' "$file" "$rank"
            fi
          fi
        elif [[ "$file" -eq "$en_passant_file" && "$rank" -eq "$en_passant_rank" ]]; then
          printf '%s|%s|en_passant\n' "$file" "$rank"
        fi
      done
      ;;
    knight)
      for token in "1:2" "2:1" "2:-1" "1:-2" "-1:-2" "-2:-1" "-2:1" "-1:2"; do
        file=$((src_file + ${token%:*}))
        rank=$((src_rank + ${token#*:}))
        if ! is_on_board "$file" "$rank"; then
          continue
        fi
        occupant=$(occupant_data "$game_id" "$file" "$rank")
        if [[ -z "$occupant" ]]; then
          printf '%s|%s|normal\n' "$file" "$rank"
        else
          IFS=$'\t' read -r _ target_color _ _ <<EOF
$occupant
EOF
          if [[ "$target_color" != "$color" ]]; then
            printf '%s|%s|capture\n' "$file" "$rank"
          fi
        fi
      done
      ;;
    bishop)
      sliding_moves "$game_id" "$src_file" "$src_rank" "$color" "1:1 1:-1 -1:1 -1:-1"
      ;;
    rook)
      sliding_moves "$game_id" "$src_file" "$src_rank" "$color" "1:0 -1:0 0:1 0:-1"
      ;;
    queen)
      sliding_moves "$game_id" "$src_file" "$src_rank" "$color" "1:0 -1:0 0:1 0:-1 1:1 1:-1 -1:1 -1:-1"
      ;;
    king)
      for token in "1:0" "1:1" "0:1" "-1:1" "-1:0" "-1:-1" "0:-1" "1:-1"; do
        file=$((src_file + ${token%:*}))
        rank=$((src_rank + ${token#*:}))
        if ! is_on_board "$file" "$rank"; then
          continue
        fi
        occupant=$(occupant_data "$game_id" "$file" "$rank")
        if [[ -z "$occupant" ]]; then
          printf '%s|%s|normal\n' "$file" "$rank"
        else
          IFS=$'\t' read -r _ target_color _ _ <<EOF
$occupant
EOF
          if [[ "$target_color" != "$color" ]]; then
            printf '%s|%s|capture\n' "$file" "$rank"
          fi
        fi
      done
      if [[ "$has_moved" -eq 0 ]] && [[ "$(is_in_check "$game_id" "$color")" -eq 0 ]]; then
        local home_rank rook_data rook_moved enemy
        home_rank=$src_rank
        enemy=$(opposite_color "$color")

        rook_data=$(dbqt "SELECT id, has_moved FROM pieces WHERE game_id = $game_id AND color = '$color' AND kind = 'rook' AND file = 8 AND rank = $home_rank;")
        if [[ -n "$rook_data" ]] && [[ -z "$(occupant_data "$game_id" 6 "$home_rank")" ]] && [[ -z "$(occupant_data "$game_id" 7 "$home_rank")" ]]; then
          IFS=$'\t' read -r _ rook_moved <<EOF
$rook_data
EOF
          if [[ "$rook_moved" -eq 0 ]] && [[ "$(square_attacked_by "$game_id" "$enemy" 6 "$home_rank")" -eq 0 ]] && [[ "$(square_attacked_by "$game_id" "$enemy" 7 "$home_rank")" -eq 0 ]]; then
            printf '7|%s|castle_kingside\n' "$home_rank"
          fi
        fi

        rook_data=$(dbqt "SELECT id, has_moved FROM pieces WHERE game_id = $game_id AND color = '$color' AND kind = 'rook' AND file = 1 AND rank = $home_rank;")
        if [[ -n "$rook_data" ]] && [[ -z "$(occupant_data "$game_id" 2 "$home_rank")" ]] && [[ -z "$(occupant_data "$game_id" 3 "$home_rank")" ]] && [[ -z "$(occupant_data "$game_id" 4 "$home_rank")" ]]; then
          IFS=$'\t' read -r _ rook_moved <<EOF
$rook_data
EOF
          if [[ "$rook_moved" -eq 0 ]] && [[ "$(square_attacked_by "$game_id" "$enemy" 4 "$home_rank")" -eq 0 ]] && [[ "$(square_attacked_by "$game_id" "$enemy" 3 "$home_rank")" -eq 0 ]]; then
            printf '3|%s|castle_queenside\n' "$home_rank"
          fi
        fi
      fi
      ;;
  esac
}

legal_moves_for_piece() {
  local game_id=$1 piece_id=$2
  local piece_data src_file src_rank color kind has_moved
  local move_line dest_file dest_rank special
  piece_data=$(piece_info "$piece_id")
  [[ -n "$piece_data" ]] || return 0
  IFS=$'\t' read -r _ src_file src_rank color kind has_moved <<EOF
$piece_data
EOF
  while IFS='|' read -r dest_file dest_rank special; do
    [[ -n "$dest_file" ]] || continue
    if [[ "$(is_move_safe "$game_id" "$piece_id" "$src_file" "$src_rank" "$color" "$kind" "$dest_file" "$dest_rank" "$special")" -eq 1 ]]; then
      printf '%s|%s|%s\n' "$dest_file" "$dest_rank" "$special"
    fi
  done <<EOF
$(pseudo_moves_for_piece "$game_id" "$piece_id")
EOF
}

list_source_options() {
  local game_id=$1 turn pieces piece_row piece_id file rank color kind symbol moves move_count square
  turn=$(game_turn "$game_id")
  pieces=$(dbqt "SELECT id, file, rank, color, kind FROM pieces WHERE game_id = $game_id AND color = '$turn' ORDER BY rank, file;")
  while IFS=$'\t' read -r piece_id file rank color kind; do
    [[ -n "$piece_id" ]] || continue
    moves=$(legal_moves_for_piece "$game_id" "$piece_id")
    move_count=$(count_lines <<EOF
$moves
EOF
)
    if [[ "$move_count" -gt 0 ]]; then
      square=$(coords_to_square "$file" "$rank")
      symbol=$(piece_symbol "$color" "$kind")
      printf '%s  %s  %s move(s)\n' "$square" "$symbol" "$move_count"
    fi
  done <<EOF
$pieces
EOF
}

move_description() {
  case "$1" in
    normal) printf 'move' ;;
    capture) printf 'capture' ;;
    promotion) printf 'promote to queen' ;;
    promotion_capture) printf 'capture + promote to queen' ;;
    en_passant) printf 'en passant' ;;
    castle_kingside) printf 'castle kingside' ;;
    castle_queenside) printf 'castle queenside' ;;
    *) printf 'move' ;;
  esac
}

list_destination_options() {
  local game_id=$1 piece_id=$2
  local legal_moves dest_file dest_rank special
  legal_moves=$(legal_moves_for_piece "$game_id" "$piece_id")
  while IFS='|' read -r dest_file dest_rank special; do
    [[ -n "$dest_file" ]] || continue
    printf '%s  %s\n' "$(coords_to_square "$dest_file" "$dest_rank")" "$(move_description "$special")"
  done <<EOF
$legal_moves
EOF
}

special_for_destination() {
  local game_id=$1 piece_id=$2 target_square=$3
  local coords dest_file dest_rank special file rank
  coords=$(square_to_coords "$target_square")
  IFS='|' read -r file rank <<EOF
$coords
EOF
  while IFS='|' read -r dest_file dest_rank special; do
    [[ -n "$dest_file" ]] || continue
    if [[ "$dest_file" -eq "$file" && "$dest_rank" -eq "$rank" ]]; then
      printf '%s' "$special"
      return 0
    fi
  done <<EOF
$(legal_moves_for_piece "$game_id" "$piece_id")
EOF
  return 1
}

render_board_text() {
  local game_id=$1 rank line file piece_char piece_data
  printf '    a b c d e f g h\n'
  printf '  +-----------------+\n'
  for rank in 8 7 6 5 4 3 2 1; do
    line=''
    for file in 1 2 3 4 5 6 7 8; do
      piece_data=$(dbq "SELECT piece FROM pieces WHERE game_id = $game_id AND file = $file AND rank = $rank;")
      if [[ -z "$piece_data" ]]; then
        piece_char='.'
      else
        piece_char=$piece_data
      fi
      if [[ -z "$line" ]]; then
        line=$piece_char
      else
        line="$line $piece_char"
      fi
    done
    printf '%s | %s | %s\n' "$rank" "$line" "$rank"
  done
  printf '  +-----------------+\n'
  printf '    a b c d e f g h\n'
}

moves_text() {
  local game_id=$1
  dbq "SELECT printf('%3d. %s', ply, notation) FROM moves WHERE game_id = $game_id ORDER BY ply;"
}

show_moves() {
  local game_id moves
  game_id=$(current_game_id)
  if [[ -z "$game_id" ]]; then
    printf 'No active game.\n'
    return 0
  fi
  moves=$(moves_text "$game_id")
  if [[ -z "$moves" ]]; then
    moves='No moves yet.'
  fi
  show_in_pager "$moves"
}

notation_for_move() {
  local src_square=$1 dest_square=$2 special=$3 capture_symbol=$4
  case "$special" in
    castle_kingside) printf 'O-O' ;;
    castle_queenside) printf 'O-O-O' ;;
    *)
      if [[ -n "$capture_symbol" ]]; then
        printf '%s x %s' "$src_square" "$dest_square"
      else
        printf '%s - %s' "$src_square" "$dest_square"
      fi
      if [[ "$special" == "en_passant" ]]; then
        printf ' e.p.'
      fi
      if [[ "$special" == "promotion" || "$special" == "promotion_capture" ]]; then
        printf ' =Q'
      fi
      ;;
  esac
}

apply_move() {
  local game_id=$1 piece_id=$2 target_square=$3
  local piece_data src_file src_rank color kind has_moved
  local coords dest_file dest_rank special capture_data capture_symbol next_turn
  local src_square dest_square notation promotion_value en_passant_file en_passant_rank

  piece_data=$(piece_info "$piece_id")
  IFS=$'\t' read -r _ src_file src_rank color kind has_moved <<EOF
$piece_data
EOF

  coords=$(square_to_coords "$target_square")
  IFS='|' read -r dest_file dest_rank <<EOF
$coords
EOF

  special=$(special_for_destination "$game_id" "$piece_id" "$target_square")
  if [[ -z "$special" ]]; then
    return 1
  fi

  capture_symbol=''
  if [[ "$special" == "capture" || "$special" == "promotion_capture" ]]; then
    capture_data=$(occupant_data "$game_id" "$dest_file" "$dest_rank")
    if [[ -n "$capture_data" ]]; then
      IFS=$'\t' read -r _ _ _ capture_symbol <<EOF
$capture_data
EOF
    fi
  elif [[ "$special" == "en_passant" ]]; then
    if [[ "$color" == "white" ]]; then
      capture_data=$(occupant_data "$game_id" "$dest_file" $((dest_rank - 1)))
    else
      capture_data=$(occupant_data "$game_id" "$dest_file" $((dest_rank + 1)))
    fi
    if [[ -n "$capture_data" ]]; then
      IFS=$'\t' read -r _ _ _ capture_symbol <<EOF
$capture_data
EOF
    fi
  fi

  src_square=$(coords_to_square "$src_file" "$src_rank")
  dest_square=$(coords_to_square "$dest_file" "$dest_rank")
  notation=$(notation_for_move "$src_square" "$dest_square" "$special" "$capture_symbol")
  promotion_value='NULL'
  if [[ "$special" == "promotion" || "$special" == "promotion_capture" ]]; then
    promotion_value="'queen'"
  fi

  en_passant_file='NULL'
  en_passant_rank='NULL'
  if [[ "$kind" == "pawn" && $((dest_rank - src_rank)) -eq 2 ]]; then
    en_passant_file=$src_file
    en_passant_rank=$((src_rank + 1))
  elif [[ "$kind" == "pawn" && $((dest_rank - src_rank)) -eq -2 ]]; then
    en_passant_file=$src_file
    en_passant_rank=$((src_rank - 1))
  fi

  next_turn=$(opposite_color "$color")

  if [[ "$DB_PATH" == file:* ]]; then
    sqlite3 "$DB_PATH" <<SQL
PRAGMA foreign_keys = ON;
BEGIN;
$(simulate_move_batch "$game_id" "$piece_id" "$src_file" "$src_rank" "$color" "$kind" "$dest_file" "$dest_rank" "$special")
UPDATE games
SET turn = '$next_turn',
    status = 'active',
    winner = NULL,
    note = NULL,
    en_passant_file = $en_passant_file,
    en_passant_rank = $en_passant_rank,
    updated_at = CURRENT_TIMESTAMP
WHERE id = $game_id;
INSERT INTO moves(game_id, ply, from_sq, to_sq, piece, capture, promotion, notation, created_at)
SELECT
  $game_id,
  COALESCE(MAX(ply), 0) + 1,
  '$src_square',
  '$dest_square',
  '$(piece_symbol "$color" "$kind")',
  $(if [[ -n "$capture_symbol" ]]; then printf "'%s'" "$(sql_quote "$capture_symbol")"; else printf 'NULL'; fi),
  $promotion_value,
  '$(sql_quote "$notation")',
  CURRENT_TIMESTAMP
FROM moves
WHERE game_id = $game_id;
COMMIT;
SQL
    return
  fi

  sqlite3 "$DB_PATH" <<SQL
PRAGMA foreign_keys = ON;
BEGIN;
$(simulate_move_batch "$game_id" "$piece_id" "$src_file" "$src_rank" "$color" "$kind" "$dest_file" "$dest_rank" "$special")
UPDATE games
SET turn = '$next_turn',
    status = 'active',
    winner = NULL,
    note = NULL,
    en_passant_file = $en_passant_file,
    en_passant_rank = $en_passant_rank,
    updated_at = CURRENT_TIMESTAMP
WHERE id = $game_id;
INSERT INTO moves(game_id, ply, from_sq, to_sq, piece, capture, promotion, notation, created_at)
SELECT
  $game_id,
  COALESCE(MAX(ply), 0) + 1,
  '$src_square',
  '$dest_square',
  '$(piece_symbol "$color" "$kind")',
  $(if [[ -n "$capture_symbol" ]]; then printf "'%s'" "$(sql_quote "$capture_symbol")"; else printf 'NULL'; fi),
  $promotion_value,
  '$(sql_quote "$notation")',
  CURRENT_TIMESTAMP
FROM moves
WHERE game_id = $game_id;
COMMIT;
SQL
}

update_game_state() {
  local game_id=$1 turn sources winner
  turn=$(game_turn "$game_id")
  sources=$(list_source_options "$game_id")
  if [[ -n "$sources" ]]; then
    if [[ "$(is_in_check "$game_id" "$turn")" -eq 1 ]]; then
      dbq "UPDATE games SET note = '$turn is in check', updated_at = CURRENT_TIMESTAMP WHERE id = $game_id;"
    else
      dbq "UPDATE games SET note = NULL, updated_at = CURRENT_TIMESTAMP WHERE id = $game_id;"
    fi
    return 0
  fi

  if [[ "$(is_in_check "$game_id" "$turn")" -eq 1 ]]; then
    winner=$(opposite_color "$turn")
    dbq "UPDATE games
        SET status = 'checkmate',
            winner = '$winner',
            note = '$winner wins by checkmate',
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $game_id;"
  else
    dbq "UPDATE games
        SET status = 'stalemate',
            winner = NULL,
            note = 'Draw by stalemate',
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $game_id;"
  fi
}

resign_game() {
  local game_id=$1 turn winner
  turn=$(game_turn "$game_id")
  winner=$(opposite_color "$turn")
  dbq "UPDATE games
      SET status = 'resigned',
          winner = '$winner',
          note = '$turn resigned',
          updated_at = CURRENT_TIMESTAMP
      WHERE id = $game_id;"
}

status_line() {
  local game_id=${1:-}
  local identity_name turn status note turn_name mode
  identity_name=$(selected_identity_name)
  if [[ -z "$identity_name" ]]; then
    identity_name='(none)'
  fi

  if [[ -z "$game_id" ]]; then
    printf 'Identity: %s\nTurn: none\nMode: writable setup\nStatus: no active game\n' "$identity_name"
    return 0
  fi

  turn=$(game_turn "$game_id")
  status=$(game_status "$game_id")
  note=$(game_note "$game_id")
  turn_name=$(turn_identity_name "$game_id")
  if [[ -z "$turn_name" ]]; then
    turn_name='unassigned'
  fi

  if [[ "$(can_selected_identity_write "$game_id")" -eq 1 ]]; then
    mode='writable'
  elif [[ "$turn_name" == 'unassigned' ]]; then
    mode='read-only (turn owner unassigned)'
  else
    mode="read-only waiting for $turn_name"
  fi

  printf 'Identity: %s\nTurn: %s (%s)\nMode: %s\nStatus: %s\n' "$identity_name" "$turn" "$turn_name" "$mode" "$status"
  if [[ -n "$note" ]]; then
    printf 'Note: %s\n' "$note"
  fi
}

interactive_game() {
  local game_id board screen source_options source_choice source_square piece_coords piece_id
  local destination_options destination_choice target_square action status
  local piece_file piece_rank allow_switch_identity

  require_gum
  ensure_selected_identity_for_interactive || return 0

  while :; do
    game_id=$(current_game_id)
    allow_switch_identity=1
    if [[ -n "$game_id" && "$(game_is_local "$game_id")" -ne 1 ]]; then
      allow_switch_identity=0
    fi

    if [[ -n "$game_id" ]]; then
      status=$(game_status "$game_id")
      board=$(render_board_text "$game_id")
      screen=$(printf '%s\n\n%s\n' "$(status_line "$game_id")" "$board")
    else
      status='none'
      screen=$(printf '%s\n' "$(status_line)")
    fi

    clear_screen
    gum style --border rounded --padding "1 2" --margin "1 0" --border-foreground 212 "$(printf '%s\n' "$APP_TITLE")"
    gum style --border normal --padding "1 2" "$screen"

    if [[ -z "$game_id" ]]; then
      action=$(pick_option "No active game." "new game" "new local game" "switch identity" "quit") || return 0
      case "$action" in
        "new game")
          if confirm_action "Start a new game?"; then
            start_new_game_flow "multiplayer"
          fi
          ;;
        "new local game")
          if confirm_action "Start a new local game?"; then
            start_new_game_flow "local"
          fi
          ;;
        "switch identity")
          switch_identity_interactively || true
          ;;
        quit)
          return 0
          ;;
      esac
      continue
    fi

    if [[ "$status" != "active" ]]; then
      if require_write_access "$game_id"; then
        if [[ "$allow_switch_identity" -eq 1 ]]; then
          action=$(pick_option "Game over." "new game" "new local game" "show moves" "switch identity" "quit") || return 0
        else
          action=$(pick_option "Game over." "new game" "new local game" "show moves" "quit") || return 0
        fi
      else
        if [[ "$allow_switch_identity" -eq 1 ]]; then
          action=$(pick_option "Read-only mode." "refresh" "show moves" "switch identity" "quit") || return 0
        else
          action=$(pick_option "Read-only mode." "refresh" "show moves" "quit") || return 0
        fi
      fi
      case "$action" in
        "new game")
          if confirm_action "Start a new game?"; then
            start_new_game_flow "multiplayer"
          fi
          ;;
        "new local game")
          if confirm_action "Start a new local game?"; then
            start_new_game_flow "local"
          fi
          ;;
        "show moves")
          show_moves
          ;;
        "switch identity")
          switch_identity_interactively || true
          ;;
        refresh)
          ;;
        quit)
          return 0
          ;;
      esac
      continue
    fi

    if ! require_write_access "$game_id"; then
      if [[ "$allow_switch_identity" -eq 1 ]]; then
        action=$(pick_option "Read-only mode." "refresh" "show moves" "switch identity" "quit") || return 0
      else
        action=$(pick_option "Read-only mode." "refresh" "show moves" "quit") || return 0
      fi
      case "$action" in
        refresh)
          ;;
        "show moves")
          show_moves
          ;;
        "switch identity")
          switch_identity_interactively || true
          ;;
        quit)
          return 0
          ;;
      esac
      continue
    fi

    if [[ "$allow_switch_identity" -eq 1 ]]; then
      action=$(pick_option "Choose an action" "move" "show moves" "switch identity" "resign" "new game" "new local game" "quit") || return 0
    else
      action=$(pick_option "Choose an action" "move" "show moves" "resign" "new game" "new local game" "quit") || return 0
    fi
    case "$action" in
      move)
        source_options=()
        while IFS= read -r line; do
          [[ -n "$line" ]] || continue
          source_options[${#source_options[@]}]=$line
        done <<EOF
$(list_source_options "$game_id")
EOF
        if [[ "${#source_options[@]}" -eq 0 ]]; then
          continue
        fi

        source_choice=$(pick_option "Select a piece" "${source_options[@]}") || continue
        source_square=${source_choice%% *}
        piece_coords=$(square_to_coords "$source_square")
        IFS='|' read -r piece_file piece_rank <<EOF
$piece_coords
EOF
        piece_id=$(piece_id_at "$game_id" "$piece_file" "$piece_rank")

        destination_options=()
        while IFS= read -r line; do
          [[ -n "$line" ]] || continue
          destination_options[${#destination_options[@]}]=$line
        done <<EOF
$(list_destination_options "$game_id" "$piece_id")
EOF
        if [[ "${#destination_options[@]}" -eq 0 ]]; then
          continue
        fi

        destination_choice=$(pick_option "Select a destination for $source_square" "${destination_options[@]}") || continue
        target_square=${destination_choice%% *}
        apply_move "$game_id" "$piece_id" "$target_square"
        update_game_state "$game_id"
        ;;
      "show moves")
        show_moves
        ;;
      "switch identity")
        switch_identity_interactively || true
        ;;
      resign)
        if confirm_action "Resign the current game?"; then
          resign_game "$game_id"
        fi
        ;;
      "new game")
        if confirm_action "Start a new game?"; then
          start_new_game_flow "multiplayer"
        fi
        ;;
      "new local game")
        if confirm_action "Start a new local game?"; then
          start_new_game_flow "local"
        fi
        ;;
      quit)
        return 0
        ;;
    esac
  done
}

main() {
  local action=''
  local identity_arg=''
  local selected_name=''
  local config_identity=''
  local board_uri=''

  require_sqlite

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --identity)
        shift
        if [[ "$#" -eq 0 ]]; then
          printf '%s\n' '--identity requires a name.' >&2
          exit 1
        fi
        identity_arg=$1
        ;;
      --new|--local|--moves|--whoami|--help|-h)
        if [[ -n "$action" ]]; then
          printf 'Only one command may be used at a time.\n' >&2
          exit 1
        fi
        action=$1
        ;;
      *)
        printf 'Unknown option: %s\n\n' "$1" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
  done

  case "$action" in
    --help|-h)
      usage
      return 0
      ;;
  esac

  if [[ "$action" != "--help" && "$action" != "-h" ]]; then
    board_uri=$(stdin_board_uri)
    if [[ -n "$board_uri" ]]; then
      DB_PATH=$board_uri
    fi
  fi

  init_db

  config_identity=$(config_identity_name)
  selected_name=$(selected_identity_name)

  if [[ -n "$identity_arg" ]]; then
    set_selected_identity "$identity_arg" >/dev/null
  elif [[ -n "$config_identity" ]]; then
    set_selected_identity "$config_identity" >/dev/null
  fi

  case "$action" in
    --help|-h)
      usage
      ;;
    --moves)
      show_moves
      ;;
    --whoami)
      if [[ -n "$(selected_identity_name)" ]]; then
        selected_identity_name
      else
        printf 'No identity selected.\n'
      fi
      ;;
    --new)
      require_gum
      ensure_selected_identity_for_interactive || exit 0
      if confirm_action "Start a new game?"; then
        start_new_game_flow "multiplayer"
      fi
      interactive_game
      ;;
    --local)
      require_gum
      ensure_selected_identity_for_interactive || exit 0
      if confirm_action "Start a new local game?"; then
        start_new_game_flow "local"
      fi
      interactive_game
      ;;
    "")
      interactive_game
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$action" >&2
      usage >&2
      exit 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
