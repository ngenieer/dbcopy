#!/bin/bash
# Cross-engine table copy: mysql <-> postgresql <-> sqlite (any direction).
# Strategy: introspect source columns, map them to generic types, create the
# target table, then stream data in a NULL-safe interchange format.
# Not carried over: indexes (non-PK), FKs, auto-increment/identity, defaults.

# Sentinel that marks SQL NULL while data is in flight. Any real field that
# contained this exact string would arrive as NULL — hence the odd name.
DBCOPY_NULL_SENTINEL='__dbcopy_null_7f3a9c__'

_cross_mysql_src() { MYSQL_PWD="$SRC_PASS" mysql -h"$SRC_HOST" -P"${SRC_PORT:-3306}" -u"$SRC_USER" "$@"; }
_cross_mysql_tgt() { MYSQL_PWD="$TGT_PASS" mysql -h"$TGT_HOST" -P"${TGT_PORT:-3306}" -u"$TGT_USER" "$@"; }
_cross_psql_src() { PGPASSWORD="$SRC_PASS" psql -h "$SRC_HOST" -p "${SRC_PORT:-5432}" -U "$SRC_USER" -v ON_ERROR_STOP=1 "$@"; }
_cross_psql_tgt() { PGPASSWORD="$TGT_PASS" psql -h "$TGT_HOST" -p "${TGT_PORT:-5432}" -U "$TGT_USER" -v ON_ERROR_STOP=1 "$@"; }

_cross_qident() { # $1=engine $2=identifier
  case "$1" in
    mysql) printf '`%s`' "$2" ;;
    *) printf '"%s"' "$2" ;;
  esac
}

_cross_src_ref() { # $1=table
  case "$SRC_ENGINE" in
    mysql) printf '`%s`.`%s`' "$SRC_DB" "$1" ;;
    postgresql) printf 'public."%s"' "$1" ;;
    sqlite) printf '"%s"' "$1" ;;
  esac
}

_cross_tgt_ref() { # $1=table
  case "$TGT_ENGINE" in
    mysql) printf '`%s`.`%s`' "$TGT_DB" "$1" ;;
    postgresql) printf '"%s"."%s"' "${TGT_SCHEMA:-public}" "$1" ;;
    sqlite) printf '"%s"' "$1" ;;
  esac
}

# Emit one TSV line per column: name, data_type, length, precision, scale,
# nullable(0/1), pk(0/1) — in ordinal order.
_cross_columns() { # $1=table
  local tab
  tab=$(printf '\t')
  case "$SRC_ENGINE" in
    mysql)
      _cross_mysql_src -B -N -e "
        SELECT COLUMN_NAME, DATA_TYPE, IFNULL(CHARACTER_MAXIMUM_LENGTH,0),
               IFNULL(NUMERIC_PRECISION,0), IFNULL(NUMERIC_SCALE,0),
               IF(IS_NULLABLE='YES',1,0), IF(COLUMN_KEY='PRI',1,0)
        FROM information_schema.columns
        WHERE table_schema='$SRC_DB' AND table_name='$1'
        ORDER BY ORDINAL_POSITION;"
      ;;
    postgresql)
      _cross_psql_src -d "$SRC_DB" -At -F "$tab" -c "
        SELECT c.column_name, c.data_type,
               COALESCE(c.character_maximum_length,0),
               COALESCE(c.numeric_precision,0), COALESCE(c.numeric_scale,0),
               CASE WHEN c.is_nullable='YES' THEN 1 ELSE 0 END,
               CASE WHEN pk.column_name IS NOT NULL THEN 1 ELSE 0 END
        FROM information_schema.columns c
        LEFT JOIN (
          SELECT kcu.column_name
          FROM information_schema.table_constraints tc
          JOIN information_schema.key_column_usage kcu
            ON tc.constraint_name = kcu.constraint_name
           AND tc.table_schema = kcu.table_schema
          WHERE tc.constraint_type='PRIMARY KEY'
            AND tc.table_schema='public' AND tc.table_name='$1'
        ) pk ON pk.column_name = c.column_name
        WHERE c.table_schema='public' AND c.table_name='$1'
        ORDER BY c.ordinal_position;"
      ;;
    sqlite)
      sqlite3 -readonly -separator "$tab" "$SRC_DB" \
        "SELECT name, LOWER(type), 0, 0, 0,
                CASE WHEN \"notnull\"=1 THEN 0 ELSE 1 END,
                CASE WHEN pk>0 THEN 1 ELSE 0 END
         FROM pragma_table_info('$1');"
      ;;
  esac
}

