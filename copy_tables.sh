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

# Order-independent content check: both sides stream the full table in the
# engine's own text format, sorted, and the md5 digests must match. Only
# meaningful same-engine — formats differ between engines.
_verify_checksum() { # $1=table
  local table="$1" src_sum tgt_sum
  case "$DB_ENGINE" in
    mysql)
      src_sum=$(MYSQL_PWD="$SRC_PASS" "${mysql_src[@]}" -B -N -e "SELECT * FROM \`$SRC_DB\`.\`$table\`$where_sql;" | LC_ALL=C sort | md5sum | awk '{print $1}')
      tgt_sum=$(MYSQL_PWD="$TGT_PASS" "${mysql_tgt[@]}" -B -N -e "SELECT * FROM \`$TGT_DB\`.\`$table\`;" | LC_ALL=C sort | md5sum | awk '{print $1}')
      ;;
    postgresql)
      src_sum=$(PGPASSWORD="$SRC_PASS" "${psql_src[@]}" -d "$SRC_DB" -c "COPY (SELECT * FROM public.\"$table\"$where_sql) TO STDOUT" | LC_ALL=C sort | md5sum | awk '{print $1}')
      tgt_sum=$(PGPASSWORD="$TGT_PASS" "${psql_tgt[@]}" -d "$TGT_DB" -c "COPY (SELECT * FROM \"$TGT_SCHEMA\".\"$table\") TO STDOUT" | LC_ALL=C sort | md5sum | awk '{print $1}')
      ;;
    sqlite)
      src_sum=$(sqlite3 -readonly -csv "$SRC_DB" "SELECT * FROM \"$table\"$where_sql;" | LC_ALL=C sort | md5sum | awk '{print $1}')
      tgt_sum=$(sqlite3 -readonly -csv "$TGT_DB" "SELECT * FROM \"$table\";" | LC_ALL=C sort | md5sum | awk '{print $1}')
      ;;
    *)
      echo "❌ --checksum is not supported for engine: $DB_ENGINE" >&2
      return 1
      ;;
  esac

  if [[ -n "$src_sum" && "$src_sum" == "$tgt_sum" ]]; then
    echo "🔒 $table: checksum verified ($src_sum)"
    echo "$(date '+%F %T') | Checksum OK $table $src_sum" >> "$log_file"
    return 0
  fi
  echo "⚠️  $table: checksum mismatch (source=$src_sum, target=$tgt_sum)" >&2
  echo "$(date '+%F %T') | CHECKSUM MISMATCH $table src=$src_sum tgt=$tgt_sum" >> "$log_file"
  return 1
}

# --- Per-table copy functions -------------------------------------------
# Called with the table name; everything else (connection arrays, dump
# flags, dry_run, log_file, where_sql) is inherited from copy_tables via
# bash dynamic scoping. Return 0 on success or skip, 1 on failure.

_copy_one_mysql() {
  local table="$1" exists src_count tgt_count
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
      return 1
    fi
    if ! confirm "Data-only: truncate $table on the target before loading?"; then
      echo "⏭️  Skipping $table."
      return 0
    fi
    if [[ "$dry_run" == false ]]; then
      if ! MYSQL_PWD="$TGT_PASS" "${mysql_tgt[@]}" -e "TRUNCATE TABLE \`$TGT_DB\`.\`$table\`;"; then
        echo "❌ Failed to truncate $table on the target." >&2
        return 1
      fi
    fi
  elif [[ "$exists" != "0" ]]; then
    if ! confirm "Table $table exists on the target. Replace?"; then
      echo "⏭️  Skipping $table."
      return 0
    fi
    if [[ "$dry_run" == false ]]; then
      # FOREIGN_KEY_CHECKS=0 (session-scoped): allow replacing a table
      # that other tables reference; their FKs re-attach to the new copy.
      MYSQL_PWD="$TGT_PASS" "${mysql_tgt[@]}" -e "SET FOREIGN_KEY_CHECKS=0; DROP TABLE \`$TGT_DB\`.\`$table\`;"
    fi
  fi

  if [[ "$dry_run" == true ]]; then
    echo "Would copy $table ($SRC_HOST/$SRC_DB → $TGT_HOST/$TGT_DB)"
    return 0
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
      report_copy_result "$table" "$src_count" "$tgt_count" "$log_file" || return 1
      if [[ "${CHECKSUM:-false}" == true ]]; then
        _verify_checksum "$table" || return 1
      fi
    fi
  else
    echo "❌ Failed to copy $table" >&2
    echo "$(date '+%F %T') | FAILED $table" >> "$log_file"
    return 1
  fi
  return 0
}

