#!/bin/bash
# Clinic app — batch 29
# التحصيلات المستقلة، طلبات التحصيل، الرصيد المقدم، وحساسية اسم المستخدم للحروف.
set -euo pipefail

APP_DIR="/opt/clinic-app"
ARCHIVE="clinic-app-batch29.tar.gz"
REPO_RAW="https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main"
BACKUP_DIR="/opt/clinic-app/data.backup-batch29-$(date +%Y%m%d%H%M%S)"

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up clinic data =="
cp -a "$APP_DIR/data" "$BACKUP_DIR"
echo "Backup: $BACKUP_DIR"

echo "== downloading batch 29 =="
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

echo "== deploy 29 completed =="
echo "Important: on this first start, the app updates the invoice database schema."
echo "Your previous database is kept at: $BACKUP_DIR"
