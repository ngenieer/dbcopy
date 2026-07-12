#!/bin/bash
# Integration tests — runs INSIDE the runner container (see docker-compose.yml).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
cd "$WORK"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  ✅ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $desc — expected '$expected', got '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

mysql_src_q() { MYSQL_PWD=srcpass mysql -hmysql-src -uroot -N -e "$1"; }
mysql_tgt_q() { MYSQL_PWD=tgtpass mysql -hmysql-tgt -uroot -N -e "$1"; }
mariadb_tgt_q() { MYSQL_PWD=tgtpass mysql -hmariadb-tgt -uroot -N -e "$1"; }
pg_tgt_q() { PGPASSWORD=tgtpass psql -hpg-tgt -Upostgres -d "$1" -Atc "$2"; }

echo "═══ MySQL: cross-server, non-interactive ═══"
cat > mysql.yaml <<'EOF'
db_engine: "mysql"
src_host: "mysql-src"
src_port: "3306"
src_user: "root"
src_pass: "srcpass"
src_db: "srcdb"
tgt_host: "mysql-tgt"
tgt_port: "3306"
tgt_user: "root"
tgt_pass: "tgtpass"
tgt_db: "tgtdb"
tgt_schema: "public"
src_ora_service: ""
tgt_ora_service: ""
dump_file: ""
EOF
chmod 600 mysql.yaml

echo "--- dry run ---"
"$ROOT/main.sh" --config mysql.yaml --tables users,orders --yes --dry-run
assert_eq "dry-run did not create the target DB" "0" \
  "$(mysql_tgt_q "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='tgtdb';")"

echo "--- real copy ---"
"$ROOT/main.sh" --config mysql.yaml --tables users,orders --yes
assert_eq "users copied (5 rows)" "5" "$(mysql_tgt_q "SELECT COUNT(*) FROM tgtdb.users;")"
assert_eq "orders copied (7 rows)" "7" "$(mysql_tgt_q "SELECT COUNT(*) FROM tgtdb.orders;")"
assert_eq "foreign key carried over" "1" \
  "$(mysql_tgt_q "SELECT COUNT(*) FROM information_schema.referential_constraints WHERE constraint_schema='tgtdb';")"

echo "--- re-run with replace (must not duplicate rows) ---"
"$ROOT/main.sh" --config mysql.yaml --tables users --yes
assert_eq "users still 5 rows after replace" "5" "$(mysql_tgt_q "SELECT COUNT(*) FROM tgtdb.users;")"

echo
echo "═══ MariaDB: cross-server via the mysql engine path ═══"
cat > mariadb.yaml <<'EOF'
db_engine: "mysql"
src_host: "mariadb-src"
src_port: "3306"
src_user: "root"
src_pass: "srcpass"
src_db: "srcdb"
tgt_host: "mariadb-tgt"
tgt_port: "3306"
tgt_user: "root"
tgt_pass: "tgtpass"
tgt_db: "tgtdb"
tgt_schema: "public"
src_ora_service: ""
tgt_ora_service: ""
dump_file: ""
EOF
chmod 600 mariadb.yaml

"$ROOT/main.sh" --config mariadb.yaml --tables users,orders --yes
assert_eq "users copied (5 rows)" "5" "$(mariadb_tgt_q "SELECT COUNT(*) FROM tgtdb.users;")"
assert_eq "orders copied (7 rows)" "7" "$(mariadb_tgt_q "SELECT COUNT(*) FROM tgtdb.orders;")"
assert_eq "foreign key carried over" "1" \
  "$(mariadb_tgt_q "SELECT COUNT(*) FROM information_schema.referential_constraints WHERE constraint_schema='tgtdb';")"

echo "--- re-run with replace (must not duplicate rows) ---"
"$ROOT/main.sh" --config mariadb.yaml --tables users --yes
assert_eq "users still 5 rows after replace" "5" "$(mariadb_tgt_q "SELECT COUNT(*) FROM tgtdb.users;")"

