#!/bin/bash
# Clinic app — batch 73: previous visits, secure doctor reports, menus, permissions, treatment form, and header refinements.
set -euo pipefail

APP_DIR="/opt/clinic-app"
ARCHIVE="clinic-app-batch73.tar.gz"
REPO_RAW="https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main"
BACKUP_DIR="/opt/clinic-app/data.backup-batch73-$(date +%Y%m%d%H%M%S)"

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

echo "== downloading batch 73 =="
cd /tmp
rm -f "$ARCHIVE"
curl --fail --location --output "$ARCHIVE" "$REPO_RAW/$ARCHIVE?cachebust=$(date +%s)"
tar -tzf "$ARCHIVE" >/dev/null

echo "== extracting source =="
tar -xzf "$ARCHIVE" -C "$APP_DIR"
echo "== checking batch 73 files =="
test -f "$APP_DIR/src/lib/report-access.ts"
test -f "$APP_DIR/src/lib/format-notes.ts"
test -f "$APP_DIR/src/components/HeaderBackButton.tsx"
grep -q "تأكيد كلمة المرور" "$APP_DIR/src/components/ReportsFilterForm.tsx"
grep -q "PERMISSION_GROUPS" "$APP_DIR/src/lib/permission-defs.ts"
grep -q "clinic-notifications-panel" "$APP_DIR/src/components/NotificationCenter.tsx"
grep -q "Bubble Gum" "$APP_DIR/src/lib/ortho/elastomeric-colors.ts"
grep -q "A bracket centre therefore sits on the wire" "$APP_DIR/src/components/ortho/InteractiveToothChart.tsx"

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
echo "== deploy 73 completed =="
echo "Database backup: $BACKUP_DIR"
