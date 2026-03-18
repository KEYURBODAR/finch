#!/bin/sh
set -eu

APP_USER="${APP_USER:-nitter}"
APP_GROUP="${APP_GROUP:-nitter}"
APP_CMD="${APP_CMD:-./nitter}"
SESSION_DIR="/tmp/finch"
SESSION_FILE="$SESSION_DIR/sessions.jsonl"

prepare_runtime_path() {
  target_path="${1:-}"
  if [ -z "$target_path" ]; then
    return 0
  fi

  target_dir=$(dirname "$target_path")
  mkdir -p "$target_dir"

  if [ "$(id -u)" = "0" ]; then
    chown -R "$APP_USER:$APP_GROUP" "$target_dir"
  fi
}

write_sessions() {
  umask 077
  target_file="${NITTER_SESSIONS_FILE:-$SESSION_FILE}"
  target_dir=$(dirname "$target_file")
  target_tmp="$target_file.tmp"
  mkdir -p "$target_dir"

  if [ "$(id -u)" = "0" ]; then
    chown -R "$APP_USER:$APP_GROUP" "$target_dir"
  fi

  if [ -n "${NITTER_SESSIONS_JSONL_B64:-}" ]; then
    printf '%s' "$NITTER_SESSIONS_JSONL_B64" | base64 -d > "$target_tmp"
    mv "$target_tmp" "$target_file"
    export NITTER_SESSIONS_FILE="$target_file"
  elif [ -n "${NITTER_SESSIONS_JSONL:-}" ]; then
    printf '%s\n' "$NITTER_SESSIONS_JSONL" > "$target_tmp"
    mv "$target_tmp" "$target_file"
    export NITTER_SESSIONS_FILE="$target_file"
  elif [ -n "${NITTER_SESSIONS_FILE:-}" ] && [ ! -f "$NITTER_SESSIONS_FILE" ]; then
    echo "Missing session file: $NITTER_SESSIONS_FILE" >&2
    exit 1
  fi
}

mkdir -p "$SESSION_DIR"

if [ "$(id -u)" = "0" ]; then
  chown -R "$APP_USER:$APP_GROUP" "$SESSION_DIR"
fi

prepare_runtime_path "${NITTER_LOCAL_DATA_PATH:-}"
write_sessions

if [ "$(id -u)" = "0" ]; then
  exec su-exec "$APP_USER:$APP_GROUP" "$APP_CMD"
fi

exec "$APP_CMD"
