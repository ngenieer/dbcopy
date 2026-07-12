# dbcopy

[![CI](https://github.com/ngenieer/dbcopy/actions/workflows/ci.yml/badge.svg)](https://github.com/ngenieer/dbcopy/actions/workflows/ci.yml)

A modular Bash utility that safely copies specific tables between **MySQL**, **MariaDB**, **PostgreSQL**, **Oracle**, and **SQLite** databases — interactively or fully non-interactively, on one server or **across servers**, with a **full backup option** and row-count verification after every copy.

---

## 🚀 Features

- 🌐 Separate source and target connections — copy between different servers (MySQL/PostgreSQL)
- 🤖 Non-interactive mode (`--tables ... --yes`) for cron/CI
- 🔢 Row-count verification after each copy (mismatches are reported and logged)
- 📋 Interactive prompts for connection info (stored in `.dbcopy_config.yaml`, mode `600`)
- 🛡️ `--dry-run` mode to preview changes before applying
- 📦 Full database backup option (`--full-backup`)
- 🪵 Table-level logging to `dbcopy.log` (successes *and* failures)
- 🔒 Passwords are never passed on the command line (kept out of `ps` output)
- ✅ Table/DB/schema names are whitelist-validated before being used in SQL
- 🧪 Docker-compose integration tests (`tests/run_tests.sh`)

---

## 🧩 Requirements

| Tool        | Purpose                    |
|-------------|----------------------------|
| `bash`      | Core scripting engine       |
| `mysql`, `mysqldump` | Required for MySQL/MariaDB (either vendor's client works; use `db_engine: "mysql"` for both) |
| `psql`, `pg_dump` | Required for PostgreSQL |
| `sqlplus`, `expdp`, `impdp` | Oracle backup/migration |
| `sqlite3` | Required for SQLite |

No other dependencies — YAML config parsing is handled by the scripts themselves.

---

## 📖 Usage

```bash
# Interactive (prompts for everything, saves the config for next time)
./main.sh

# Preview without touching anything
./main.sh --dry-run

# Fully non-interactive (cron/CI): copy two tables, replace if they exist
./main.sh --config prod.yaml --tables users,orders --yes

# Full backup of the source DB, then exit
./main.sh --full-backup --yes
```

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview changes without applying them |
| `--config FILE` | Config file to use (default: `.dbcopy_config.yaml`) |
| `--tables LIST` | Comma/space-separated table names (skips the prompt) |
| `-y`, `--yes` | Use the saved config and replace existing target tables without asking |
| `--full-backup` | Perform a full backup of the source DB and exit |

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

---

## 🧪 Tests

Integration tests spin up source/target MySQL 8, MariaDB 11, and PostgreSQL 16 servers with docker compose and run dbcopy against them — plus a file-based SQLite pass (dry-run, cross-server copy, replace-without-duplicates, non-`public` target schema, legacy config):

```bash
tests/run_tests.sh   # requires docker compose
```

---

## ⚠️ Notes & limitations

- **Oracle** copies are same-server only (Data Pump via `DATA_PUMP_DIR`); use `NETWORK_LINK` for cross-server transfers. The Oracle path is not covered by the docker tests.
- MySQL copies go through `mysqldump | mysql`, so indexes, foreign keys, and triggers carry over. Replacing a table that other tables reference re-attaches their FKs to the new copy.
- PostgreSQL copies assume the source table lives in the `public` schema; a non-`public` target schema is handled by restoring into `public` and then `ALTER TABLE ... SET SCHEMA`. Replacing a table referenced by another table's FK will fail loudly (drop the constraint first).
- SQLite table selection uses `sqlite3 .dump`, whose argument is a `LIKE` pattern — a `_` in a table name acts as a single-character wildcard, so a rare similarly-named table could be included.
- For stronger credential protection use `~/.my.cnf`, `~/.pgpass`, or an Oracle wallet; TLS settings are also left to your client config.
