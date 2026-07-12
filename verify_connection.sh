#!/bin/bash

verify_one_connection() {
  local label="$1" host="$2" port="$3" user="$4" pass="$5" service="${6:-}"
  local err rc=0
  err=$(mktemp) || return 1

  case "$DB_ENGINE" in
    mysql)
      # Password via MYSQL_PWD, not -p<pass>: keeps it out of `ps` output.
      MYSQL_PWD="$pass" mysql -h"$host" -P"${port:-3306}" -u"$user" \
        -e "SELECT 1;" > /dev/null 2> "$err" || rc=1
      ;;
    postgresql)
      PGPASSWORD="$pass" psql -h "$host" -p "${port:-5432}" -U "$user" \
        -d postgres -c "\q" 2> "$err" || rc=1
      ;;
    oracle)
      # /nolog + CONNECT on stdin keeps credentials out of the process list.
      # sqlplus exits 0 even on a failed login, so also grep for ORA-/SP2- errors.
      sqlplus -s /nolog > "$err" 2>&1 <<EOF || rc=1
CONNECT $user/"$pass"@//$host:${port:-1521}/$service
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
    echo "❌ $label connection failed:"
    cat "$err"
    rm -f "$err"
    return 1
  fi

  rm -f "$err"
  echo "✅ $label connection successful."
  return 0
}

verify_connection() {
  verify_one_connection "Source ($SRC_HOST)" "$SRC_HOST" "$SRC_PORT" "$SRC_USER" "$SRC_PASS" "$SRC_ORA_SERVICE" || return 1
  verify_one_connection "Target ($TGT_HOST)" "$TGT_HOST" "$TGT_PORT" "$TGT_USER" "$TGT_PASS" "$TGT_ORA_SERVICE" || return 1
}
