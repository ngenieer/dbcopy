# dbcopy

A modular, interactive Bash utility that safely copies specific tables between **MySQL**, **PostgreSQL**, and **Oracle** databases—now with a **full backup option** and configuration stored in YAML.

---

## 🚀 Features

- 📋 Interactive prompts for connection info (stored in `.dbcopy_config.yaml`, mode `600`)
- 🛡️ `--dry-run` mode to preview changes before applying
- 🧰 Modular codebase: easy to read, extend, and maintain
- 📦 Full database backup option (skips table copy if selected)
- 🪵 Table-level logging to `dbcopy.log` (successes *and* failures)
- 🧠 Remembers connection settings for reuse
- 🔒 Passwords are never passed on the command line (kept out of `ps` output)
- ✅ Table/DB/schema names are whitelist-validated before being used in SQL

---

## 🧩 Requirements

| Tool        | Purpose                    |
|-------------|----------------------------|
| `bash`      | Core scripting engine       |
| `mysql`, `mysqldump` | Required for MySQL |
| `psql`, `pg_dump`, `createdb` | Required for PostgreSQL |
| `sqlplus`, `expdp`, `impdp` | Oracle backup/migration |

No other dependencies — YAML config parsing is handled by the scripts themselves.

---

## 📖 Usage

```bash
# Preview what would happen, without touching anything
./main.sh --dry-run

# Run for real
./main.sh
```

The script will:

1. Load `.dbcopy_config.yaml` from the current directory (or prompt for connection details and save them).
2. Verify the database connection.
3. Offer a full backup of the source DB (written to `backup_<timestamp>/`; if chosen, table copy is skipped).
4. Prompt for space-separated table names and copy each one from the source DB to the target DB, asking before replacing existing tables.

---

## ⚠️ Notes & limitations

- Source and target databases must be on the **same server** (one set of connection credentials).
- The config file stores the DB password in **plain text** (file mode `600`). It is `.gitignore`d — never commit it. For stronger protection use `~/.my.cnf`, `~/.pgpass`, or an Oracle wallet.
- MySQL copies use `CREATE TABLE ... LIKE` + `INSERT ... SELECT`, which does **not** carry over foreign keys or triggers.
- PostgreSQL copies assume the source table lives in the `public` schema; a non-`public` target schema is handled by restoring into `public` and then `ALTER TABLE ... SET SCHEMA`.
- Oracle copies use Data Pump via `DATA_PUMP_DIR` on the server; `remap_schema` maps the source schema to the target schema.
