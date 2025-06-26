#!/bin/bash

load_config() {
  local config_file="$1"

  if [[ -f "$config_file" ]]; then
    echo "📄 Found config file:"
    yq '.' "$config_file"
    read -p "Use this configuration? (y/n): " use_config
    if [[ "$use_config" =~ ^[Yy]$ ]]; then
      DB_ENGINE=$(yq '.db_engine' "$config_file")
      DB_HOST=$(yq '.db_host' "$config_file")
      DB_PORT=$(yq '.db_port' "$config_file")
      DB_USER=$(yq '.db_user' "$config_file")
      DB_PASS=$(yq '.db_pass' "$config_file")
      SRC_DB=$(yq '.source_db' "$config_file")
      TGT_DB=$(yq '.target_db' "$config_file")
      TGT_SCHEMA=$(yq '.target_schema' "$config_file")
      ORA_SERVICE=$(yq '.ora_service' "$config_file")
      DUMP_FILE=$(yq '.dump_file' "$config_file")
      return 0
    fi
  fi

  return 1
}

