#!/bin/bash

_oracle_table_exists() { # $1=owner $2=table -> 0/1
  sqlplus -s /nolog <<EOF | tr -d '[:space:]'
CONNECT $SRC_USER/"$SRC_PASS"@//$SRC_HOST:${SRC_PORT:-1521}/$SRC_ORA_SERVICE
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT COUNT(*) FROM all_tables WHERE owner = UPPER('$1') AND table_name = UPPER('$2');
EXIT
EOF
}

_oracle_row_count() {
  local owner="$1" table="$2"
  sqlplus -s /nolog <<EOF | tr -d '[:space:]'
CONNECT $SRC_USER/"$SRC_PASS"@//$SRC_HOST:${SRC_PORT:-1521}/$SRC_ORA_SERVICE
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT COUNT(*) FROM $owner.$table;
EXIT
EOF
}

# List all base tables in the source database, one per line.
_list_source_tables() {
  case "$SRC_ENGINE" in
    mysql)
      _cross_mysql_src -B -N -e "SELECT table_name FROM information_schema.tables WHERE table_schema='$SRC_DB' AND table_type='BASE TABLE' ORDER BY table_name;"
      ;;
    postgresql)
      _cross_psql_src -d "$SRC_DB" -Atc "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;"
      ;;
    sqlite)
      sqlite3 -readonly "$SRC_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
      ;;
    oracle)
      sqlplus -s /nolog <<EOF | sed '/^$/d'
CONNECT $SRC_USER/"$SRC_PASS"@//$SRC_HOST:${SRC_PORT:-1521}/$SRC_ORA_SERVICE
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT table_name FROM all_tables WHERE owner = UPPER('$SRC_DB') ORDER BY table_name;
EXIT
EOF
      ;;
  esac
}