echo
echo "═══ PostgreSQL: cross-server into non-public schema ═══"
cat > pg.yaml <<'EOF'
db_engine: "postgresql"
src_host: "pg-src"
src_port: "5432"
src_user: "postgres"
src_pass: "srcpass"
src_db: "srcdb"
tgt_host: "pg-tgt"
tgt_port: "5432"
tgt_user: "postgres"
tgt_pass: "tgtpass"
tgt_db: "tgtdb"
tgt_schema: "analytics"
src_ora_service: ""
tgt_ora_service: ""
dump_file: ""
EOF
chmod 600 pg.yaml

echo "--- dry run ---"
"$ROOT/main.sh" --config pg.yaml --tables users,orders --yes --dry-run
assert_eq "dry-run did not create the target DB" "0" \
  "$(pg_tgt_q postgres "SELECT COUNT(*) FROM pg_database WHERE datname='tgtdb';")"

echo "--- real copy ---"
"$ROOT/main.sh" --config pg.yaml --tables users,orders --yes
assert_eq "users copied into analytics schema (5 rows)" "5" \
  "$(pg_tgt_q tgtdb "SELECT count(*) FROM analytics.users;")"
assert_eq "orders copied into analytics schema (7 rows)" "7" \
  "$(pg_tgt_q tgtdb "SELECT count(*) FROM analytics.orders;")"

echo "--- re-run with replace (must not duplicate rows) ---"
"$ROOT/main.sh" --config pg.yaml --tables users --yes
assert_eq "users still 5 rows after replace" "5" \
  "$(pg_tgt_q tgtdb "SELECT count(*) FROM analytics.users;")"

echo
echo "═══ SQLite: file-to-file copy ═══"
sqlite3 src.db < "$ROOT/tests/seed/sqlite-init.sql"
cat > sqlite.yaml <<'EOF'
db_engine: "sqlite"
src_host: ""
src_port: ""
src_user: ""
src_pass: ""
src_db: "src.db"
tgt_host: ""
tgt_port: ""
tgt_user: ""
tgt_pass: ""
tgt_db: "tgt.db"
tgt_schema: "public"
src_ora_service: ""
tgt_ora_service: ""
dump_file: ""
EOF
chmod 600 sqlite.yaml

echo "--- dry run ---"
"$ROOT/main.sh" --config sqlite.yaml --tables users,orders --yes --dry-run
assert_eq "dry-run did not create the target file" "absent" \
  "$([[ -f tgt.db ]] && echo present || echo absent)"

echo "--- real copy ---"
"$ROOT/main.sh" --config sqlite.yaml --tables users,orders --yes
assert_eq "users copied (5 rows)" "5" "$(sqlite3 -readonly tgt.db 'SELECT COUNT(*) FROM users;')"
assert_eq "orders copied (7 rows)" "7" "$(sqlite3 -readonly tgt.db 'SELECT COUNT(*) FROM orders;')"
assert_eq "index carried over" "1" \
  "$(sqlite3 -readonly tgt.db "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_orders_user';")"

echo "--- re-run with replace (must not duplicate rows) ---"
"$ROOT/main.sh" --config sqlite.yaml --tables users --yes
assert_eq "users still 5 rows after replace" "5" "$(sqlite3 -readonly tgt.db 'SELECT COUNT(*) FROM users;')"

echo "--- missing source table fails loudly ---"
if "$ROOT/main.sh" --config sqlite.yaml --tables no_such_table --yes > /dev/null 2>&1; then
  assert_eq "missing source table exits nonzero" "nonzero" "zero"
else
  assert_eq "missing source table exits nonzero" "nonzero" "nonzero"
fi

_cross_user_for() { case "$1" in mysql) echo root ;; postgresql) echo postgres ;; *) echo "" ;; esac; }

