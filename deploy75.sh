#!/bin/bash
# Clinic app — batch 75: patient deletion crash fix (bracket/inventory stock ledger
# FK) + auto stock restore, and billing page UI cleanup.
set -euo pipefail

APP_DIR="/opt/clinic-app"
ARCHIVE="clinic-app-batch75.tar.gz"
REPO_RAW="https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main"
BACKUP_DIR="/opt/clinic-app/data.backup-batch75-$(date +%Y%m%d%H%M%S)"

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

echo "== downloading batch 75 =="
cd /tmp
rm -f "$ARCHIVE"
curl --fail --location --output "$ARCHIVE" "$REPO_RAW/$ARCHIVE?cachebust=$(date +%s)"
tar -tzf "$ARCHIVE" >/dev/null

echo "== extracting source =="
tar -xzf "$ARCHIVE" -C "$APP_DIR"
echo "== checking batch 75 files =="
test -f "$APP_DIR/src/app/patients/actions.ts"
grep -q "bracketConsumption" "$APP_DIR/src/app/patients/actions.ts"
grep -q "returnInventoryItem" "$APP_DIR/src/app/patients/actions.ts"
grep -q "orthodontic_bracket_stock_movements" "$APP_DIR/src/app/patients/actions.ts"
grep -q "bdi dir=\"ltr\"" "$APP_DIR/src/app/patients/[id]/billing/page.tsx"
grep -q "الملف الطبي" "$APP_DIR/src/app/patients/[id]/billing/page.tsx"

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
echo "== deploy 75 completed =="
echo "Database backup: $BACKUP_DIR"
