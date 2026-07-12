#!/bin/bash

# Read a value from the flat YAML config this tool generates (key: "value").
# Avoids yq entirely: the two common yq implementations (mikefarah Go yq vs
# kislyuk Python yq) disagree on quoting, which silently broke connections.
config_get() {
  local file="$1" key="$2"
  sed -n "s/^${key}:[[:space:]]*\"\(.*\)\"[[:space:]]*$/\1/p" "$file" | head -n 1
}

# Ask a y/n question; --yes answers everything with yes.
confirm() {
  local prompt="$1" reply
  if [[ "${ASSUME_YES:-false}" == true ]]; then
    echo "$prompt (y/n): y  [--yes]"
    return 0
  fi
  read -p "$prompt (y/n): " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# Compare source/target row counts after a copy and log the outcome.
report_copy_result() {
  local table="$1" src_count="$2" tgt_count="$3" log_file="$4"
  if [[ -n "$src_count" && "$src_count" == "$tgt_count" ]]; then
    echo "✅ $table: copied and verified ($tgt_count rows)"
    echo "$(date '+%F %T') | Copied $table ($tgt_count rows, verified)" >> "$log_file"
    return 0
  fi
  echo "⚠️  $table: row count mismatch (source=$src_count, target=$tgt_count)" >&2
  echo "$(date '+%F %T') | MISMATCH $table src=$src_count tgt=$tgt_count" >> "$log_file"
  return 1
}

# Run "$1 <table>" for every table in the ambient `tables` array — either
# sequentially or in parallel batches of $2. Parallel jobs buffer their
# output and print it as each batch completes, so lines don't interleave.
# Increments the ambient `failures` counter.
_run_tables() {
  local fn="$1" jobs="${2:-1}" table
  if (( jobs <= 1 )); then
    for table in "${tables[@]}"; do
      "$fn" "$table" || failures=$((failures + 1))
    done
    return 0
  fi

  echo "⚡ Copying with up to $jobs parallel jobs."
  local i=0 j pids=() outs=() out
  while (( i < ${#tables[@]} )); do
    pids=()
    outs=()
    for table in "${tables[@]:i:jobs}"; do
      out=$(mktemp)
      "$fn" "$table" > "$out" 2>&1 &
      pids+=("$!")
      outs+=("$out")
    done
    for j in "${!pids[@]}"; do
      if ! wait "${pids[j]}"; then
        failures=$((failures + 1))
      fi
      cat "${outs[j]}"
      rm -f "${outs[j]}"
    done
    i=$((i + jobs))
  done
  return 0
}

# Whitelist validation — these values are interpolated into SQL statements
# and Oracle connect strings, so anything outside the whitelist is rejected.
validate_identifier() {
  local value="$1" what="$2"
  if [[ ! "$value" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "❌ Invalid $what: '$value' (only letters, digits and _ are allowed)" >&2
    return 1
  fi
}

validate_hostname() {
  local value="$1" what="$2"
  if [[ ! "$value" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "❌ Invalid $what: '$value'" >&2
    return 1
  fi
}

validate_port() {
  local value="$1"
  if [[ -n "$value" && ! "$value" =~ ^[0-9]+$ ]]; then
    echo "❌ Invalid port: '$value'" >&2
    return 1
  fi
}

# Validate everything loaded from config or prompts before it is used.
validate_config() {
  local e
  SRC_ENGINE="${SRC_ENGINE:-$DB_ENGINE}"
  TGT_ENGINE="${TGT_ENGINE:-$DB_ENGINE}"

  for e in "$SRC_ENGINE" "$TGT_ENGINE"; do
    case "$e" in
      mysql|postgresql|oracle|sqlite) ;;
      *)
        echo "❌ Unsupported engine: '$e' (expected mysql/postgresql/oracle/sqlite)" >&2
        return 1
        ;;
    esac
  done

  if [[ "$SRC_ENGINE" != "$TGT_ENGINE" ]]; then
    if [[ "$SRC_ENGINE" == "oracle" || "$TGT_ENGINE" == "oracle" ]]; then
      echo "❌ Cross-engine copies involving Oracle are not supported." >&2
      return 1
    fi
  fi

  # Source side
  if [[ "$SRC_ENGINE" == "sqlite" ]]; then
    if [[ -z "$SRC_DB" ]]; then
      echo "❌ SQLite source requires a database file path (src_db)." >&2
      return 1
    fi
  else
    validate_hostname "$SRC_HOST" "source host" || return 1
    validate_port "$SRC_PORT" || return 1
    validate_identifier "$SRC_DB" "source database name" || return 1
  fi

  # Target side
  if [[ "$TGT_ENGINE" == "sqlite" ]]; then
    if [[ -z "$TGT_DB" ]]; then
      echo "❌ SQLite target requires a database file path (tgt_db)." >&2
      return 1
    fi
  else
    validate_hostname "$TGT_HOST" "target host" || return 1
    validate_port "$TGT_PORT" || return 1
    validate_identifier "$TGT_DB" "target database name" || return 1
  fi

  if [[ "$SRC_ENGINE" == "sqlite" && "$TGT_ENGINE" == "sqlite" && "$SRC_DB" == "$TGT_DB" ]]; then
    echo "❌ SQLite source and target must be different files." >&2
    return 1
  fi

  if [[ "$TGT_ENGINE" == "postgresql" ]]; then
    validate_identifier "${TGT_SCHEMA:-public}" "target schema" || return 1
  fi

  if [[ "$SRC_ENGINE" == "oracle" ]]; then
    # Usernames end up inside a sqlplus script / connect string for Oracle.
    # The regex lives in a variable so $# isn't expanded inside [[ =~ ]].
    local u ora_user_re='^[A-Za-z0-9_$#]+$'
    for u in "$SRC_USER" "$TGT_USER"; do
      if [[ ! "$u" =~ $ora_user_re ]]; then
        echo "❌ Invalid Oracle username: '$u'" >&2
        return 1
      fi
    done
    validate_hostname "$SRC_ORA_SERVICE" "source Oracle service name" || return 1
    validate_hostname "$TGT_ORA_SERVICE" "target Oracle service name" || return 1
    validate_identifier "$DUMP_FILE" "dump file name" || return 1
  fi

  return 0
}