# Map a source column type to a generic type: INT BIGINT SMALLINT DOUBLE REAL
# NUMERIC[(p,s)] BOOL VARCHAR(n) TEXT DATE TIME TIMESTAMP JSON. Unknown -> 1.
_cross_generic_type() { # $1=data_type $2=len $3=prec $4=scale
  local t="$1"
  case "$SRC_ENGINE" in
    mysql)
      case "$t" in
        tinyint|smallint|year) echo SMALLINT ;;
        mediumint|int) echo INT ;;
        bigint) echo BIGINT ;;
        decimal) echo "NUMERIC($3,$4)" ;;
        float) echo REAL ;;
        double) echo DOUBLE ;;
        char|varchar) echo "VARCHAR($2)" ;;
        tinytext|text|mediumtext|longtext|enum|set) echo TEXT ;;
        date) echo DATE ;;
        time) echo TIME ;;
        datetime|timestamp) echo TIMESTAMP ;;
        json) echo JSON ;;
        *) return 1 ;;
      esac ;;
    postgresql)
      case "$t" in
        smallint) echo SMALLINT ;;
        integer) echo INT ;;
        bigint) echo BIGINT ;;
        numeric) if [[ "$3" -gt 0 ]]; then echo "NUMERIC($3,$4)"; else echo NUMERIC; fi ;;
        real) echo REAL ;;
        "double precision") echo DOUBLE ;;
        boolean) echo BOOL ;;
        "character varying"|character) if [[ "$2" -gt 0 ]]; then echo "VARCHAR($2)"; else echo TEXT; fi ;;
        text) echo TEXT ;;
        uuid) echo "VARCHAR(36)" ;;
        date) echo DATE ;;
        "time without time zone") echo TIME ;;
        "timestamp without time zone"|"timestamp with time zone") echo TIMESTAMP ;;
        json|jsonb) echo JSON ;;
        *) return 1 ;;
      esac ;;
    sqlite)
      # SQLite declared types are free-form — use affinity-style matching.
      case "$t" in
        *int*) echo BIGINT ;;
        *blob*) return 1 ;;
        *bool*) echo BOOL ;;
        *real*|*floa*|*doub*) echo DOUBLE ;;
        *decimal*|*numeric*) echo NUMERIC ;;
        *) echo TEXT ;;
      esac ;;
  esac
}

_cross_render_type() { # $1=generic -> target column type
  local g="$1" base args=""
  base="${g%%(*}"
  [[ "$g" == *"("* ]] && args="(${g#*(}"
  case "$TGT_ENGINE" in
    postgresql)
      case "$base" in
        INT) echo integer ;;
        BIGINT) echo bigint ;;
        SMALLINT) echo smallint ;;
        DOUBLE) echo "double precision" ;;
        REAL) echo real ;;
        NUMERIC) echo "numeric$args" ;;
        BOOL) echo boolean ;;
        VARCHAR) echo "varchar$args" ;;
        TEXT) echo text ;;
        DATE) echo date ;;
        TIME) echo time ;;
        TIMESTAMP) echo timestamp ;;
        JSON) echo jsonb ;;
      esac ;;
    mysql)
      case "$base" in
        INT) echo int ;;
        BIGINT) echo bigint ;;
        SMALLINT) echo smallint ;;
        DOUBLE) echo double ;;
        REAL) echo float ;;
        NUMERIC) if [[ -n "$args" ]]; then echo "decimal$args"; else echo "decimal(65,30)"; fi ;;
        BOOL) echo "tinyint(1)" ;;
        VARCHAR) echo "varchar$args" ;;
        TEXT) echo text ;;
        DATE) echo date ;;
        TIME) echo time ;;
        TIMESTAMP) echo datetime ;;
        JSON) echo json ;;
      esac ;;
    sqlite)
      case "$base" in
        INT|BIGINT|SMALLINT|BOOL) echo INTEGER ;;
        DOUBLE|REAL) echo REAL ;;
        NUMERIC) echo NUMERIC ;;
        *) echo TEXT ;;
      esac ;;
  esac
}

