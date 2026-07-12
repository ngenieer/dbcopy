#!/bin/bash

prompt_and_save_config() {
  local config_file="$1"

  TGT_SCHEMA=""
  ORA_SERVICE=""
  DUMP_FILE=""

  while true; do
    read -p "Enter database engine (mysql/postgresql/oracle): " DB_ENGINE
    DB_ENGINE=$(echo "$DB_ENGINE" | tr '[:upper:]' '[:lower:]')
    case "$DB_ENGINE" in
      mysql|postgresql|oracle) break ;;
      *) echo "❌ Unsupported engine: '$DB_ENGINE'" ;;
    esac
  done

  read -p "Enter host (default: localhost): " DB_HOST
  DB_HOST=${DB_HOST:-localhost}
  read -p "Enter port (optional): " DB_PORT
  read -p "Enter DB username: " DB_USER
  read -s -p "Enter DB password: " DB_PASS; echo
  read -p "Enter source database: " SRC_DB
  read -p "Enter target database: " TGT_DB

  if [[ "$DB_ENGINE" == "postgresql" ]]; then
    read -p "Enter target schema (default: public): " TGT_SCHEMA
    TGT_SCHEMA=${TGT_SCHEMA:-public}
  elif [[ "$DB_ENGINE" == "oracle" ]]; then
    read -p "Enter Oracle service name (e.g. ORCL): " ORA_SERVICE
    read -p "Enter Oracle dump file name (without .dmp): " DUMP_FILE
  fi

  # umask 077 (in a subshell) + chmod: the file is never world-readable,
  # even for an instant — it holds a plain-text password.
  (
    umask 077
    cat > "$config_file" <<EOF
db_engine: "$DB_ENGINE"
db_host: "$DB_HOST"
db_port: "$DB_PORT"
db_user: "$DB_USER"
db_pass: "$DB_PASS"
source_db: "$SRC_DB"
target_db: "$TGT_DB"
target_schema: "${TGT_SCHEMA:-public}"
ora_service: "${ORA_SERVICE:-}"
dump_file: "${DUMP_FILE:-}"
EOF
  )
  chmod 600 "$config_file"
  echo "🔒 Saved config to $config_file (mode 600). Note: the password is stored in plain text — keep this file out of version control."
}
