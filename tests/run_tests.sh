#!/bin/bash
# Integration tests: spins up source/target MySQL + PostgreSQL servers with
# docker compose and runs dbcopy against them (non-interactive mode).
# Usage: tests/run_tests.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

cleanup() {
  docker compose down -v --remove-orphans > /dev/null 2>&1 || true
}
trap cleanup EXIT

docker compose build runner
docker compose up -d --wait mysql-src mysql-tgt pg-src pg-tgt
docker compose run --rm runner

echo "🎉 All integration tests passed."
