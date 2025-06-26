# dbcopy

A modular, interactive Bash utility that safely copies specific tables between **MySQL**, **PostgreSQL**, and **Oracle** databases—now with a **full backup option** and configuration stored in YAML.

---

## 🚀 Features

- 📋 Interactive prompts for connection info (stored in `.dbcopy_config.yaml`)
- 🛡️ `--dry-run` mode to preview changes before applying
- 🧰 Modular codebase: easy to read, extend, and maintain
- 📦 Full database backup option (skips table copy if selected)
- 🪵 Table-level logging to `dbcopy.log`
- 🧠 Remembers connection settings for reuse

---

## 🧩 Requirements

| Tool        | Purpose                    |
|-------------|----------------------------|
| `bash`      | Core scripting engine       |
| `yq`        | YAML parsing                |
| `mysql`     | Required for MySQL          |
| `psql`      | Required for PostgreSQL     |
| `sqlplus`, `expdp`, `impdp` | Oracle backup/migration |

Install `yq`:

```bash
# On Ubuntu/Debian
sudo apt install yq

# On macOS
brew install yq

