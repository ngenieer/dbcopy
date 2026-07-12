# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- **`--incremental --key COL`**: stateless append-only sync — copies only
  rows newer than the target's `MAX(key)`; missing target tables get a
  full copy. Works same-engine and cross-engine (not Oracle).
- Cross-engine copies now support **binary columns** (`blob`/`bytea`/
  `varbinary`): data is transported hex-encoded and decoded on arrival,
  NUL bytes and empty blobs included.

### Changed
- CI caches the test-runner image (Oracle Instant Client download) —
  integration runs are faster on unchanged Dockerfiles.

## [1.0.0] - 2026-07-12

First stable release.

### Added
- **Cross-engine copy** between MySQL/MariaDB ↔ PostgreSQL ↔ SQLite (all 6
  directions): automatic target-table creation via a generic type map and
  NULL-safe data streaming.
- **Separate source/target connections** (`src_*` / `tgt_*` config keys) —
  copy between different servers. The legacy single-server config format is
  still read.
- **SQLite engine** (`db_engine: "sqlite"`, file-path based).
- **Non-interactive CLI**: `--tables`, `--all-tables`, `-y/--yes`,
  `--config`, `--full-backup`, `--help`.
- **Partial copies**: `--where EXPR`, `--schema-only`, `--data-only`.
- **`--parallel N`** concurrent table copies (SQLite targets stay
  sequential; requires `--yes`).
- **Verification**: row counts after every copy; `--checksum` for
  order-independent content comparison (same-engine).
- **Backup operations**: `--compress` (gzip) and `--keep-backups N`
  retention pruning.
- **Integration test suite** (82 assertions) against dockerized MySQL 8,
  MariaDB 11, PostgreSQL 16, Oracle Free 23ai, and SQLite, run in GitHub
  Actions on every push, plus shellcheck linting.

### Fixed
- Passwords no longer appear in the process list (`MYSQL_PWD`/`PGPASSWORD`,
  sqlplus stdin `CONNECT`, mode-600 Data Pump parameter files) or world-
  readable files (config is mode 600 and password-masked when displayed).
- SQL injection via table/DB/schema/column names (whitelist validation).
- PostgreSQL: missing `-p` port on several calls; schema remap silently
  broken on pg_dump ≥ 11; duplicate inserts when declining a replace.
- MySQL: replacing FK-referenced tables (ERROR 3730), false positives in
  existence checks, MariaDB/MySQL dump-flag differences.
- Oracle: expdp/impdp never authenticated via stdin; unqualified `tables=`
  resolved against the wrong schema; re-copies failed on existing tables.
- Failures are logged as failures (no more unconditional "Copied" log lines)
  and propagate to the exit code.

[1.0.0]: https://github.com/ngenieer/dbcopy/releases/tag/v1.0.0