cross_cfg() { # file src_engine tgt_engine src_host src_db tgt_host tgt_db
  cat > "$1" <<EOF
src_engine: "$2"
tgt_engine: "$3"
src_host: "$4"
src_port: ""
src_user: "$(_cross_user_for "$2")"
src_pass: "srcpass"
src_db: "$5"
tgt_host: "$6"
tgt_port: ""
tgt_user: "$(_cross_user_for "$3")"
tgt_pass: "tgtpass"
tgt_db: "$7"
tgt_schema: "public"
src_ora_service: ""
tgt_ora_service: ""
dump_file: ""
EOF
  chmod 600 "$1"
}

echo
echo "═══ Cross-engine: MySQL → PostgreSQL ═══"
cross_cfg x_m2p.yaml mysql postgresql mysql-src srcdb pg-tgt xm2p

echo "--- dry run ---"
"$ROOT/main.sh" --config x_m2p.yaml --tables notes --yes --dry-run
assert_eq "dry-run did not create the target DB" "0" \
  "$(pg_tgt_q postgres "SELECT COUNT(*) FROM pg_database WHERE datname='xm2p';")"

echo "--- real copy ---"
"$ROOT/main.sh" --config x_m2p.yaml --tables users,notes --yes
assert_eq "users copied (5 rows)" "5" "$(pg_tgt_q xm2p "SELECT count(*) FROM users;")"
assert_eq "notes copied (6 rows)" "6" "$(pg_tgt_q xm2p "SELECT count(*) FROM notes;")"
assert_eq "NULL survives" "1" "$(pg_tgt_q xm2p "SELECT count(*) FROM notes WHERE body IS NULL;")"
assert_eq "empty string stays empty (not NULL)" "1" "$(pg_tgt_q xm2p "SELECT count(*) FROM notes WHERE body = '';")"
assert_eq "embedded newline survives" "1" "$(pg_tgt_q xm2p "SELECT count(*) FROM notes WHERE position(E'\n' in body) > 0;")"
src_len=$(mysql_src_q "SELECT CHAR_LENGTH(body) FROM srcdb.notes WHERE id=4;")
assert_eq "special chars row length matches (id=4)" "$src_len" \
  "$(pg_tgt_q xm2p "SELECT length(body) FROM notes WHERE id=4;")"

echo "--- re-run with replace (must not duplicate rows) ---"
"$ROOT/main.sh" --config x_m2p.yaml --tables notes --yes
assert_eq "notes still 6 rows after replace" "6" "$(pg_tgt_q xm2p "SELECT count(*) FROM notes;")"

echo
echo "═══ Cross-engine: PostgreSQL → MySQL ═══"
cross_cfg x_p2m.yaml postgresql mysql pg-src srcdb mysql-tgt xp2m
"$ROOT/main.sh" --config x_p2m.yaml --tables users,notes --yes
assert_eq "users copied (5 rows)" "5" "$(mysql_tgt_q "SELECT COUNT(*) FROM xp2m.users;")"
assert_eq "notes copied (6 rows)" "6" "$(mysql_tgt_q "SELECT COUNT(*) FROM xp2m.notes;")"
assert_eq "NULL survives" "1" "$(mysql_tgt_q "SELECT COUNT(*) FROM xp2m.notes WHERE body IS NULL;")"
assert_eq "empty string stays empty (not NULL)" "1" "$(mysql_tgt_q "SELECT COUNT(*) FROM xp2m.notes WHERE body = '' AND body IS NOT NULL;")"
assert_eq "embedded newline survives" "1" "$(mysql_tgt_q "SELECT COUNT(*) FROM xp2m.notes WHERE INSTR(body, CHAR(10)) > 0;")"
assert_eq "boolean mapped to tinyint (true count)" "2" "$(mysql_tgt_q "SELECT COUNT(*) FROM xp2m.notes WHERE flag = 1;")"
src_len=$(PGPASSWORD=srcpass psql -hpg-src -Upostgres -d srcdb -Atc "SELECT length(body) FROM notes WHERE id=4;")
assert_eq "special chars row length matches (id=4)" "$src_len" \
  "$(mysql_tgt_q "SELECT CHAR_LENGTH(body) FROM xp2m.notes WHERE id=4;")"