# Introspect $1 and fill CROSS_NAMES/CROSS_RAW/CROSS_TYPES/CROSS_NULLABLE/CROSS_PK.
_cross_load_columns() { # $1=table
  local table="$1" raw name dtype len prec scale nullable pk g
  CROSS_NAMES=(); CROSS_RAW=(); CROSS_TYPES=(); CROSS_NULLABLE=(); CROSS_PK=()

  if ! raw=$(_cross_columns "$table"); then
    echo "❌ Could not read the source schema for $table." >&2
    return 1
  fi
  if [[ -z "$raw" ]]; then
    echo "❌ Table $table not found in source." >&2
    return 1
  fi

  while IFS=$'\t' read -r name dtype len prec scale nullable pk; do
    # Column names are interpolated into SQL on both sides — whitelist them.
    validate_identifier "$name" "column name in $table" || return 1
    if ! g=$(_cross_generic_type "$dtype" "$len" "$prec" "$scale"); then
      echo "❌ $table.$name: source type '$dtype' is not supported for cross-engine copy." >&2
      return 1
    fi
    CROSS_NAMES+=("$name")
    CROSS_RAW+=("$dtype")
    CROSS_TYPES+=("$g")
    CROSS_NULLABLE+=("$nullable")
    CROSS_PK+=("$pk")
  done <<< "$raw"
}

_cross_create_table() { # $1=table
  local table="$1" defs="" pkcols="" i q t
  for i in "${!CROSS_NAMES[@]}"; do
    q=$(_cross_qident "$TGT_ENGINE" "${CROSS_NAMES[i]}")
    t=$(_cross_render_type "${CROSS_TYPES[i]}")
    defs+="${defs:+, }$q $t"
    if [[ "${CROSS_NULLABLE[i]}" == "0" ]]; then
      defs+=" NOT NULL"
    fi
    if [[ "${CROSS_PK[i]}" == "1" ]]; then
      pkcols+="${pkcols:+, }$q"
    fi
  done
  if [[ -n "$pkcols" ]]; then
    defs+=", PRIMARY KEY ($pkcols)"
  fi
  local ddl
  ddl="CREATE TABLE $(_cross_tgt_ref "$table") ($defs);"

  case "$TGT_ENGINE" in
    mysql) _cross_mysql_tgt -e "$ddl" ;;
    postgresql) _cross_psql_tgt -q -d "$TGT_DB" -c "$ddl" ;;
    sqlite) sqlite3 -bail "$TGT_DB" "$ddl" ;;
  esac
}

# SELECT list for a PostgreSQL source: cast types whose text output the
# target cannot parse (booleans, tz-aware timestamps).
_cross_pg_select_list() {
  local i q out=""
  for i in "${!CROSS_NAMES[@]}"; do
    q="\"${CROSS_NAMES[i]}\""
    case "${CROSS_TYPES[i]}:${CROSS_RAW[i]}" in
      BOOL:*) q="$q::int" ;;
      *:"timestamp with time zone") q="($q AT TIME ZONE 'UTC')" ;;
    esac
    out+="${out:+, }$q"
  done
  printf '%s' "$out"
}

# SELECT list for a MySQL source producing pg COPY text fields: everything
# as CHAR with NULLs replaced by the sentinel (mysql batch mode prints the
# bare word NULL, which is indistinguishable from real 'NULL' text).
_cross_mysql_select_list() {
  local i out=""
  for i in "${!CROSS_NAMES[@]}"; do
    out+="${out:+, }IFNULL(CAST(\`${CROSS_NAMES[i]}\` AS CHAR), '$DBCOPY_NULL_SENTINEL')"
  done
  printf '%s' "$out"
}

# Single expression turning a MySQL row into one CSV line (used with --raw,
# so embedded newlines survive inside the quoted fields).
_cross_mysql_csv_expr() {
  local i f out=""
  for i in "${!CROSS_NAMES[@]}"; do
    f="IF(\`${CROSS_NAMES[i]}\` IS NULL, '$DBCOPY_NULL_SENTINEL', CONCAT('\"', REPLACE(CAST(\`${CROSS_NAMES[i]}\` AS CHAR), '\"', '\"\"'), '\"'))"
    out+="${out:+, }$f"
  done
  printf 'CONCAT_WS(%s, %s)' "','" "$out"
}

