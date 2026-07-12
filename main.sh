#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE=".dbcopy_config.yaml"
LOG_FILE="dbcopy.log"
DRY_RUN=false
ASSUME_YES=false
DO_FULL_BACKUP=false
TABLES_ARG=""

usage() {
  cat <<'EOF'
Usage: main.sh [options]

Options:
  --dry-run           Preview changes without applying them
  --config FILE       Config file to use (default: .dbcopy_config.yaml)
  --tables LIST       Comma/space-separated table names (skips the prompt)
  -y, --yes           Non-interactive: use the saved config and replace
                      existing target tables without asking
  --full-backup       Perform a full backup of the source DB and exit
  -h, --help          Show this help

With --tables and --yes, dbcopy runs fully non-interactively (cron/CI friendly).
EOF
}

# 🧭 Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    -y|--yes) ASSUME_YES=true ;;
    --full-backup) DO_FULL_BACKUP=true ;;
    --tables) TABLES_ARG="${2:?--tables requires a value}"; shift ;;
    --tables=*) TABLES_ARG="${1#*=}" ;;
    --config) CONFIG_FILE="${2:?--config requires a value}"; shift ;;
    --config=*) CONFIG_FILE="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "❌ Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

if [[ "$DRY_RUN" == true ]]; then
  echo "🧪 DRY RUN mode: No changes will be made."
fi

# 🧩 Load modular components
# shellcheck source=utils.sh
source "$SCRIPT_DIR/utils.sh"
# shellcheck source=config_loader.sh
source "$SCRIPT_DIR/config_loader.sh"
# shellcheck source=prompt_for_config.sh
source "$SCRIPT_DIR/prompt_for_config.sh"
# shellcheck source=verify_connection.sh
source "$SCRIPT_DIR/verify_connection.sh"
# shellcheck source=full_backup.sh
source "$SCRIPT_DIR/full_backup.sh"
# shellcheck source=copy_tables.sh
source "$SCRIPT_DIR/copy_tables.sh"

# 📦 Load or prompt for connection config
if ! load_config "$CONFIG_FILE"; then
  if [[ "$ASSUME_YES" == true ]]; then
    echo "❌ --yes given but no usable config at $CONFIG_FILE — run once interactively first." >&2
    exit 1
  fi
  prompt_and_save_config "$CONFIG_FILE"
fi

# 🛡 Reject values that could break out of SQL / connect strings
validate_config || exit 1

# 🔌 Verify source and target connections
verify_connection || exit 1

# 🗂 Full backup (flag, or interactive question)
if [[ "$DO_FULL_BACKUP" == true ]]; then
  perform_full_backup || exit 1
  echo "✅ Full backup completed."
  exit 0
fi

if [[ "$ASSUME_YES" == false && -z "$TABLES_ARG" ]]; then
  read -p "Do you want to create a full backup of the source DB? (y/n): " full_backup
  if [[ "$full_backup" =~ ^[Yy]$ ]]; then
    perform_full_backup || exit 1
    echo "✅ Full backup completed. Skipping table copy as requested."
    exit 0
  fi
fi

# 🚛 Proceed with table copying
copy_tables "$DRY_RUN" "$LOG_FILE" "$TABLES_ARG"
