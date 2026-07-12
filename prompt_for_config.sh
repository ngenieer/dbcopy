#!/bin/bash

prompt_and_save_config() {
  local config_file="$1" same

  TGT_SCHEMA=""
  SRC_ORA_SERVICE=""
  TGT_ORA_SERVICE=""
  DUMP_FILE=""

  while true; do
    read -p "Enter database engine (mysql/postgresql/oracle): " DB_ENGINE
    DB_ENGINE=$(echo "$DB_ENGINE" | tr '[:upper:]' '[:lower:]')
    case "$DB_ENGINE" in
      mysql|postgresql|oracle) break ;;
      *) echo "❌ Unsupported engine: '$DB_ENGINE'" ;;
    esac
  done

  echo "-- Source connection --"
  read -p "Source host (default: localhost): " SRC_HOST
  SRC_HOST=${SRC_HOST:-localhost}
  read -p "Source port (optional): " SRC_PORT
  read -p "Source username: " SRC_USER
  read -s -p "Source password: " SRC_PASS; echo
  read -p "Source database: " SRC_DB
  if [[ "$DB_ENGINE" == "oracle" ]]; then
    read -p "Source Oracle service name (e.g. ORCL): " SRC_ORA_SERVICE
  fi

  echo "-- Target connection --"
  read -p "Is the target on the same server with the same credentials? (y/n): " same
  if [[ "$same" =~ ^[Yy]$ ]]; then
    TGT_HOST="$SRC_HOST"
    TGT_PORT="$SRC_PORT"
    TGT_USER="$SRC_USER"
    TGT_PASS="$SRC_PASS"
    TGT_ORA_SERVICE="$SRC_ORA_SERVICE"
  else
    read -p "Target host (default: localhost): " TGT_HOST
    TGT_HOST=${TGT_HOST:-localhost}
    read -p "Target port (optional): " TGT_PORT
    read -p "Target username: " TGT_USER
    read -s -p "Target password: " TGT_PASS; echo
    if [[ "$DB_ENGINE" == "oracle" ]]; then
      read -p "Target Oracle service name (e.g. ORCL): " TGT_ORA_SERVICE
    fi
  fi
  read -p "Target database: " TGT_DB

  if [[ "$DB_ENGINE" == "postgresql" ]]; then
    read -p "Target schema (default: public): " TGT_SCHEMA
    TGT_SCHEMA=${TGT_SCHEMA:-public}
  elif [[ "$DB_ENGINE" == "oracle" ]]; then
    read -p "Oracle dump file name (without .dmp): " DUMP_FILE
  fi

  # umask 077 (in a subshell) + chmod: the file is never world-readable,
  # even for an instant — it holds plain-text passwords.
  (
    umask 077
    cat > "$config_file" <<EOF
db_engine: "$DB_ENGINE"
src_host: "$SRC_HOST"
src_port: "$SRC_PORT"
src_user: "$SRC_USER"
src_pass: "$SRC_PASS"
src_db: "$SRC_DB"
tgt_host: "$TGT_HOST"
tgt_port: "$TGT_PORT"
tgt_user: "$TGT_USER"
tgt_pass: "$TGT_PASS"
tgt_db: "$TGT_DB"
tgt_schema: "${TGT_SCHEMA:-public}"
src_ora_service: "$SRC_ORA_SERVICE"
tgt_ora_service: "$TGT_ORA_SERVICE"
dump_file: "$DUMP_FILE"
EOF
  )
  chmod 600 "$config_file"
  echo "🔒 Saved config to $config_file (mode 600). Note: passwords are stored in plain text — keep this file out of version control."
}
