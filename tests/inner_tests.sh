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
