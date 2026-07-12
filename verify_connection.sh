#!/bin/bash

verify_connection() {
  local err rc=0
  err=$(mktemp) || return 1

  case "$DB_ENGINE" in
    mysql)
      # Password via MYSQL_PWD, not -p<pass>: keeps it out of `ps` output.
      MYSQL_PWD="$DB_PASS" mysql -h"$DB_HOST" -P"${DB_PORT:-3306}" -u"$DB_USER" \
        -e "SELECT 1;" > /dev/null 2> "$err" || rc=1
      ;;
    postgresql)
      PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" \
        -d postgres -c "\q" 2> "$err" || rc=1
      ;;
    oracle)
      # /nolog + CONNECT on stdin keeps credentials out of the process list.
      # sqlplus exits 0 even on a failed login, so also grep for ORA-/SP2- errors.
      sqlplus -s /nolog > "$err" 2>&1 <<EOF || rc=1
CONNECT $DB_USER/"$DB_PASS"@//$DB_HOST:${DB_PORT:-1521}/$ORA_SERVICE
EXIT
EOF
      grep -qE "ORA-|SP2-" "$err" && rc=1
      ;;
    *)
      echo "❌ Unsupported engine: $DB_ENGINE" >&2
      rm -f "$err"
      return 1
      ;;
  esac

  if [[ $rc -ne 0 ]]; then
    echo "❌ Connection failed:"
    cat "$err"
    rm -f "$err"
    return 1
  fi

  rm -f "$err"
  echo "✅ Connection successful."
  return 0
}