_copy_one_postgresql() {
  local table="$1" exists src_count tgt_count
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
      return 1
    fi
    if ! confirm "Data-only: truncate $table on the target before loading?"; then
      echo "⏭️  Skipping $table."
      return 0
    fi
    if [[ "$dry_run" == false ]]; then
      if ! PGPASSWORD="$TGT_PASS" "${psql_tgt[@]}" -d "$TGT_DB" -q -c "TRUNCATE \"$TGT_SCHEMA\".\"$table\";"; then
        echo "❌ Failed to truncate $table on the target." >&2
        return 1
      fi
    fi
  elif [[ -n "$exists" && "$exists" != "NULL" ]]; then
    if ! confirm "Table $table exists on the target. Replace?"; then
      echo "⏭️  Skipping $table."
      return 0
    fi
    if [[ "$dry_run" == false ]]; then
      PGPASSWORD="$TGT_PASS" "${psql_tgt[@]}" -d "$TGT_DB" -q -c "DROP TABLE \"$TGT_SCHEMA\".\"$table\";"
    fi
  fi

  if [[ "$dry_run" == true ]]; then
    echo "Would copy $table ($SRC_HOST/$SRC_DB → $TGT_HOST/$TGT_DB, schema $TGT_SCHEMA)"
    return 0
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
      report_copy_result "$table" "$src_count" "$tgt_count" "$log_file" || return 1
      if [[ "${CHECKSUM:-false}" == true ]]; then
        _verify_checksum "$table" || return 1
      fi
    fi
  else
    echo "❌ Failed to copy $table" >&2
    echo "$(date '+%F %T') | FAILED $table" >> "$log_file"
    return 1
  fi
  return 0
}

_copy_one_sqlite() {
  local table="$1" exists src_exists src_count tgt_count
  echo "➡️  SQLite: $table"

  if ! src_exists=$(sqlite3 -readonly "$SRC_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$table';"); then
    echo "❌ Could not read the source database." >&2
    return 1
  fi
  if [[ "$src_exists" == "0" ]]; then
    echo "❌ Table $table not found in source $SRC_DB" >&2
    echo "$(date '+%F %T') | FAILED $table (not in source)" >> "$log_file"
    return 1
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
      return 1
    fi
    if ! confirm "Data-only: truncate $table on the target before loading?"; then
      echo "⏭️  Skipping $table."
      return 0
    fi
    if [[ "$dry_run" == false ]]; then
      if ! sqlite3 -bail "$TGT_DB" "DELETE FROM \"$table\";"; then
        echo "❌ Failed to truncate $table on the target." >&2
        return 1
      fi
    fi
  elif [[ "$exists" != "0" ]]; then
    if ! confirm "Table $table exists on the target. Replace?"; then
      echo "⏭️  Skipping $table."
      return 0
    fi
    if [[ "$dry_run" == false ]]; then
      sqlite3 -bail "$TGT_DB" "DROP TABLE \"$table\";"
    fi
  fi

  if [[ "$dry_run" == true ]]; then
    echo "Would copy $table ($SRC_DB → $TGT_DB)"
    return 0
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
      report_copy_result "$table" "$src_count" "$tgt_count" "$log_file" || return 1
      if [[ "${CHECKSUM:-false}" == true ]]; then
        _verify_checksum "$table" || return 1
      fi
    fi
  else
    echo "❌ Failed to copy $table" >&2
    echo "$(date '+%F %T') | FAILED $table" >> "$log_file"
    return 1
  fi
  return 0
}

_copy_one_oracle() {
  local table="$1" exists src_count tgt_count table_exists_action exp_par imp_par
  echo "➡️  Oracle: $table"
  if ! exists=$(_oracle_table_exists "$TGT_DB" "$table"); then
    echo "❌ Could not check whether $table exists on the target." >&2
    return 1
  fi
  table_exists_action="skip"
  if [[ "$exists" != "0" ]]; then
    if ! confirm "Table $table exists on the target. Replace?"; then
      echo "⏭️  Skipping $table."
      return 0
    fi
    table_exists_action="replace"
  fi

  if [[ "$dry_run" == true ]]; then
    echo "Would export/import $table via Data Pump"
    return 0
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
  local rc=0
  if expdp parfile="$exp_par" && impdp parfile="$imp_par"; then
    src_count=$(_oracle_row_count "$SRC_DB" "$table")
    tgt_count=$(_oracle_row_count "$TGT_DB" "$table")
    report_copy_result "$table" "$src_count" "$tgt_count" "$log_file" || rc=1
  else
    echo "❌ Failed to copy $table" >&2
    echo "$(date '+%F %T') | FAILED $table" >> "$log_file"
    rc=1
  fi
  rm -f "$exp_par" "$imp_par"
  return $rc
}

copy_tables() {
  local dry_run="$1"
  local log_file="$2"
  local tables_arg="${3:-}"
  local tables=() table failures=0
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

  # SQLite files are single-writer: parallel jobs would just fight over
  # the database lock.
  local jobs="${PARALLEL_JOBS:-1}"
  if (( jobs > 1 )) && [[ "$TGT_ENGINE" == "sqlite" ]]; then
    echo "ℹ️  SQLite targets are single-writer — running sequentially."
    jobs=1
  fi

  if [[ "$SRC_ENGINE" != "$TGT_ENGINE" ]]; then
    _cross_copy_tables "$dry_run" "$log_file" "$jobs" "${tables[@]}"
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

    _run_tables _copy_one_mysql "$jobs"

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

    _run_tables _copy_one_postgresql "$jobs"

  elif [[ "$DB_ENGINE" == "sqlite" ]]; then
    _run_tables _copy_one_sqlite "$jobs"

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

    _run_tables _copy_one_oracle "$jobs"
  fi

  if [[ $failures -gt 0 ]]; then
    echo "❌ Table copy finished with $failures failure(s) — see $log_file." >&2
    return 1
  fi
  echo "✅ Table copy complete."
}