echo
echo "═══ Cross-engine: MySQL → SQLite ═══"
cross_cfg x_m2s.yaml mysql sqlite mysql-src srcdb "" x_m2s.db
"$ROOT/main.sh" --config x_m2s.yaml --tables notes --yes
assert_eq "notes copied (6 rows)" "6" "$(sqlite3 -readonly x_m2s.db 'SELECT COUNT(*) FROM notes;')"
assert_eq "NULL survives" "1" "$(sqlite3 -readonly x_m2s.db 'SELECT COUNT(*) FROM notes WHERE body IS NULL;')"
assert_eq "empty string stays empty (not NULL)" "1" "$(sqlite3 -readonly x_m2s.db "SELECT COUNT(*) FROM notes WHERE body = '';")"
assert_eq "embedded newline survives" "1" "$(sqlite3 -readonly x_m2s.db 'SELECT COUNT(*) FROM notes WHERE instr(body, char(10)) > 0;')"
src_len=$(mysql_src_q "SELECT CHAR_LENGTH(body) FROM srcdb.notes WHERE id=4;")
assert_eq "special chars row length matches (id=4)" "$src_len" \
  "$(sqlite3 -readonly x_m2s.db 'SELECT length(body) FROM notes WHERE id=4;')"

echo
echo "═══ Cross-engine: PostgreSQL → SQLite ═══"
cross_cfg x_p2s.yaml postgresql sqlite pg-src srcdb "" x_p2s.db
"$ROOT/main.sh" --config x_p2s.yaml --tables notes --yes
assert_eq "notes copied (6 rows)" "6" "$(sqlite3 -readonly x_p2s.db 'SELECT COUNT(*) FROM notes;')"
assert_eq "NULL survives" "1" "$(sqlite3 -readonly x_p2s.db 'SELECT COUNT(*) FROM notes WHERE body IS NULL;')"
assert_eq "boolean mapped to integer (true count)" "2" "$(sqlite3 -readonly x_p2s.db 'SELECT COUNT(*) FROM notes WHERE flag = 1;')"
assert_eq "embedded newline survives" "1" "$(sqlite3 -readonly x_p2s.db 'SELECT COUNT(*) FROM notes WHERE instr(body, char(10)) > 0;')"

echo
echo "═══ Cross-engine: SQLite → PostgreSQL ═══"
cross_cfg x_s2p.yaml sqlite postgresql "" src.db pg-tgt xs2p
"$ROOT/main.sh" --config x_s2p.yaml --tables notes --yes
assert_eq "notes copied (6 rows)" "6" "$(pg_tgt_q xs2p "SELECT count(*) FROM notes;")"
assert_eq "NULL survives" "1" "$(pg_tgt_q xs2p "SELECT count(*) FROM notes WHERE body IS NULL;")"
assert_eq "empty string stays empty (not NULL)" "1" "$(pg_tgt_q xs2p "SELECT count(*) FROM notes WHERE body = '';")"
assert_eq "embedded newline survives" "1" "$(pg_tgt_q xs2p "SELECT count(*) FROM notes WHERE position(E'\n' in body) > 0;")"
src_len=$(sqlite3 -readonly src.db 'SELECT length(body) FROM notes WHERE id=4;')
assert_eq "special chars row length matches (id=4)" "$src_len" \
  "$(pg_tgt_q xs2p "SELECT length(body) FROM notes WHERE id=4;")"

echo
echo "═══ Cross-engine: SQLite → MySQL ═══"
cross_cfg x_s2m.yaml sqlite mysql "" src.db mysql-tgt xs2m
"$ROOT/main.sh" --config x_s2m.yaml --tables notes --yes
assert_eq "notes copied (6 rows)" "6" "$(mysql_tgt_q "SELECT COUNT(*) FROM xs2m.notes;")"
assert_eq "NULL survives" "1" "$(mysql_tgt_q "SELECT COUNT(*) FROM xs2m.notes WHERE body IS NULL;")"
assert_eq "empty string stays empty (not NULL)" "1" "$(mysql_tgt_q "SELECT COUNT(*) FROM xs2m.notes WHERE body = '' AND body IS NOT NULL;")"
assert_eq "embedded newline survives" "1" "$(mysql_tgt_q "SELECT COUNT(*) FROM xs2m.notes WHERE INSTR(body, CHAR(10)) > 0;")"

