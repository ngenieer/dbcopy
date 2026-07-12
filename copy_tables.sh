#!/bin/bash

copy_tables() {
  local dry_run="$1"
  local log_file="$2"
  local tables=() table exists y

  read -p "Enter table names (space-separated): " -a tables
  if [[ ${#tables[@]} -eq 0 ]]; then
    echo "❌ No table names given." >&2
    return 1
  fi
  for table in "${tables[@]}"; do
    validate_identifier "$table" "table name" || return 1
  done

  if [[ "$DB_ENGINE" == "mysql" ]]; then
    local mysql_cmd=(mysql -h"$DB_HOST" -P"${DB_PORT:-3306}" -u"$DB_USER")
    export MYSQL_PWD="$DB_PASS"

    if ! "${mysql_cmd[@]}" -e "USE \`$TGT_DB\`;" 2>/dev/null; then
      echo "Creating DB $TGT_DB..."
      if [[ "$dry_run" == false ]]; then
        "${mysql_cmd[@]}" -e "CREATE DATABASE \`$TGT_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
      fi
    fi

    for table in "${tables[@]}"; do
      echo "➡️  MySQL: $table"
      # information_schema gives an exact match; `SHOW TABLES LIKE | grep`
      # produced false positives on substrings and _/% wildcards.
      if ! exists=$("${mysql_cmd[@]}" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$TGT_DB' AND table_name='$table';"); then
        echo "❌ Could not check whether $table exists." >&2
        return 1
      fi
      if [[ "$exists" != "0" ]]; then
        read -p "Table $table exists. Replace? (y/n): " y
        if [[ ! "$y" =~ ^[Yy]$ ]]; then
          echo "⏭️  Skipping $table."
          continue
        fi
        if [[ "$dry_run" == false ]]; then
          "${mysql_cmd[@]}" -e "DROP TABLE \`$TGT_DB\`.\`$table\`;"
        fi
      fi

      if [[ "$dry_run" == true ]]; then
        echo "Would copy $table"
        continue
      fi

      if "${mysql_cmd[@]}" -e "CREATE TABLE \`$TGT_DB\`.\`$table\` LIKE \`$SRC_DB\`.\`$table\`;" &&
         "${mysql_cmd[@]}" -e "INSERT INTO \`$TGT_DB\`.\`$table\` SELECT * FROM \`$SRC_DB\`.\`$table\`;"; then
        echo "$(date '+%F %T') | Copied $table" >> "$log_file"
      else
        echo "❌ Failed to copy $table" >&2
        echo "$(date '+%F %T') | FAILED $table" >> "$log_file"
      fi
    done

  elif [[ "$DB_ENGINE" == "postgresql" ]]; then
    export PGPASSWORD="$DB_PASS"
    local port="${DB_PORT:-5432}"
    local psql_cmd=(psql -h "$DB_HOST" -p "$port" -U "$DB_USER" -v ON_ERROR_STOP=1)

    local db_exists=true
    if ! "${psql_cmd[@]}" -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$TGT_DB';" | grep -q 1; then
      db_exists=false
      echo "Creating PostgreSQL DB $TGT_DB..."
      if [[ "$dry_run" == false ]]; then
        createdb -h "$DB_HOST" -p "$port" -U "$DB_USER" "$TGT_DB"
        db_exists=true
      fi
    fi

    for table in "${tables[@]}"; do
      echo "➡️  PostgreSQL: $table"
      exists=""
      if [[ "$db_exists" == true ]]; then
        if ! exists=$("${psql_cmd[@]}" -d "$TGT_DB" -Atc "SELECT to_regclass('\"$TGT_SCHEMA\".\"$table\"');"); then
          echo "❌ Could not check whether $table exists." >&2
          return 1
        fi
      fi
      if [[ -n "$exists" && "$exists" != "NULL" ]]; then
        read -p "Table $table exists. Replace? (y/n): " y
        if [[ ! "$y" =~ ^[Yy]$ ]]; then
          echo "⏭️  Skipping $table."
          continue
        fi
        if [[ "$dry_run" == false ]]; then
          "${psql_cmd[@]}" -d "$TGT_DB" -c "DROP TABLE \"$TGT_SCHEMA\".\"$table\";"
        fi
      fi

      if [[ "$dry_run" == true ]]; then
        echo "Would copy $table"
        continue
      fi

      # The old `sed s/SET search_path .../` remap silently stopped working on
      # pg_dump >= 11 (which emits schema-qualified DDL instead). Restore into
      # the schema the dump names (public), then move the table if needed.
      local copy_ok=true
      pg_dump -h "$DB_HOST" -p "$port" -U "$DB_USER" -t "public.\"$table\"" "$SRC_DB" \
        | "${psql_cmd[@]}" -q -d "$TGT_DB" || copy_ok=false
      if [[ "$copy_ok" == true && "$TGT_SCHEMA" != "public" ]]; then
        "${psql_cmd[@]}" -q -d "$TGT_DB" \
          -c "CREATE SCHEMA IF NOT EXISTS \"$TGT_SCHEMA\";" \
          -c "ALTER TABLE public.\"$table\" SET SCHEMA \"$TGT_SCHEMA\";" || copy_ok=false
      fi

      if [[ "$copy_ok" == true ]]; then
        echo "$(date '+%F %T') | Copied $table" >> "$log_file"
      else
        echo "❌ Failed to copy $table" >&2
        echo "$(date '+%F %T') | FAILED $table" >> "$log_file"
      fi
    done

  elif [[ "$DB_ENGINE" == "oracle" ]]; then
    echo "📦 Oracle (Data Pump):"
    local ora_conn="$DB_USER@//$DB_HOST:${DB_PORT:-1521}/$ORA_SERVICE"

    for table in "${tables[@]}"; do
      echo "➡️  Oracle: $table"
      if [[ "$dry_run" == true ]]; then
        echo "Would export/import $table via Data Pump"
        continue
      fi
      # Password is fed on stdin so it never appears in the process list.
      if expdp "$ora_conn" tables="$table" dumpfile="${DUMP_FILE}_${table}.dmp" \
           directory=DATA_PUMP_DIR logfile="exp_${table}.log" reuse_dumpfiles=y <<< "$DB_PASS" &&
         impdp "$ora_conn" tables="$table" dumpfile="${DUMP_FILE}_${table}.dmp" \
           directory=DATA_PUMP_DIR logfile="imp_${table}.log" remap_schema="$SRC_DB:$TGT_DB" <<< "$DB_PASS"; then
        echo "$(date '+%F %T') | Oracle copied $table" >> "$log_file"
      else
        echo "❌ Failed to copy $table" >&2
        echo "$(date '+%F %T') | FAILED $table" >> "$log_file"
      fi
    done
  fi

  echo "✅ Table copy complete."
}
