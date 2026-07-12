# dbcopy

[![CI](https://github.com/ngenieer/dbcopy/actions/workflows/ci.yml/badge.svg)](https://github.com/ngenieer/dbcopy/actions/workflows/ci.yml)

A modular Bash utility that copies tables between **MySQL**, **MariaDB**, **PostgreSQL**, **Oracle**, and **SQLite** — on one server, across servers, or even **across engines**. Works interactively or fully non-interactively (cron/CI), filters rows with `--where`, copies tables in parallel, and verifies every copy by row count (optionally by content checksum).

---

## 🚀 Features

**Copying**
- 🔀 **Cross-engine copy** between MySQL/MariaDB ↔ PostgreSQL ↔ SQLite (all 6 directions): the target table is created automatically from the source schema via a type map, and data streams through a NULL-safe interchange format
- 🌐 Separate source and target connections — copy between different servers
- 📋 `--tables a,b,c` or `--all-tables`; `--where` to copy only matching rows; `--schema-only` / `--data-only` to split structure and data
- ⚡ `--parallel N` copies multiple tables concurrently

**Safety & verification**
- 🔢 Row-count verification after every copy; `--checksum` adds order-independent content comparison (same-engine)
- 🛡️ `--dry-run` previews everything without touching the target
- ✅ Table/DB/schema/column names are whitelist-validated before being used in SQL
- 🔒 Passwords never appear on a command line (`MYSQL_PWD`/`PGPASSWORD`, sqlplus stdin, mode-600 Data Pump parameter files)
- 🪵 Table-level logging to `dbcopy.log` (successes, failures, and mismatches)

**Operations**
- 🤖 Fully non-interactive with `--tables ... --yes` — cron/CI friendly, nonzero exit on any failure
- 📦 `--full-backup` for a full source dump, with `--compress` (gzip) and `--keep-backups N` retention
- 🧠 Connection settings saved to `.dbcopy_config.yaml` (mode `600`) on first interactive run
- 🧪 82-assertion docker-compose integration suite covering all five engines (`tests/run_tests.sh`)

---

## 🧩 Requirements

| Tool | Purpose |
|------|---------|
| `bash` | Core scripting engine |
| `mysql`, `mysqldump` | MySQL/MariaDB (either vendor's client; use engine `mysql` for both) |
| `psql`, `pg_dump` | PostgreSQL |
| `sqlite3` | SQLite |
| `sqlplus`, `expdp`, `impdp` | Oracle |

Only the clients for the engines you actually use are needed. No other dependencies — YAML config parsing is handled by the scripts themselves.

---

## 📥 Installation

```bash
git clone https://github.com/ngenieer/dbcopy.git
cd dbcopy
./main.sh --help
```

That's it — dbcopy is plain Bash. Install the client tools for the engines you use (see Requirements above), or add the repo directory to your `PATH`.

---

## 📖 Usage

```bash
# Interactive (prompts for everything, saves the config for next time)
./main.sh

# Preview without touching anything
./main.sh --dry-run

# Cron/CI: copy two tables, replacing them if they exist
./main.sh --config prod.yaml --tables users,orders --yes

# Grab only recent rows from every table, four tables at a time
./main.sh --all-tables --where "created_at > '2026-06-01'" --parallel 4 --yes

# Structure first, data later (e.g. to review DDL in between)
./main.sh --tables events --schema-only --yes
./main.sh --tables events --data-only --yes

# Copy and verify the actual contents, not just row counts
./main.sh --tables billing --checksum --yes

# Nightly compressed backup, keeping the last 7
./main.sh --full-backup --compress --keep-backups 7 --yes
```

### Options

| Option | Description |
|--------|-------------|
| `--config FILE` | Config file to use (default: `.dbcopy_config.yaml`) |
| `--tables LIST` | Comma/space-separated table names (skips the prompt) |
| `--all-tables` | Copy every table in the source database |
| `--where EXPR` | Only copy rows matching a SQL condition (applied to every selected table; not for Oracle) |
| `--schema-only` | Create table structures without copying rows |
| `--data-only` | Copy rows into existing target tables (truncates them first) |
| `--parallel N` | Copy up to N tables concurrently (requires `--yes`; SQLite targets run sequentially) |
| `--checksum` | Compare an order-independent md5 of the full table contents after each copy (same-engine only; keep server versions aligned so values render identically) |
| `--dry-run` | Preview changes without applying them |
| `-y`, `--yes` | Non-interactive: use the saved config and replace existing target tables without asking |
| `--full-backup` | Perform a full backup of the source DB and exit |
| `--compress` | gzip the backup dump (mysql/postgresql/sqlite) |
| `--keep-backups N` | After a successful backup, keep only the N newest `backup_*` directories |
| `-h`, `--help` | Show usage |

### Config file

Created on first interactive run (mode `600`, passwords in plain text — it is `.gitignore`d, never commit it):

```yaml
db_engine: "mysql"
src_host: "db1.internal"
src_port: "3306"
src_user: "reader"
src_pass: "..."
src_db: "prod"
tgt_host: "db2.internal"
tgt_port: "3306"
tgt_user: "writer"
tgt_pass: "..."
tgt_db: "staging"
tgt_schema: "public"        # PostgreSQL only
src_ora_service: ""         # Oracle only
tgt_ora_service: ""         # Oracle only
dump_file: ""               # Oracle only
```

The legacy single-server format (`db_host:` / `source_db:` / `target_db:`) is still read and treated as one server acting as both source and target.

For SQLite, `src_db` / `tgt_db` are **file paths** (the target file is created if missing) and the host/port/user/pass fields are ignored:

```yaml
db_engine: "sqlite"
src_db: "/data/prod-snapshot.db"
tgt_db: "./local-copy.db"
```

### Cross-engine copy

Set `src_engine` and `tgt_engine` to different engines (`db_engine` is then unnecessary). Any direction between `mysql`, `postgresql`, and `sqlite` works; Oracle is excluded:

```yaml
src_engine: "mysql"
tgt_engine: "postgresql"
src_host: "db1.internal"
src_user: "reader"
src_pass: "..."
src_db: "prod"
tgt_host: "warehouse.internal"
tgt_user: "writer"
tgt_pass: "..."
tgt_db: "staging"
tgt_schema: "public"
```

What carries over: columns (via a generic type map), `NOT NULL`, and the primary key. What does **not**: secondary indexes, foreign keys, auto-increment/identity, defaults, and triggers. Binary types (`blob`/`bytea`/`varbinary`) are rejected loudly. Column names must match `[A-Za-z0-9_]+`.

---

## 🧪 Tests

The integration suite spins up source/target MySQL 8, MariaDB 11, PostgreSQL 16, and Oracle Free 23ai servers with docker compose and runs dbcopy against them — plus a file-based SQLite pass. 82 assertions cover dry-run safety, cross-server and all six cross-engine directions (including tabs/newlines/quotes/Korean text/NULL-vs-empty-string edge data), partial-copy options, parallel copy, checksum verification, backup compression/retention, replace-without-duplicates, non-`public` target schemas, and the legacy config format:

```bash
tests/run_tests.sh   # requires docker compose
```

The same suite runs in GitHub Actions on every push and pull request, alongside a shellcheck lint pass.

---

## ⚠️ Notes & limitations

- **Oracle** copies are same-server only (Data Pump via `DATA_PUMP_DIR`); use `NETWORK_LINK` for cross-server transfers. `--where`/`--schema-only`/`--data-only`/`--checksum` are not supported for Oracle. Data Pump credentials are passed via a mode-600 parameter file that is deleted right after the run.
- MySQL copies go through `mysqldump | mysql`, so indexes, foreign keys, and triggers carry over. Replacing a table that other tables reference re-attaches their FKs to the new copy.
- PostgreSQL copies assume the source table lives in the `public` schema; a non-`public` target schema is handled by restoring into `public` and then `ALTER TABLE ... SET SCHEMA`. Replacing a table referenced by another table's FK will fail loudly (drop the constraint first).
- SQLite full-table copies use `sqlite3 .dump`, whose argument is a `LIKE` pattern — a `_` in a table name acts as a single-character wildcard, so a rare similarly-named table could be included. (`--where` copies use `ATTACH` + `INSERT ... SELECT` instead.)
- Cross-engine copies **into MySQL** use `LOAD DATA LOCAL INFILE`, which requires `local_infile=ON` on the target server.
- Cross-engine NULLs travel as a sentinel string (`__dbcopy_null_7f3a9c__`); a field containing that exact text would arrive as NULL.
- Cross-engine copies read the source table from the `public` schema when the source is PostgreSQL.
- For stronger credential protection use `~/.my.cnf`, `~/.pgpass`, or an Oracle wallet; TLS settings are also left to your client config.

---

## 📄 License

[MIT](LICENSE)
