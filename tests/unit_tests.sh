#!/bin/bash
# Fast unit tests — no docker, no database servers needed.
# Usage: tests/unit_tests.sh
#
# The globals assigned throughout are consumed by the sourced functions
# (validate_config, confirm, ...) — not unused, despite what SC2034 thinks.
# shellcheck disable=SC2034
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../utils.sh
source "$ROOT/utils.sh"
# shellcheck source=../cross_engine.sh
source "$ROOT/cross_engine.sh"
# shellcheck source=../full_backup.sh
source "$ROOT/full_backup.sh"

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

assert_ok() {
  local desc="$1"
  shift
  if "$@" > /dev/null 2>&1; then
    echo "  ✅ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $desc — expected success, got failure"
    FAIL=$((FAIL + 1))
  fi
}

assert_fail() {
  local desc="$1"
  shift
  if "$@" > /dev/null 2>&1; then
    echo "  ❌ $desc — expected failure, got success"
    FAIL=$((FAIL + 1))
  else
    echo "  ✅ $desc"
    PASS=$((PASS + 1))
  fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "═══ config_get ═══"
cat > c.yaml <<'EOF'
db_engine: "mysql"
src_pass: "p@ss w0rd$123"
tgt_db: "staging"
EOF
assert_eq "plain value" "mysql" "$(config_get c.yaml db_engine)"
assert_eq "special characters preserved" 'p@ss w0rd$123' "$(config_get c.yaml src_pass)"
assert_eq "missing key yields empty" "" "$(config_get c.yaml nonexistent)"

echo "═══ validators ═══"
assert_ok "identifier accepts users" validate_identifier users "test"
assert_fail "identifier rejects SQL injection" validate_identifier "users; DROP TABLE x" "test"
assert_fail "identifier rejects backtick" validate_identifier 'a`b' "test"
assert_fail "identifier rejects empty" validate_identifier "" "test"
assert_ok "hostname accepts FQDN" validate_hostname db-1.example.com "host"
assert_fail "hostname rejects slash" validate_hostname "evil/host" "host"
assert_ok "port accepts number" validate_port 5432
assert_ok "port accepts empty (optional)" validate_port ""
assert_fail "port rejects command injection" validate_port "5432; rm -rf /"

echo "═══ validate_config engine rules ═══"
_set_cfg() {
  DB_ENGINE="$1" SRC_ENGINE="$2" TGT_ENGINE="$3"
  SRC_HOST=h TGT_HOST=h SRC_PORT="" TGT_PORT="" SRC_DB=srcdb TGT_DB=tgtdb
  SRC_USER=u TGT_USER=u SRC_PASS=p TGT_PASS=p TGT_SCHEMA=public
  SRC_ORA_SERVICE=svc TGT_ORA_SERVICE=svc DUMP_FILE=dump
}
_set_cfg mysql mysql mysql
assert_ok "same-engine mysql accepted" validate_config
_set_cfg mysql mysql postgresql
assert_ok "cross mysql→pg accepted" validate_config
_set_cfg oracle oracle postgresql
assert_fail "cross involving oracle rejected" validate_config
_set_cfg bogus bogus bogus
assert_fail "unknown engine rejected" validate_config
_set_cfg sqlite sqlite sqlite
SRC_DB=/tmp/same.db TGT_DB=/tmp/same.db
assert_fail "sqlite identical src/tgt files rejected" validate_config
SRC_DB=/tmp/a.db TGT_DB=/tmp/b.db
assert_ok "sqlite distinct files accepted" validate_config
_set_cfg mysql mysql mysql
TGT_DB='evil"db'
assert_fail "bad target DB name rejected" validate_config

echo "═══ confirm ═══"
ASSUME_YES=true
assert_ok "--yes auto-confirms" confirm "Proceed?"
ASSUME_YES=false
assert_ok "interactive y confirms" bash -c 'source "'"$ROOT"'/utils.sh"; ASSUME_YES=false confirm "Proceed?" <<< "y"'
assert_fail "interactive n declines" bash -c 'source "'"$ROOT"'/utils.sh"; ASSUME_YES=false confirm "Proceed?" <<< "n"'

echo "═══ report_copy_result ═══"
log=$(mktemp)
assert_ok "matching counts pass" report_copy_result t1 5 5 "$log"
assert_fail "mismatched counts fail" report_copy_result t2 5 4 "$log"
assert_eq "mismatch is logged" "1" "$(grep -c 'MISMATCH t2' "$log")"

echo "═══ cross-engine type mapping ═══"
SRC_ENGINE=mysql
assert_eq "mysql decimal(10,2)" "NUMERIC(10,2)" "$(_cross_generic_type decimal 0 10 2)"
assert_eq "mysql varchar(50)" "VARCHAR(50)" "$(_cross_generic_type varchar 50 0 0)"
assert_eq "mysql blob → BINARY" "BINARY" "$(_cross_generic_type blob 0 0 0)"
assert_fail "mysql geometry unsupported" _cross_generic_type geometry 0 0 0
SRC_ENGINE=postgresql
assert_eq "pg timestamptz → TIMESTAMP" "TIMESTAMP" "$(_cross_generic_type 'timestamp with time zone' 0 0 0)"
assert_eq "pg bytea → BINARY" "BINARY" "$(_cross_generic_type bytea 0 0 0)"
assert_eq "pg unbounded varchar → TEXT" "TEXT" "$(_cross_generic_type 'character varying' 0 0 0)"
SRC_ENGINE=sqlite
assert_eq "sqlite free-form INTEGER → BIGINT" "BIGINT" "$(_cross_generic_type integer 0 0 0)"
assert_eq "sqlite BLOB → BINARY" "BINARY" "$(_cross_generic_type blob 0 0 0)"
TGT_ENGINE=mysql
assert_eq "render BOOL → tinyint(1) (mysql)" "tinyint(1)" "$(_cross_render_type BOOL)"
TGT_ENGINE=postgresql
assert_eq "render NUMERIC(10,2) (pg)" "numeric(10,2)" "$(_cross_render_type 'NUMERIC(10,2)')"
assert_eq "render BINARY → bytea (pg)" "bytea" "$(_cross_render_type BINARY)"
TGT_ENGINE=sqlite
assert_eq "render BINARY → BLOB (sqlite)" "BLOB" "$(_cross_render_type BINARY)"

echo "═══ incremental guard ═══"
# _inc_guard_value lives in copy_tables.sh — sourcing only defines functions.
# shellcheck source=../copy_tables.sh
source "$ROOT/copy_tables.sh"
assert_ok "numeric key value accepted" _inc_guard_value "12345"
assert_ok "timestamp key value accepted" _inc_guard_value "2026-07-12 10:00:00"
assert_fail "quoted key value refused" _inc_guard_value "x' OR '1'='1"

echo "═══ _prune_backups ═══"
mkdir -p backup_20260101_000000 backup_20260102_000000 backup_20260103_000000 unrelated_backup_dir
_prune_backups 2
remaining=0
for d in backup_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]; do
  if [[ -d "$d" ]]; then remaining=$((remaining + 1)); fi
