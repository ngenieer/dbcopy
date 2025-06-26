#!/bin/bash

copy_tables() {
  local dry_run="$1"
  local log_file="$2"

  read -p "Enter table names (space-separated): " -a tables

  if [[ "$DB_ENGINE" == "mysql" ]]; then
    MYSQL="mysql -h$DB_HOST -P${DB_PORT:-3306} -u$DB_USER -p$DB_PASS"

    $MYSQL -e "USE \`$TGT_DB\`;" 2>/dev/null || {
      echo "Creating DB $TGT_DB..."
      [[ "$dry_run" == false ]] && $MYSQL -e "CREATE DATABASE \`$TGT_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    }

    for table in "${tables[@]}"; do
      echo "➡️  MySQL: $table"
      exists=$($MYSQL -e "SHOW TABLES IN \`$TGT_DB\` LIKE '$table';" | grep "$table")
      if [[ -n "$exists" ]]; then
        read -p "Table $table exists. Replace? (y/n): " y
        [[ "$y" =~ ^[Yy]$ ]] && [[ "$dry_run" == false ]] && $MYSQL -e "DROP TABLE \`$TGT_DB\`.\`$table\`;"
      fi

      [[ "$dry_run" == false ]] && {
        $MYSQL -e "CREATE TABLE \`$TGT_DB\`.\`$table\` LIKE \`$SRC_DB\`.\`$table\`;"
        $MYSQL -e "INSERT INTO \`$TGT_DB\`.\`$table\` SELECT * FROM \`$SRC_DB\`.\`$table\`;"
        echo "$(date '+%F %T') | Copied $table" >> "$log_file"
      } || echo "Would copy $table"
    done

  elif [[ "$DB_ENGINE" == "postgresql" ]]; then
    export PGPASSWORD="$DB_PASS"

    psql -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$TGT_DB';" | grep -q 1 || {
      echo "Creating PostgreSQL DB $TGT_DB..."
      [[ "$dry_run" == false ]] && createdb -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" "$TGT_DB"
    }

    for table in "${tables[@]}"; do
      echo "➡️  PostgreSQL: $table"
      exists=$(psql -h "$DB_HOST" -U "$DB_USER" -d "$TGT_DB" -Atc "SELECT to_regclass('$TGT_SCHEMA.$table');")
      if [[ "$exists" != "" && "$exists" != "NULL" ]]; then
        read -p "Table $table exists. Replace? (y/n): " y
        [[ "$y" =~ ^[Yy]$ ]] && [[ "$dry_run" == false ]] && \
          psql -h "$DB_HOST" -U "$DB_USER" -d "$TGT_DB" -c "DROP TABLE \"$TGT_SCHEMA\".\"$table\";"
      fi

      [[ "$dry_run" == false ]] && {
        pg_dump -h "$DB_HOST" -U "$DB_USER" -t "$table" "$SRC_DB" | \
          sed "s/SET search_path = .*/SET search_path = $TGT_SCHEMA;/" | \
          psql -h "$DB_HOST" -U "$DB_USER" -d "$TGT_DB"
        echo "$(date '+%F %T') | Copied $table" >> "$log_file"
      } || echo "Would copy $table"
    done

  elif [[ "$DB_ENGINE" == "oracle" ]]; then
    echo "📦 Oracle (Data Pump):"
    ORA_CONN="$DB_USER/$DB_PASS@//$DB_HOST:${DB_PORT:-1521}/$ORA_SERVICE"

    for table in "${tables[@]}"; do
      echo "➡️  Oracle: $table"
      if [[ "$dry_run" == false ]]; then
        expdp "$ORA_CONN" tables=$table dumpfile=${DUMP_FILE}_${table}.dmp directory=DATA_PUMP_DIR logfile=exp_${table}.log reuse_dumpfiles=y
        impdp "$ORA_CONN" tables=$table dumpfile=${DUMP_FILE}_${table}.dmp directory=DATA_PUMP_DIR logfile=imp_${table}.log remap_schema=$SRC_DB:$TGT_DB
        echo "$(date '+%F %T') | Oracle copied $table" >> "$log_file"
      else
        echo "Would export/import $table via Data Pump"
      fi
    done
  fi

  echo "✅ Table copy complete."
}

