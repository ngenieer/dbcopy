#!/bin/bash

CONFIG_FILE=".dbcopy_config.yaml"
LOG_FILE="dbcopy.log"
DRY_RUN=false

# 🧪 Check for --dry-run flag
if [[ "$1" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "🧪 DRY RUN mode: No changes will be made."
fi

# 🧩 Load modular components
source config_loader.sh
source prompt_for_config.sh
source verify_connection.sh
source full_backup.sh
source copy_tables.sh

# 📦 Load or prompt for connection config
load_config "$CONFIG_FILE"
if [[ $? -ne 0 ]]; then
  prompt_and_save_config "$CONFIG_FILE"
fi

# 🔌 Verify connection
verify_connection || exit 1

# 🗂 Optional full backup
read -p "Do you want to create a full backup of the source DB? (y/n): " full_backup
if [[ "$full_backup" =~ ^[Yy]$ ]]; then
  perform_full_backup
  echo "✅ Full backup completed. Skipping table copy as requested."
  exit 0
fi

# 🚛 Proceed with table copying
copy_tables "$DRY_RUN" "$LOG_FILE"

