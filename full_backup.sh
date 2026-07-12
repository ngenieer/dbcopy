#!/bin/bash

# Delete all but the newest $1 backup_* directories. The glob is strict
# (backup_YYYYMMDD_HHMMSS only) so nothing else can ever match, and the
# timestamp format makes lexicographic order chronological.
_prune_backups() {
  local keep="$1" dirs=() d
  for d in backup_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]; do
    if [[ -d "$d" ]]; then
      dirs+=("$d")
    fi
  done
  local excess=$(( ${#dirs[@]} - keep ))
  if (( excess <= 0 )); then
    return 0
  fi
  local i
  for (( i = 0; i < excess; i++ )); do
    echo "🧹 Pruning old backup ${dirs[i]}"
    rm -rf "${dirs[i]}"
  done
}

perform_full_backup() {
  local timestamp backup_dir file
  timestamp=$(date +"%Y%m%d_%H%M%S")
  backup_dir="backup_$timestamp"
  mkdir -p "$backup_dir"

  echo "🔐 Starting full backup of source → $backup_dir"

  case "$SRC_ENGINE" in
    mysql)
      file="$backup_dir/${SRC_DB}_full.sql"
      # --single-transaction: consistent snapshot without locking a live DB.
      local dump_cmd=(mysqldump -h"$SRC_HOST" -P"${SRC_PORT:-3306}" -u"$SRC_USER"
                      --single-transaction --routines --triggers --databases "$SRC_DB")
      if [[ "${COMPRESS:-false}" == true ]]; then
        file="$file.gz"
        MYSQL_PWD="$SRC_PASS" "${dump_cmd[@]}" | gzip > "$file" || { rm -f "$file"; echo "❌ MySQL backup failed." >&2; return 1; }
      else
        MYSQL_PWD="$SRC_PASS" "${dump_cmd[@]}" > "$file" || { rm -f "$file"; echo "❌ MySQL backup failed." >&2; return 1; }
      fi
      echo "✅ MySQL full dump saved to $file"
      ;;
    postgresql)
      file="$backup_dir/${SRC_DB}_full.sql"
      local pg_cmd=(pg_dump -h "$SRC_HOST" -p "${SRC_PORT:-5432}" -U "$SRC_USER" -d "$SRC_DB" -F p)
      if [[ "${COMPRESS:-false}" == true ]]; then
        file="$file.gz"
        PGPASSWORD="$SRC_PASS" "${pg_cmd[@]}" | gzip > "$file" || { rm -f "$file"; echo "❌ PostgreSQL backup failed." >&2; return 1; }
      else
        PGPASSWORD="$SRC_PASS" "${pg_cmd[@]}" > "$file" || { rm -f "$file"; echo "❌ PostgreSQL backup failed." >&2; return 1; }
      fi
      echo "✅ PostgreSQL full dump saved to $file"
      ;;
    sqlite)
      file="$backup_dir/$(basename "$SRC_DB")"
      # .backup uses SQLite's online backup API — safe on a live database.
      if ! sqlite3 "$SRC_DB" ".backup \"$file\""; then
        rm -f "$file"
        echo "❌ SQLite backup failed." >&2
        return 1
      fi
      if [[ "${COMPRESS:-false}" == true ]]; then
        gzip -f "$file"
        file="$file.gz"
      fi
      echo "✅ SQLite backup saved to $file"
      ;;
    oracle)
      if [[ "${COMPRESS:-false}" == true ]]; then
        echo "ℹ️  --compress is ignored for Oracle (the dump is written server-side to DATA_PUMP_DIR)."
      fi
      file="${SRC_DB}_full.dmp"
      # Credentials go into a mode-600 parameter file (removed right after):
      # expdp cannot take the password on stdin, and the command line would
      # expose it in the process list.
      local exp_par
      exp_par=$(mktemp) || return 1
      chmod 600 "$exp_par"
      cat > "$exp_par" <<EOF
userid=$SRC_USER/"$SRC_PASS"@//$SRC_HOST:${SRC_PORT:-1521}/$SRC_ORA_SERVICE
full=y
directory=DATA_PUMP_DIR
dumpfile=$file
logfile=exp_full.log
reuse_dumpfiles=y
EOF
      if expdp parfile="$exp_par"; then
        rm -f "$exp_par"
        echo "✅ Oracle Data Pump export complete: $file (logical, stored in DATA_PUMP_DIR on the server)"
      else
        rm -f "$exp_par"
        echo "❌ Oracle backup failed." >&2
        return 1
      fi
      ;;
    *)
      echo "❌ Full backup not implemented for engine: $SRC_ENGINE" >&2
      return 1
      ;;
  esac

  if [[ -n "${KEEP_BACKUPS:-}" ]]; then
    _prune_backups "$KEEP_BACKUPS"
  fi
  return 0
}
