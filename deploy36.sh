#!/bin/bash
# Clinic app — batch 36: robust deletion, chat unread marker, and orthodontic provider sync.
set -euo pipefail

APP_DIR="/opt/clinic-app"
ARCHIVE="clinic-app-batch36.tar.gz"
REPO_RAW="https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main"
BACKUP_DIR="/opt/clinic-app/data.backup-batch36-$(date +%Y%m%d%H%M%S)"

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

echo "== downloading batch 36 =="
cd /tmp
rm -f "$ARCHIVE"
curl --fail --location --output "$ARCHIVE" "$REPO_RAW/$ARCHIVE?cachebust=$(date +%s)"
tar -tzf "$ARCHIVE" >/dev/null

echo "== extracting source =="
tar -xzf "$ARCHIVE" -C "$APP_DIR"
echo "== checking critical files =="
grep -q "notification_cases" "$APP_DIR/src/app/patients/actions.ts"
grep -q "chat_read_states" "$APP_DIR/src/lib/db/schema.sql"
grep -q "performingDoctorId" "$APP_DIR/src/lib/ortho-treatment-sync.ts"
grep -q "allowedOrthoDoctorIds" "$APP_DIR/src/app/patients/[id]/orthodontics/ortho-v2-actions.ts"

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
echo "== deploy 36 completed =="
echo "Database backup: $BACKUP_DIR"
