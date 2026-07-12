#!/bin/bash

_oracle_row_count() {
  local owner="$1" table="$2"
  sqlplus -s /nolog <<EOF | tr -d '[:space:]'
CONNECT $SRC_USER/"$SRC_PASS"@//$SRC_HOST:${SRC_PORT:-1521}/$SRC_ORA_SERVICE
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT COUNT(*) FROM $owner.$table;
EXIT
EOF
}

copy_tables() {
  local dry_run="$1"
  local log_file="$2"
  local tables_arg="${3:-}"
  local tables=() table exists failures=0 src_count tgt_count

  if [[ -n "$tables_arg" ]]; then
    local raw=()
    IFS=', ' read -r -a raw <<< "$tables_arg"
    for table in "${raw[@]}"; do
      if [[ -n "$table" ]]; then
        tables+=("$table")
      fi
    done
  else
    read -p "Enter table names (space-separated): " -a tables
  fi

  if [[ ${#tables[@]} -eq 0 ]]; then
    echo "❌ No table names given." >&2
    return 1
  fi
  for table in "${tables[@]}"; do
    validate_identifier "$table" "table name" || return 1
  done

  if [[ "$DB_ENGINE" == "mysql" ]]; then
    local mysql_src=(mysql -h"$SRC_HOST" -P"${SRC_PORT:-3306}" -u"$SRC_USER")
    local mysql_tgt=(mysql -h"$TGT_HOST" -P"${TGT_PORT:-3306}" -u"$TGT_USER")

    # Flags differ between MySQL's and MariaDB's mysqldump — detect support.
    local dump_flags=(--single-transaction) dump_help
    dump_help=$(mysqldump --help 2>/dev/null || true)
    if grep -q -- '--set-gtid-purged' <<< "$dump_help"; then
      dump_flags+=(--set-gtid-purged=OFF)
    fi
    if grep -q -- '--no-tablespaces' <<< "$dump_help"; then
      dump_flags+=(--no-tablespaces)
    fi

    if ! MYSQL_PWD="$TGT_PASS" "${mysql_tgt[@]}" -e "USE \`$TGT_DB\`;" 2>/dev/null; then
      echo "Creating DB $TGT_DB on target..."
      if [[ "$dry_run" == false ]]; then
        MYSQL_PWD="$TGT_PASS" "${mysql_tgt[@]}" -e "CREATE DATABASE \`$TGT_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
      fi
    fi

    for table in "${tables[@]}"; do
      echo "➡️  MySQL: $table"
      # information_schema gives an exact match; `SHOW TABLES LIKE | grep`
      # produced false positives on substrings and _/% wildcards.
      if ! exists=$(MYSQL_PWD="$TGT_PASS" "${mysql_tgt[@]}" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$TGT_DB' AND table_name='$table';"); then
        echo "❌ Could not check whether $table exists on the target." >&2
        return 1
      fi
      if [[ "$exists" != "0" ]]; then
        if ! confirm "Table $table exists on the target. Replace?"; then
          echo "⏭️  Skipping $table."
          continue
        fi
        if [[ "$dry_run" == false ]]; then
          # FOREIGN_KEY_CHECKS=0 (session-scoped): allow replacing a table
          # that other tables reference; their FKs re-attach to the new copy.
          MYSQL_PWD="$TGT_PASS" "${mysql_tgt[@]}" -e "SET FOREIGN_KEY_CHECKS=0; DROP TABLE \`$TGT_DB\`.\`$table\`;"
        fi
      fi

      if [[ "$dry_run" == true ]]; then
        echo "Would copy $table ($SRC_HOST/$SRC_DB → $TGT_HOST/$TGT_DB)"
        continue
      fi

      # mysqldump | mysql works both same-server and cross-server, and
      # (unlike CREATE TABLE ... LIKE) carries indexes, FKs and triggers.
      if MYSQL_PWD="$SRC_PASS" mysqldump -h"$SRC_HOST" -P"${SRC_PORT:-3306}" -u"$SRC_USER" \
           "${dump_flags[@]}" "$SRC_DB" "$table" \
           | MYSQL_PWD="$TGT_PASS" "${mysql_tgt[@]}" "$TGT_DB"; then
        src_count=$(MYSQL_PWD="$SRC_PASS" "${mysql_src[@]}" -N -e "SELECT COUNT(*) FROM \`$SRC_DB\`.\`$table\`;")
        tgt_count=$(MYSQL_PWD="$TGT_PASS" "${mysql_tgt[@]}" -N -e "SELECT COUNT(*) FROM \`$TGT_DB\`.\`$table\`;")
        report_copy_result "$table" "$src_count" "$tgt_count" "$log_file" || failures=$((failures + 1))
      else
        echo "❌ Failed to copy $table" >&2
        echo "$(date '+%F %T') | FAILED $table" >> "$log_file"
        failures=$((failures + 1))
      fi
    done

  elif [[ "$DB_ENGINE" == "postgresql" ]]; then
    local src_port="${SRC_PORT:-5432}" tgt_port="${TGT_PORT:-5432}"
    local psql_src=(psql -h "$SRC_HOST" -p "$src_port" -U "$SRC_USER" -v ON_ERROR_STOP=1)
    local psql_tgt=(psql -h "$TGT_HOST" -p "$tgt_port" -U "$TGT_USER" -v ON_ERROR_STOP=1)

    local db_exists=true
    if ! PGPASSWORD="$TGT_PASS" "${psql_tgt[@]}" -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$TGT_DB';" | grep -q 1; then
      db_exists=false
      echo "Creating PostgreSQL DB $TGT_DB on target..."
      if [[ "$dry_run" == false ]]; then
        PGPASSWORD="$TGT_PASS" "${psql_tgt[@]}" -d postgres -q -c "CREATE DATABASE \"$TGT_DB\";"
        db_exists=true
      fi
    fi

    for table in "${tables[@]}"; do
      echo "➡️  PostgreSQL: $table"
      exists=""
      if [[ "$db_exists" == true ]]; then
        if ! exists=$(PGPASSWORD="$TGT_PASS" "${psql_tgt[@]}" -d "$TGT_DB" -Atc "SELECT to_regclass('\"$TGT_SCHEMA\".\"$table\"');"); then
          echo "❌ Could not check whether $table exists on the target." >&2
          return 1
        fi
      fi
      if [[ -n "$exists" && "$exists" != "NULL" ]]; then
        if ! confirm "Table $table exists on the target. Replace?"; then
          echo "⏭️  Skipping $table."
          continue
        fi
        if [[ "$dry_run" == false ]]; then
          PGPASSWORD="$TGT_PASS" "${psql_tgt[@]}" -d "$TGT_DB" -q -c "DROP TABLE \"$TGT_SCHEMA\".\"$table\";"
        fi
      fi

      if [[ "$dry_run" == true ]]; then
        echo "Would copy $table ($SRC_HOST/$SRC_DB → $TGT_HOST/$TGT_DB, schema $TGT_SCHEMA)"
        continue
      fi

      # The old `sed s/SET search_path .../` remap silently stopped working on
      # pg_dump >= 11 (which emits schema-qualified DDL instead). Restore into
      # the schema the dump names (public), then move the table if needed.
      local copy_ok=true
      PGPASSWORD="$SRC_PASS" pg_dump -h "$SRC_HOST" -p "$src_port" -U "$SRC_USER" \
          -t "public.\"$table\"" "$SRC_DB" \
        | PGPASSWORD="$TGT_PASS" "${psql_tgt[@]}" -q -d "$TGT_DB" > /dev/null || copy_ok=false
      if [[ "$copy_ok" == true && "$TGT_SCHEMA" != "public" ]]; then
        PGPASSWORD="$TGT_PASS" "${psql_tgt[@]}" -q -d "$TGT_DB" \
          -c "CREATE SCHEMA IF NOT EXISTS \"$TGT_SCHEMA\";" \
          -c "ALTER TABLE public.\"$table\" SET SCHEMA \"$TGT_SCHEMA\";" || copy_ok=false
      fi

      if [[ "$copy_ok" == true ]]; then
        src_count=$(PGPASSWORD="$SRC_PASS" "${psql_src[@]}" -d "$SRC_DB" -Atc "SELECT count(*) FROM public.\"$table\";")
        tgt_count=$(PGPASSWORD="$TGT_PASS" "${psql_tgt[@]}" -d "$TGT_DB" -Atc "SELECT count(*) FROM \"$TGT_SCHEMA\".\"$table\";")
        report_copy_result "$table" "$src_count" "$tgt_count" "$log_file" || failures=$((failures + 1))
      else
        echo "❌ Failed to copy $table" >&2
        echo "$(date '+%F %T') | FAILED $table" >> "$log_file"
        failures=$((failures + 1))
      fi
    done

  elif [[ "$DB_ENGINE" == "oracle" ]]; then
    if [[ "$SRC_HOST" != "$TGT_HOST" || "${SRC_PORT:-1521}" != "${TGT_PORT:-1521}" \
          || "$SRC_ORA_SERVICE" != "$TGT_ORA_SERVICE" || "$SRC_USER" != "$TGT_USER" ]]; then
      echo "❌ Oracle copies are only supported within a single server/service (Data Pump via DATA_PUMP_DIR)." >&2
      echo "   For cross-server transfers use impdp with NETWORK_LINK, or copy the dump file manually." >&2
      return 1
    fi

    echo "📦 Oracle (Data Pump):"
    local ora_conn="$SRC_USER@//$SRC_HOST:${SRC_PORT:-1521}/$SRC_ORA_SERVICE"

    for table in "${tables[@]}"; do
      echo "➡️  Oracle: $table"
      if [[ "$dry_run" == true ]]; then
        echo "Would export/import $table via Data Pump"
        continue
      fi
      # Password is fed on stdin so it never appears in the process list.
      if expdp "$ora_conn" tables="$table" dumpfile="${DUMP_FILE}_${table}.dmp" \
           directory=DATA_PUMP_DIR logfile="exp_${table}.log" reuse_dumpfiles=y <<< "$SRC_PASS" &&
         impdp "$ora_conn" tables="$table" dumpfile="${DUMP_FILE}_${table}.dmp" \
           directory=DATA_PUMP_DIR logfile="imp_${table}.log" remap_schema="$SRC_DB:$TGT_DB" <<< "$SRC_PASS"; then
        src_count=$(_oracle_row_count "$SRC_DB" "$table")
        tgt_count=$(_oracle_row_count "$TGT_DB" "$table")
        report_copy_result "$table" "$src_count" "$tgt_count" "$log_file" || failures=$((failures + 1))
      else
        echo "❌ Failed to copy $table" >&2
        echo "$(date '+%F %T') | FAILED $table" >> "$log_file"
        failures=$((failures + 1))
      fi
    done
  fi

  if [[ $failures -gt 0 ]]; then
    echo "❌ Table copy finished with $failures failure(s) — see $log_file." >&2
    return 1
  fi
  echo "✅ Table copy complete."
}