copy_tables() {
  local dry_run="$1"
  local log_file="$2"
  local tables_arg="${3:-}"
  local tables=() table exists failures=0 src_count tgt_count
  local where_sql=""
  if [[ -n "${WHERE_CLAUSE:-}" ]]; then
    where_sql=" WHERE $WHERE_CLAUSE"
  fi

  if [[ "${ALL_TABLES:-false}" == true ]]; then
    local list
    if ! list=$(_list_source_tables); then
      echo "❌ Could not list tables from the source." >&2
      return 1
    fi
    while IFS= read -r table; do
      if [[ -n "$table" ]]; then
        tables+=("$table")
      fi
    done <<< "$list"
    echo "📋 Selected ${#tables[@]} table(s) from the source."
  elif [[ -n "$tables_arg" ]]; then
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

  if [[ "$SRC_ENGINE" != "$TGT_ENGINE" ]]; then
    _cross_copy_tables "$dry_run" "$log_file" "${tables[@]}"
    return $?
  fi

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
    if [[ -n "${WHERE_CLAUSE:-}" ]]; then
      dump_flags+=(--where="$WHERE_CLAUSE")
    fi
    if [[ "${SCHEMA_ONLY:-false}" == true ]]; then
      dump_flags+=(--no-data)
    fi
    if [[ "${DATA_ONLY:-false}" == true ]]; then
      dump_flags+=(--no-create-info)
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
      if [[ "${DATA_ONLY:-false}" == true ]]; then
        if [[ "$exists" == "0" ]]; then
          echo "❌ $table does not exist on the target (--data-only needs the schema in place)." >&2
          echo "$(date '+%F %T') | FAILED $table (data-only, no target table)" >> "$log_file"
          failures=$((failures + 1))
          continue
        fi
        if ! confirm "Data-only: truncate $table on the target before loading?"; then
          echo "⏭️  Skipping $table."
          continue
        fi
        if [[ "$dry_run" == false ]]; then
          if ! MYSQL_PWD="$TGT_PASS" "${mysql_tgt[@]}" -e "TRUNCATE TABLE \`$TGT_DB\`.\`$table\`;"; then
            echo "❌ Failed to truncate $table on the target." >&2
            failures=$((failures + 1))
            continue
          fi
        fi
      elif [[ "$exists" != "0" ]]; then
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
        if [[ "${SCHEMA_ONLY:-false}" == true ]]; then
          echo "✅ $table: schema created"
          echo "$(date '+%F %T') | Schema $table" >> "$log_file"
        else
          src_count=$(MYSQL_PWD="$SRC_PASS" "${mysql_src[@]}" -N -e "SELECT COUNT(*) FROM \`$SRC_DB\`.\`$table\`$where_sql;")
          tgt_count=$(MYSQL_PWD="$TGT_PASS" "${mysql_tgt[@]}" -N -e "SELECT COUNT(*) FROM \`$TGT_DB\`.\`$table\`;")
          report_copy_result "$table" "$src_count" "$tgt_count" "$log_file" || failures=$((failures + 1))
        fi
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
      if [[ "${DATA_ONLY:-false}" == true ]]; then
        if [[ -z "$exists" || "$exists" == "NULL" ]]; then
          echo "❌ $table does not exist on the target (--data-only needs the schema in place)." >&2
          echo "$(date '+%F %T') | FAILED $table (data-only, no target table)" >> "$log_file"
          failures=$((failures + 1))
          continue
        fi
        if ! confirm "Data-only: truncate $table on the target before loading?"; then
          echo "⏭️  Skipping $table."
          continue
        fi
        if [[ "$dry_run" == false ]]; then
          if ! PGPASSWORD="$TGT_PASS" "${psql_tgt[@]}" -d "$TGT_DB" -q -c "TRUNCATE \"$TGT_SCHEMA\".\"$table\";"; then
            echo "❌ Failed to truncate $table on the target." >&2
            failures=$((failures + 1))
            continue
          fi
        fi
      elif [[ -n "$exists" && "$exists" != "NULL" ]]; then
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
      if [[ "${DATA_ONLY:-false}" != true ]]; then
        local dump_args=(-h "$SRC_HOST" -p "$src_port" -U "$SRC_USER" -t "public.\"$table\"")
        # With --where the data is loaded separately via COPY (SELECT ...).
        if [[ "${SCHEMA_ONLY:-false}" == true || -n "$where_sql" ]]; then
          dump_args+=(--schema-only)
        fi
        PGPASSWORD="$SRC_PASS" pg_dump "${dump_args[@]}" "$SRC_DB" \
          | PGPASSWORD="$TGT_PASS" "${psql_tgt[@]}" -q -d "$TGT_DB" > /dev/null || copy_ok=false
        if [[ "$copy_ok" == true && "$TGT_SCHEMA" != "public" ]]; then
          PGPASSWORD="$TGT_PASS" "${psql_tgt[@]}" -q -d "$TGT_DB" \
            -c "CREATE SCHEMA IF NOT EXISTS \"$TGT_SCHEMA\";" \
            -c "ALTER TABLE public.\"$table\" SET SCHEMA \"$TGT_SCHEMA\";" || copy_ok=false
        fi
      fi
      if [[ "$copy_ok" == true && "${SCHEMA_ONLY:-false}" != true \
            && ( "${DATA_ONLY:-false}" == true || -n "$where_sql" ) ]]; then
        PGPASSWORD="$SRC_PASS" "${psql_src[@]}" -d "$SRC_DB" \
            -c "COPY (SELECT * FROM public.\"$table\"$where_sql) TO STDOUT" \
          | PGPASSWORD="$TGT_PASS" "${psql_tgt[@]}" -q -d "$TGT_DB" \
            -c "\\copy \"$TGT_SCHEMA\".\"$table\" FROM STDIN" || copy_ok=false
      fi

      if [[ "$copy_ok" == true ]]; then
        if [[ "${SCHEMA_ONLY:-false}" == true ]]; then
          echo "✅ $table: schema created"
          echo "$(date '+%F %T') | Schema $table" >> "$log_file"
        else
          src_count=$(PGPASSWORD="$SRC_PASS" "${psql_src[@]}" -d "$SRC_DB" -Atc "SELECT count(*) FROM public.\"$table\"$where_sql;")
          tgt_count=$(PGPASSWORD="$TGT_PASS" "${psql_tgt[@]}" -d "$TGT_DB" -Atc "SELECT count(*) FROM \"$TGT_SCHEMA\".\"$table\";")
          report_copy_result "$table" "$src_count" "$tgt_count" "$log_file" || failures=$((failures + 1))
        fi
      else
        echo "❌ Failed to copy $table" >&2
        echo "$(date '+%F %T') | FAILED $table" >> "$log_file"
        failures=$((failures + 1))
      fi
    done

  elif [[ "$DB_ENGINE" == "sqlite" ]]; then
    for table in "${tables[@]}"; do
      echo "➡️  SQLite: $table"

      local src_exists
      if ! src_exists=$(sqlite3 -readonly "$SRC_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$table';"); then
        echo "❌ Could not read the source database." >&2
        return 1
      fi
      if [[ "$src_exists" == "0" ]]; then
        echo "❌ Table $table not found in source $SRC_DB" >&2
        echo "$(date '+%F %T') | FAILED $table (not in source)" >> "$log_file"
        failures=$((failures + 1))
        continue
      fi

      # Opening a missing file with sqlite3 would create it, so only check
      # for the table when the target file already exists (dry-run safety).
      exists="0"
      if [[ -f "$TGT_DB" ]]; then
        if ! exists=$(sqlite3 -readonly "$TGT_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$table';"); then
          echo "❌ Could not check whether $table exists on the target." >&2
          return 1
        fi
      fi
      if [[ "${DATA_ONLY:-false}" == true ]]; then
        if [[ "$exists" == "0" ]]; then
          echo "❌ $table does not exist on the target (--data-only needs the schema in place)." >&2
          echo "$(date '+%F %T') | FAILED $table (data-only, no target table)" >> "$log_file"
          failures=$((failures + 1))
          continue
        fi
        if ! confirm "Data-only: truncate $table on the target before loading?"; then
          echo "⏭️  Skipping $table."
          continue
        fi
        if [[ "$dry_run" == false ]]; then
          if ! sqlite3 -bail "$TGT_DB" "DELETE FROM \"$table\";"; then
            echo "❌ Failed to truncate $table on the target." >&2
            failures=$((failures + 1))
            continue
          fi
        fi
      elif [[ "$exists" != "0" ]]; then
        if ! confirm "Table $table exists on the target. Replace?"; then
          echo "⏭️  Skipping $table."
          continue
        fi
        if [[ "$dry_run" == false ]]; then
          sqlite3 -bail "$TGT_DB" "DROP TABLE \"$table\";"
        fi
      fi

      if [[ "$dry_run" == true ]]; then
        echo "Would copy $table ($SRC_DB → $TGT_DB)"
        continue
      fi

      local copy_ok=true
      if [[ "${DATA_ONLY:-false}" != true ]]; then
        if [[ "${SCHEMA_ONLY:-false}" == true || -n "$where_sql" ]]; then
          # DDL from sqlite_master (table first, then its indexes/triggers).
          sqlite3 -readonly "$SRC_DB" "SELECT sql || ';' FROM sqlite_master WHERE ((type='table' AND name='$table') OR (tbl_name='$table' AND type IN ('index','trigger'))) AND sql IS NOT NULL ORDER BY CASE type WHEN 'table' THEN 0 ELSE 1 END;" \
            | sqlite3 -bail "$TGT_DB" || copy_ok=false
        else
          # .dump TABLE emits schema + data. The target file is created on
          # first write if it does not exist yet.
          sqlite3 -readonly -bail "$SRC_DB" ".dump $table" | sqlite3 -bail "$TGT_DB" || copy_ok=false
          if [[ "$copy_ok" == true ]]; then
            # .dump TABLE matches sqlite_master *names*, so separately named
            # indexes/triggers on the table are not included — copy their DDL too.
            sqlite3 -readonly "$SRC_DB" "SELECT sql || ';' FROM sqlite_master WHERE tbl_name='$table' AND type IN ('index','trigger') AND sql IS NOT NULL;" \
              | sqlite3 -bail "$TGT_DB" || copy_ok=false
          fi
        fi
      fi
      if [[ "$copy_ok" == true && "${SCHEMA_ONLY:-false}" != true \
            && ( "${DATA_ONLY:-false}" == true || -n "$where_sql" ) ]]; then
        sqlite3 -bail "$TGT_DB" "ATTACH DATABASE '$SRC_DB' AS dbsrc; INSERT INTO \"$table\" SELECT * FROM dbsrc.\"$table\"$where_sql;" || copy_ok=false
      fi

      if [[ "$copy_ok" == true ]]; then
        if [[ "${SCHEMA_ONLY:-false}" == true ]]; then
          echo "✅ $table: schema created"
          echo "$(date '+%F %T') | Schema $table" >> "$log_file"
        else
          src_count=$(sqlite3 -readonly "$SRC_DB" "SELECT COUNT(*) FROM \"$table\"$where_sql;")
          tgt_count=$(sqlite3 -readonly "$TGT_DB" "SELECT COUNT(*) FROM \"$table\";")
          report_copy_result "$table" "$src_count" "$tgt_count" "$log_file" || failures=$((failures + 1))
        fi
      else
        echo "❌ Failed to copy $table" >&2
        echo "$(date '+%F %T') | FAILED $table" >> "$log_file"
        failures=$((failures + 1))
      fi
    done

  elif [[ "$DB_ENGINE" == "oracle" ]]; then
    if [[ -n "${WHERE_CLAUSE:-}" || "${SCHEMA_ONLY:-false}" == true || "${DATA_ONLY:-false}" == true ]]; then
      echo "❌ --where/--schema-only/--data-only are not supported for Oracle." >&2
      return 1
    fi
    if [[ "$SRC_HOST" != "$TGT_HOST" || "${SRC_PORT:-1521}" != "${TGT_PORT:-1521}" \
          || "$SRC_ORA_SERVICE" != "$TGT_ORA_SERVICE" || "$SRC_USER" != "$TGT_USER" ]]; then
      echo "❌ Oracle copies are only supported within a single server/service (Data Pump via DATA_PUMP_DIR)." >&2
      echo "   For cross-server transfers use impdp with NETWORK_LINK, or copy the dump file manually." >&2
      return 1
    fi

    echo "📦 Oracle (Data Pump):"
    # Credentials go into mode-600 parameter files (removed right after):
    # expdp/impdp cannot take the password on stdin, and putting it on the
    # command line would expose it in the process list.
    local ora_userid="$SRC_USER/\"$SRC_PASS\"@//$SRC_HOST:${SRC_PORT:-1521}/$SRC_ORA_SERVICE"
    local exp_par imp_par

    local table_exists_action
    for table in "${tables[@]}"; do
      echo "➡️  Oracle: $table"
      if ! exists=$(_oracle_table_exists "$TGT_DB" "$table"); then
        echo "❌ Could not check whether $table exists on the target." >&2
        return 1
      fi
      table_exists_action="skip"
      if [[ "$exists" != "0" ]]; then
        if ! confirm "Table $table exists on the target. Replace?"; then
          echo "⏭️  Skipping $table."
          continue
        fi
        table_exists_action="replace"
      fi

      if [[ "$dry_run" == true ]]; then
        echo "Would export/import $table via Data Pump"
        continue
      fi
      exp_par=$(mktemp) || return 1
      imp_par=$(mktemp) || return 1
      chmod 600 "$exp_par" "$imp_par"
      # tables= is schema-qualified: unqualified names would resolve against
      # the *connected* user's schema, not $SRC_DB.
      cat > "$exp_par" <<EOF
userid=$ora_userid
tables=$SRC_DB.$table
dumpfile=${DUMP_FILE}_${table}.dmp
directory=DATA_PUMP_DIR
logfile=exp_${table}.log
reuse_dumpfiles=y
EOF
      cat > "$imp_par" <<EOF
userid=$ora_userid
tables=$SRC_DB.$table
dumpfile=${DUMP_FILE}_${table}.dmp
directory=DATA_PUMP_DIR
logfile=imp_${table}.log
remap_schema=$SRC_DB:$TGT_DB
table_exists_action=$table_exists_action
EOF
      if expdp parfile="$exp_par" && impdp parfile="$imp_par"; then
        src_count=$(_oracle_row_count "$SRC_DB" "$table")
        tgt_count=$(_oracle_row_count "$TGT_DB" "$table")
        report_copy_result "$table" "$src_count" "$tgt_count" "$log_file" || failures=$((failures + 1))
      else
        echo "❌ Failed to copy $table" >&2
        echo "$(date '+%F %T') | FAILED $table" >> "$log_file"
        failures=$((failures + 1))
      fi
      rm -f "$exp_par" "$imp_par"
    done
  fi

  if [[ $failures -gt 0 ]]; then
    echo "❌ Table copy finished with $failures failure(s) — see $log_file." >&2
    return 1
  fi
  echo "✅ Table copy complete."
}
