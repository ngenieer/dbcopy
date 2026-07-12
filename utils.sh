#!/bin/bash

# Read a value from the flat YAML config this tool generates (key: "value").
# Avoids yq entirely: the two common yq implementations (mikefarah Go yq vs
# kislyuk Python yq) disagree on quoting, which silently broke connections.
config_get() {
  local file="$1" key="$2"
  sed -n "s/^${key}:[[:space:]]*\"\(.*\)\"[[:space:]]*$/\1/p" "$file" | head -n 1
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

  validate_hostname "$DB_HOST" "host" || return 1
  validate_port "$DB_PORT" || return 1
  validate_identifier "$SRC_DB" "source database name" || return 1
  validate_identifier "$TGT_DB" "target database name" || return 1

  if [[ "$DB_ENGINE" == "postgresql" ]]; then
    validate_identifier "${TGT_SCHEMA:-public}" "target schema" || return 1
  elif [[ "$DB_ENGINE" == "oracle" ]]; then
    # DB_USER ends up inside a sqlplus script / connect string for Oracle.
    if [[ ! "$DB_USER" =~ ^[A-Za-z0-9_$#]+$ ]]; then
      echo "❌ Invalid Oracle username: '$DB_USER'" >&2
      return 1
    fi
    validate_hostname "$ORA_SERVICE" "Oracle service name" || return 1
    validate_identifier "$DUMP_FILE" "dump file name" || return 1
  fi

  return 0
}
