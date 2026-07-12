#!/bin/bash

load_config() {
  local config_file="$1"

  [[ -f "$config_file" ]] || return 1

  # Tighten permissions on configs created by older versions of this tool.
  chmod 600 "$config_file" 2>/dev/null || true

  echo "📄 Found config file: $config_file"
  sed -E 's/^(db_pass|src_pass|tgt_pass):.*/\1: "********"/' "$config_file"
  confirm "Use this configuration?" || return 1

  DB_ENGINE=$(config_get "$config_file" db_engine)
  SRC_ENGINE=$(config_get "$config_file" src_engine)
  TGT_ENGINE=$(config_get "$config_file" tgt_engine)
  SRC_ENGINE="${SRC_ENGINE:-$DB_ENGINE}"
  TGT_ENGINE="${TGT_ENGINE:-$DB_ENGINE}"
  DB_ENGINE="${DB_ENGINE:-$SRC_ENGINE}"

  if grep -q '^db_host:' "$config_file"; then
    # Legacy single-server format: one connection serves as source and target.
    echo "ℹ️  Legacy config format detected — using one server as both source and target."
    SRC_HOST=$(config_get "$config_file" db_host);  TGT_HOST="$SRC_HOST"
    SRC_PORT=$(config_get "$config_file" db_port);  TGT_PORT="$SRC_PORT"
    SRC_USER=$(config_get "$config_file" db_user);  TGT_USER="$SRC_USER"
    SRC_PASS=$(config_get "$config_file" db_pass);  TGT_PASS="$SRC_PASS"
    SRC_DB=$(config_get "$config_file" source_db)
    TGT_DB=$(config_get "$config_file" target_db)
    TGT_SCHEMA=$(config_get "$config_file" target_schema)
    SRC_ORA_SERVICE=$(config_get "$config_file" ora_service)
    TGT_ORA_SERVICE="$SRC_ORA_SERVICE"
    DUMP_FILE=$(config_get "$config_file" dump_file)
  else
    SRC_HOST=$(config_get "$config_file" src_host)
    SRC_PORT=$(config_get "$config_file" src_port)
    SRC_USER=$(config_get "$config_file" src_user)
    SRC_PASS=$(config_get "$config_file" src_pass)
    SRC_DB=$(config_get "$config_file" src_db)
    TGT_HOST=$(config_get "$config_file" tgt_host)
    TGT_PORT=$(config_get "$config_file" tgt_port)
    TGT_USER=$(config_get "$config_file" tgt_user)
    TGT_PASS=$(config_get "$config_file" tgt_pass)
    TGT_DB=$(config_get "$config_file" tgt_db)
    TGT_SCHEMA=$(config_get "$config_file" tgt_schema)
    SRC_ORA_SERVICE=$(config_get "$config_file" src_ora_service)
    TGT_ORA_SERVICE=$(config_get "$config_file" tgt_ora_service)
    DUMP_FILE=$(config_get "$config_file" dump_file)
  fi

  return 0
}
