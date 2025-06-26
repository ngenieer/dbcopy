#!/bin/bash

prompt_and_save_config() {
  local config_file="$1"

  read -p "Enter database engine (mysql/postgresql/oracle): " DB_ENGINE
  DB_ENGINE=$(echo "$DB_ENGINE" | tr '[:upper:]' '[:lower:]')
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
}

