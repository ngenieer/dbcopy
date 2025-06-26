#!/bin/bash

verify_connection() {
  case "$DB_ENGINE" in
    mysql)
      mysql -h"$DB_HOST" -P"${DB_PORT:-3306}" -u"$DB_USER" -p"$DB_PASS" -e ";" 2> /tmp/db_err
      ;;
    postgresql)
      export PGPASSWORD="$DB_PASS"
      psql -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" -d postgres -c "\q" 2> /tmp/db_err
      ;;
    oracle)
      echo "exit" | sqlplus -s "$DB_USER/$DB_PASS@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(Host=$DB_HOST)(Port=${DB_PORT:-1521}))(CONNECT_DATA=(SERVICE_NAME=$ORA_SERVICE)))" > /tmp/db_err 2>&1
      ;;
  esac

  if [[ $? -ne 0 ]]; then
    echo "❌ Connection failed:"
    cat /tmp/db_err
    return 1
  fi

  echo "✅ Connection successful."
  return 0
}

