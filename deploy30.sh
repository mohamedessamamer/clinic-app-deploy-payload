#!/bin/bash
# Clinic app — batch 30
# إصلاح تسلسل ترقية قاعدة البيانات في batch 29.
set -euo pipefail

APP_DIR="/opt/clinic-app"
ARCHIVE="clinic-app-batch30.tar.gz"
REPO_RAW="https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main"
BACKUP_DIR="/opt/clinic-app/data.backup-batch30-$(date +%Y%m%d%H%M%S)"

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up clinic data =="
cp -a "$APP_DIR/data" "$BACKUP_DIR"
echo "Backup: $BACKUP_DIR"

echo "== downloading batch 30 =="
cd /tmp
rm -f "$ARCHIVE"
curl --fail --location --output "$ARCHIVE" "$REPO_RAW/$ARCHIVE?cachebust=$(date +%s)"

echo "== checking archive =="
tar -tzf "$ARCHIVE" >/dev/null

echo "== extracting source =="
tar -xzf "$ARCHIVE" -C "$APP_DIR"

echo "== checking critical files =="
grep -q "collection_requests" "$APP_DIR/src/lib/db/schema.sql"
grep -q "patient_credits" "$APP_DIR/src/lib/db/schema.sql"
grep -q "create_collection_requests_all_doctors" "$APP_DIR/src/lib/permission-defs.ts"
grep -q "lower(username)" "$APP_DIR/src/app/login/actions.ts"

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

echo "== deploy 30 completed =="
echo "Database backup: $BACKUP_DIR"
