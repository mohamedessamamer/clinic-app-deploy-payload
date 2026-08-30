#!/bin/bash
# Clinic app — batch 43: per-tooth orthodontic bracket stock (American / Ormco).
set -euo pipefail

APP_DIR="/opt/clinic-app"
ARCHIVE="clinic-app-batch43.tar.gz"
REPO_RAW="https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main"
BACKUP_DIR="/opt/clinic-app/data.backup-batch43-$(date +%Y%m%d%H%M%S)"

echo "== stopping app =="
systemctl stop clinic-app
echo "== backing up clinic data =="
cp -a "$APP_DIR/data" "$BACKUP_DIR"
echo "Backup: $BACKUP_DIR"

if ! command -v make >/dev/null 2>&1; then
  echo "== installing build tools =="
  apt-get update
  apt-get install -y build-essential
fi

echo "== downloading batch 43 =="
cd /tmp
rm -f "$ARCHIVE"
curl --fail --location --output "$ARCHIVE" "$REPO_RAW/$ARCHIVE?cachebust=$(date +%s)"
tar -tzf "$ARCHIVE" >/dev/null

echo "== extracting source =="
tar -xzf "$ARCHIVE" -C "$APP_DIR"
echo "== checking bracket stock update =="
grep -q "orthodontic_bracket_stock" "$APP_DIR/src/lib/db/schema.sql"
grep -q "bonding_bracket_brand" "$APP_DIR/src/app/patients/[id]/orthodontics/ortho-v2-actions.ts"
grep -q "OrthodonticBracketStock" "$APP_DIR/src/components/InventoryBrowser.tsx"

echo "== installing dependencies and building =="
cd "$APP_DIR"
npm ci
rm -rf .next
npm run build
echo "== starting app =="
systemctl start clinic-app
sleep 2
systemctl is-active --quiet clinic-app
systemctl status clinic-app --no-pager
echo "== deploy 43 completed =="
echo "Database backup: $BACKUP_DIR"