echo
echo "═══ Partial copy options ═══"
echo "--- --where (same-engine mysql) ---"
"$ROOT/main.sh" --config mysql.yaml --tables users --where "id <= 2" --yes
assert_eq "--where copies only matching rows" "2" "$(mysql_tgt_q "SELECT COUNT(*) FROM tgtdb.users;")"

echo "--- --where (same-engine sqlite, ATTACH path) ---"
"$ROOT/main.sh" --config sqlite.yaml --tables users --where "id <= 3" --yes
assert_eq "--where via ATTACH copies only matching rows" "3" "$(sqlite3 -readonly tgt.db 'SELECT COUNT(*) FROM users;')"

echo "--- --where (cross-engine mysql→pg) ---"
"$ROOT/main.sh" --config x_m2p.yaml --tables notes --where "id <= 3" --yes
assert_eq "--where works cross-engine" "3" "$(pg_tgt_q xm2p "SELECT count(*) FROM notes;")"

echo "--- --schema-only then --data-only (same-engine pg) ---"
"$ROOT/main.sh" --config pg.yaml --tables orders --schema-only --yes
assert_eq "--schema-only leaves table empty" "0" "$(pg_tgt_q tgtdb "SELECT count(*) FROM analytics.orders;")"
"$ROOT/main.sh" --config pg.yaml --tables orders --data-only --yes
assert_eq "--data-only fills the existing table" "7" "$(pg_tgt_q tgtdb "SELECT count(*) FROM analytics.orders;")"

echo "--- --schema-only then --data-only (cross-engine mysql→pg) ---"
"$ROOT/main.sh" --config x_m2p.yaml --tables orders --schema-only --yes
assert_eq "cross --schema-only creates empty table" "0" "$(pg_tgt_q xm2p "SELECT count(*) FROM orders;")"
"$ROOT/main.sh" --config x_m2p.yaml --tables orders --data-only --yes
assert_eq "cross --data-only fills the existing table" "7" "$(pg_tgt_q xm2p "SELECT count(*) FROM orders;")"

echo "--- --data-only without target table fails ---"
if "$ROOT/main.sh" --config mysql.yaml --tables no_table_here --data-only --yes > /dev/null 2>&1; then
  assert_eq "--data-only on missing table exits nonzero" "nonzero" "zero"
else
  assert_eq "--data-only on missing table exits nonzero" "nonzero" "nonzero"
fi

echo "--- --all-tables (same-engine sqlite) ---"
cat > sq_all.yaml <<'EOF'
db_engine: "sqlite"
src_db: "src.db"
tgt_db: "all.db"
EOF
chmod 600 sq_all.yaml
"$ROOT/main.sh" --config sq_all.yaml --all-tables --yes
assert_eq "--all-tables copies every table" "3" \
  "$(sqlite3 -readonly all.db "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")"
assert_eq "--all-tables data present" "5" "$(sqlite3 -readonly all.db 'SELECT COUNT(*) FROM users;')"

echo
echo "═══ Legacy config format (single-server copy) ═══"
cat > legacy.yaml <<'EOF'
db_engine: "mysql"
db_host: "mysql-src"
db_port: "3306"
db_user: "root"
db_pass: "srcpass"
source_db: "srcdb"
target_db: "legacydb"
target_schema: "public"
ora_service: ""
dump_file: ""
EOF
chmod 600 legacy.yaml

"$ROOT/main.sh" --config legacy.yaml --tables users --yes
assert_eq "legacy config: same-server copy (5 rows)" "5" \
  "$(mysql_src_q "SELECT COUNT(*) FROM legacydb.users;")"

echo
echo "═══ Results: $PASS passed, $FAIL failed ═══"
[[ $FAIL -eq 0 ]]
