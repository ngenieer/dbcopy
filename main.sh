#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE=".dbcopy_config.yaml"
LOG_FILE="dbcopy.log"
DRY_RUN=false

# 🧪 Check for --dry-run flag
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "🧪 DRY RUN mode: No changes will be made."
fi

# 🧩 Load modular components
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/config_loader.sh"
source "$SCRIPT_DIR/prompt_for_config.sh"
source "$SCRIPT_DIR/verify_connection.sh"
source "$SCRIPT_DIR/full_backup.sh"
source "$SCRIPT_DIR/copy_tables.sh"

# 📦 Load or prompt for connection config
if ! load_config "$CONFIG_FILE"; then
  prompt_and_save_config "$CONFIG_FILE"
fi

# 🛡 Reject values that could break out of SQL / connect strings
validate_config || exit 1

# 🔌 Verify connection
verify_connection || exit 1

# 🗂 Optional full backup
read -p "Do you want to create a full backup of the source DB? (y/n): " full_backup
if [[ "$full_backup" =~ ^[Yy]$ ]]; then
  perform_full_backup || exit 1
  echo "✅ Full backup completed. Skipping table copy as requested."
  exit 0
fi

# 🚛 Proceed with table copying
copy_tables "$DRY_RUN" "$LOG_FILE"
