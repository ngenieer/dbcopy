#!/bin/bash

perform_full_backup() {
  local timestamp
  timestamp=$(date +"%Y%m%d_%H%M%S")
  local backup_dir="backup_$timestamp"
  mkdir -p "$backup_dir"

  echo "🔐 Starting full backup → $backup_dir"

  case "$DB_ENGINE" in
    mysql)
      FILE="$backup_dir/${SRC_DB}_full.sql"
      mysqldump -h"$DB_HOST" -P"${DB_PORT:-3306}" -u"$DB_USER" -p"$DB_PASS" --databases "$SRC_DB" > "$FILE"
      echo "✅ MySQL full dump saved to $FILE"
      ;;
    postgresql)
      export PGPASSWORD="$DB_PASS"
      FILE="$backup_dir/${SRC_DB}_full.sql"
      pg_dump -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" -d "$SRC_DB" -F p > "$FILE"
      echo "✅ PostgreSQL full dump saved to $FILE"
      ;;
    oracle)
      FILE="$backup_dir/${SRC_DB}_full.dmp"
      ORA_CONN="$DB_USER/$DB_PASS@//$DB_HOST:${DB_PORT:-1521}/$ORA_SERVICE"
      expdp "$ORA_CONN" full=y directory=DATA_PUMP_DIR dumpfile=$(basename "$FILE") logfile=exp_full.log reuse_dumpfiles=y
      echo "✅ Oracle Data Pump export complete: $FILE (logical, stored in Oracle directory)"
      ;;
    *)
      echo "❌ Full backup not implemented for engine: $DB_ENGINE"
      ;;
  esac
}