# SELECT list for a SQLite source: NULLs replaced by the sentinel because
# sqlite3 -csv prints NULL and '' identically.
_cross_sqlite_select_list() {
  local i out=""
  for i in "${!CROSS_NAMES[@]}"; do
    out+="${out:+, }IFNULL(\"${CROSS_NAMES[i]}\", '$DBCOPY_NULL_SENTINEL')"
  done
  printf '%s' "$out"
}

# sqlite3 .import cannot represent NULL — sentinels are imported literally
# and converted afterwards.
_cross_sqlite_fix_sentinels() { # $1=table
  local c sql=""
  for c in "${CROSS_NAMES[@]}"; do
    sql+="UPDATE \"$1\" SET \"$c\"=NULL WHERE \"$c\"='$DBCOPY_NULL_SENTINEL';"
  done
  sqlite3 -bail "$TGT_DB" "$sql"
}

_cross_copy_data() { # $1=table
  local table="$1" sel tmp vars="" sets="" i
  local where_sql=""
  if [[ -n "${WHERE_CLAUSE:-}" ]]; then
    where_sql=" WHERE $WHERE_CLAUSE"
  fi
  case "$SRC_ENGINE:$TGT_ENGINE" in
    mysql:postgresql)
      sel=$(_cross_mysql_select_list)
      # mysql -B escapes \t \n \\ exactly like pg's COPY text format expects.
      _cross_mysql_src -B -N -e "SELECT $sel FROM $(_cross_src_ref "$table")$where_sql;" \
        | sed "s/$DBCOPY_NULL_SENTINEL/\\\\N/g" \
        | _cross_psql_tgt -q -d "$TGT_DB" -c "\\copy $(_cross_tgt_ref "$table") FROM STDIN"
      ;;
    mysql:sqlite)
      sel=$(_cross_mysql_csv_expr)
      _cross_mysql_src --raw -B -N -e "SELECT $sel FROM $(_cross_src_ref "$table")$where_sql;" \
        | sqlite3 -bail "$TGT_DB" ".import --csv /dev/stdin $table" || return 1
      _cross_sqlite_fix_sentinels "$table"
      ;;
    postgresql:mysql)
      # pg COPY text output (\t sep, \N null, backslash escapes) matches
      # LOAD DATA's default text format.
      sel=$(_cross_pg_select_list)
      tmp=$(mktemp) || return 1
      if ! _cross_psql_src -d "$SRC_DB" -c "COPY (SELECT $sel FROM $(_cross_src_ref "$table")$where_sql) TO STDOUT" > "$tmp"; then
        rm -f "$tmp"; return 1
      fi
      if ! _cross_mysql_tgt --local-infile=1 -e "LOAD DATA LOCAL INFILE '$tmp' INTO TABLE $(_cross_tgt_ref "$table");"; then
        echo "ℹ️  LOAD DATA LOCAL requires local_infile=ON on the target MySQL server." >&2
        rm -f "$tmp"; return 1
      fi
      rm -f "$tmp"
      ;;
    postgresql:sqlite)
      sel=$(_cross_pg_select_list)
      _cross_psql_src -d "$SRC_DB" -c "COPY (SELECT $sel FROM $(_cross_src_ref "$table")$where_sql) TO STDOUT WITH (FORMAT csv, NULL '$DBCOPY_NULL_SENTINEL')" \
        | sqlite3 -bail "$TGT_DB" ".import --csv /dev/stdin $table" || return 1
      _cross_sqlite_fix_sentinels "$table"
      ;;
    sqlite:postgresql)
      sel=$(_cross_sqlite_select_list)
      sqlite3 -readonly -csv "$SRC_DB" "SELECT $sel FROM $(_cross_src_ref "$table")$where_sql;" \
        | _cross_psql_tgt -q -d "$TGT_DB" -c "\\copy $(_cross_tgt_ref "$table") FROM STDIN WITH (FORMAT csv, NULL '$DBCOPY_NULL_SENTINEL')"
      ;;
    sqlite:mysql)
      sel=$(_cross_sqlite_select_list)
      for i in "${!CROSS_NAMES[@]}"; do
        vars+="${vars:+, }@v$i"
        sets+="${sets:+, }\`${CROSS_NAMES[i]}\`=NULLIF(@v$i, '$DBCOPY_NULL_SENTINEL')"
      done
      tmp=$(mktemp) || return 1
      if ! sqlite3 -readonly -csv "$SRC_DB" "SELECT $sel FROM $(_cross_src_ref "$table")$where_sql;" > "$tmp"; then
        rm -f "$tmp"; return 1
      fi
      if ! _cross_mysql_tgt --local-infile=1 -e "LOAD DATA LOCAL INFILE '$tmp' INTO TABLE $(_cross_tgt_ref "$table") FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '\"' LINES TERMINATED BY '\n' ($vars) SET $sets;"; then
        echo "ℹ️  LOAD DATA LOCAL requires local_infile=ON on the target MySQL server." >&2
        rm -f "$tmp"; return 1
      fi
      rm -f "$tmp"
      ;;
    *)
      echo "❌ Unsupported cross-engine direction: $SRC_ENGINE → $TGT_ENGINE" >&2
      return 1
      ;;
  esac
}

