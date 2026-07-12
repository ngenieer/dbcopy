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
  case "$DB_ENGINE" in
    mysql|postgresql|oracle) ;;
    *)
      echo "❌ Unsupported db_engine: '$DB_ENGINE' (expected mysql/postgresql/oracle)" >&2
      return 1
      ;;
  esac

  validate_hostname "$SRC_HOST" "source host" || return 1
  validate_hostname "$TGT_HOST" "target host" || return 1
  validate_port "$SRC_PORT" || return 1
  validate_port "$TGT_PORT" || return 1
  validate_identifier "$SRC_DB" "source database name" || return 1
  validate_identifier "$TGT_DB" "target database name" || return 1

  if [[ "$DB_ENGINE" == "postgresql" ]]; then
    validate_identifier "${TGT_SCHEMA:-public}" "target schema" || return 1
  elif [[ "$DB_ENGINE" == "oracle" ]]; then
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
