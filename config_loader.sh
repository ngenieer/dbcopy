#!/bin/bash

load_config() {
  local config_file="$1"

  [[ -f "$config_file" ]] || return 1

  # Tighten permissions on configs created by older versions of this tool.
  chmod 600 "$config_file" 2>/dev/null || true

  echo "📄 Found config file: $config_file"
  sed 's/^db_pass:.*/db_pass: "********"/' "$config_file"
  read -p "Use this configuration? (y/n): " use_config
  [[ "$use_config" =~ ^[Yy]$ ]] || return 1

  DB_ENGINE=$(config_get "$config_file" db_engine)
  DB_HOST=$(config_get "$config_file" db_host)
  DB_PORT=$(config_get "$config_file" db_port)
  DB_USER=$(config_get "$config_file" db_user)
  DB_PASS=$(config_get "$config_file" db_pass)
  SRC_DB=$(config_get "$config_file" source_db)
  TGT_DB=$(config_get "$config_file" target_db)
  TGT_SCHEMA=$(config_get "$config_file" target_schema)
  ORA_SERVICE=$(config_get "$config_file" ora_service)
  DUMP_FILE=$(config_get "$config_file" dump_file)
  return 0
}