_cross_count_src() { # $1=table
  local where_sql=""
  if [[ -n "${WHERE_CLAUSE:-}" ]]; then
    where_sql=" WHERE $WHERE_CLAUSE"
  fi
  case "$SRC_ENGINE" in
    mysql) _cross_mysql_src -B -N -e "SELECT COUNT(*) FROM $(_cross_src_ref "$1")$where_sql;" ;;
    postgresql) _cross_psql_src -d "$SRC_DB" -Atc "SELECT count(*) FROM $(_cross_src_ref "$1")$where_sql;" ;;
    sqlite) sqlite3 -readonly "$SRC_DB" "SELECT COUNT(*) FROM \"$1\"$where_sql;" ;;
  esac
}

_cross_count_tgt() { # $1=table
  case "$TGT_ENGINE" in
    mysql) _cross_mysql_tgt -B -N -e "SELECT COUNT(*) FROM $(_cross_tgt_ref "$1");" ;;
    postgresql) _cross_psql_tgt -d "$TGT_DB" -Atc "SELECT count(*) FROM $(_cross_tgt_ref "$1");" ;;
    sqlite) sqlite3 -readonly "$TGT_DB" "SELECT COUNT(*) FROM \"$1\";" ;;
  esac
}

_cross_ensure_target_db() { # $1=dry_run; sets CROSS_TGT_DB_READY
  local dry_run="$1"
  CROSS_TGT_DB_READY=true
  case "$TGT_ENGINE" in
    mysql)
      if ! _cross_mysql_tgt -e "USE \`$TGT_DB\`;" 2>/dev/null; then
        echo "Creating DB $TGT_DB on target..."
        if [[ "$dry_run" == false ]]; then
          _cross_mysql_tgt -e "CREATE DATABASE \`$TGT_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" || return 1
        else
          CROSS_TGT_DB_READY=false
        fi
      fi
      ;;
    postgresql)
      if ! _cross_psql_tgt -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$TGT_DB';" | grep -q 1; then
        echo "Creating PostgreSQL DB $TGT_DB on target..."
        if [[ "$dry_run" == false ]]; then
          _cross_psql_tgt -d postgres -q -c "CREATE DATABASE \"$TGT_DB\";" || return 1
        else
          CROSS_TGT_DB_READY=false
        fi
      fi
      if [[ "$dry_run" == false ]]; then
        _cross_psql_tgt -d "$TGT_DB" -q -c "CREATE SCHEMA IF NOT EXISTS \"${TGT_SCHEMA:-public}\";" || return 1
      fi
      ;;
    sqlite)
      : # the file is created on first write
      ;;
  esac
  return 0
}