done
assert_eq "keeps only the 2 newest" "2" "$remaining"
assert_eq "oldest pruned" "absent" "$([[ -d backup_20260101_000000 ]] && echo present || echo absent)"
assert_eq "newest survives" "present" "$([[ -d backup_20260103_000000 ]] && echo present || echo absent)"
assert_eq "non-matching dirs untouched" "present" "$([[ -d unrelated_backup_dir ]] && echo present || echo absent)"

echo "═══ main.sh flag validation (exits before any connection) ═══"
M="$ROOT/main.sh"
assert_ok "--help exits 0" "$M" --help
assert_fail "unknown option rejected" "$M" --frobnicate
assert_fail "--schema-only + --data-only rejected" "$M" --schema-only --data-only
assert_fail "--where + --schema-only rejected" "$M" --schema-only --where "id > 1"
assert_fail "--tables + --all-tables rejected" "$M" --tables a --all-tables
assert_fail "--parallel without --yes rejected" "$M" --parallel 2
assert_fail "--parallel 0 rejected" "$M" --parallel 0 --yes
assert_fail "--incremental without --key rejected" "$M" --incremental --yes
assert_fail "--key without --incremental rejected" "$M" --key id
assert_fail "--incremental + --where rejected" "$M" --incremental --key id --where "x" --yes
assert_fail "--keep-backups junk rejected" "$M" --keep-backups abc

echo
echo "═══ Results: $PASS passed, $FAIL failed ═══"
[[ $FAIL -eq 0 ]]
