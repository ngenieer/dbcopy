#!/bin/bash

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
      if MYSQL_PWD="$SRC_PASS" mysqldump -h"$SRC_HOST" -P"${SRC_PORT:-3306}" -u"$SRC_USER" \
           --single-transaction --routines --triggers --databases "$SRC_DB" > "$file"; then
        echo "✅ MySQL full dump saved to $file"
      else
        rm -f "$file"
        echo "❌ MySQL backup failed." >&2
        return 1
      fi
      ;;
    postgresql)
      file="$backup_dir/${SRC_DB}_full.sql"
      if PGPASSWORD="$SRC_PASS" pg_dump -h "$SRC_HOST" -p "${SRC_PORT:-5432}" -U "$SRC_USER" \
           -d "$SRC_DB" -F p > "$file"; then
        echo "✅ PostgreSQL full dump saved to $file"
      else
        rm -f "$file"
        echo "❌ PostgreSQL backup failed." >&2
        return 1
      fi
      ;;
    sqlite)
      file="$backup_dir/$(basename "$SRC_DB")"
      # .backup uses SQLite's online backup API — safe on a live database.
      if sqlite3 "$SRC_DB" ".backup \"$file\""; then
        echo "✅ SQLite backup saved to $file"
      else
        rm -f "$file"
        echo "❌ SQLite backup failed." >&2
        return 1
      fi
      ;;
    oracle)
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
}