_cross_target_exists() { # $1=table -> echoes 0/1
  case "$TGT_ENGINE" in
    mysql)
      if [[ "$CROSS_TGT_DB_READY" == false ]]; then echo 0; return 0; fi
      _cross_mysql_tgt -B -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$TGT_DB' AND table_name='$1';"
      ;;
    postgresql)
      if [[ "$CROSS_TGT_DB_READY" == false ]]; then echo 0; return 0; fi
      _cross_psql_tgt -d "$TGT_DB" -Atc "SELECT CASE WHEN to_regclass('\"${TGT_SCHEMA:-public}\".\"$1\"') IS NULL THEN 0 ELSE 1 END;"
      ;;
    sqlite)
      if [[ -f "$TGT_DB" ]]; then
        sqlite3 -readonly "$TGT_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$1';"
      else
        echo 0
      fi
      ;;
  esac
}

_cross_drop_target() { # $1=table
  case "$TGT_ENGINE" in
    mysql) _cross_mysql_tgt -e "SET FOREIGN_KEY_CHECKS=0; DROP TABLE $(_cross_tgt_ref "$1");" ;;
    postgresql) _cross_psql_tgt -q -d "$TGT_DB" -c "DROP TABLE $(_cross_tgt_ref "$1");" ;;
    sqlite) sqlite3 -bail "$TGT_DB" "DROP TABLE \"$1\";" ;;
  esac
}

_cross_truncate_target() { # $1=table
  case "$TGT_ENGINE" in
    mysql) _cross_mysql_tgt -e "TRUNCATE TABLE $(_cross_tgt_ref "$1");" ;;
    postgresql) _cross_psql_tgt -q -d "$TGT_DB" -c "TRUNCATE $(_cross_tgt_ref "$1");" ;;
    sqlite) sqlite3 -bail "$TGT_DB" "DELETE FROM \"$1\";" ;;
  esac
}

# Per-table cross-engine copy; dry_run/log_file come from the caller via
# dynamic scoping. Returns 0 on success or skip, 1 on failure.
_cross_copy_one() {
  local table="$1" exists src_count tgt_count
  echo "➡️  $SRC_ENGINE→$TGT_ENGINE: $table"

  if ! _cross_load_columns "$table"; then
    echo "$(date '+%F %T') | FAILED $table (cross-engine schema)" >> "$log_file"
    return 1
  fi

  if ! exists=$(_cross_target_exists "$table"); then
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
      if ! _cross_truncate_target "$table"; then
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
      if ! _cross_drop_target "$table"; then
        echo "❌ Failed to drop $table on the target." >&2
        echo "$(date '+%F %T') | FAILED $table (drop)" >> "$log_file"
        return 1
      fi
    fi
  fi

  if [[ "$dry_run" == true ]]; then
    echo "Would create and copy $table (${#CROSS_NAMES[@]} columns, $SRC_ENGINE → $TGT_ENGINE)"
    return 0
  fi

  if [[ "${DATA_ONLY:-false}" != true ]]; then
    if ! _cross_create_table "$table"; then
      echo "❌ Failed to create $table on the target." >&2
      echo "$(date '+%F %T') | FAILED $table (create)" >> "$log_file"
      return 1
    fi
  fi
  if [[ "${SCHEMA_ONLY:-false}" == true ]]; then
    echo "✅ $table: schema created"
    echo "$(date '+%F %T') | Schema $table" >> "$log_file"
    return 0
  fi
  if ! _cross_copy_data "$table"; then
    echo "❌ Failed to copy $table" >&2
    echo "$(date '+%F %T') | FAILED $table" >> "$log_file"
    return 1
  fi

  src_count=$(_cross_count_src "$table") || src_count=""
  tgt_count=$(_cross_count_tgt "$table") || tgt_count=""
  report_copy_result "$table" "$src_count" "$tgt_count" "$log_file" || return 1
  return 0
}

_cross_copy_tables() { # $1=dry_run $2=log_file $3=jobs $4..=tables
  local dry_run="$1" log_file="$2" jobs="$3"
  shift 3
  local tables=("$@") failures=0

  echo "🔀 Cross-engine copy: $SRC_ENGINE → $TGT_ENGINE"
  _cross_ensure_target_db "$dry_run" || return 1

  _run_tables _cross_copy_one "$jobs"

  if [[ $failures -gt 0 ]]; then
    echo "❌ Table copy finished with $failures failure(s) — see $log_file." >&2
    return 1
  fi
  echo "✅ Table copy complete."
}
