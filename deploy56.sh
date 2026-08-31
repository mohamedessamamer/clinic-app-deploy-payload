#!/bin/bash
# Clinic app — batch 56: aligned appointment cards and unified doctor schedule workspace.
set -euo pipefail

APP_DIR="/opt/clinic-app"
ARCHIVE="clinic-app-batch56.tar.gz"
REPO_RAW="https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main"
BACKUP_DIR="/opt/clinic-app/data.backup-batch56-$(date +%Y%m%d%H%M%S)"

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

echo "== downloading batch 56 =="
cd /tmp
rm -f "$ARCHIVE"
curl --fail --location --output "$ARCHIVE" "$REPO_RAW/$ARCHIVE?cachebust=$(date +%s)"
tar -tzf "$ARCHIVE" >/dev/null

echo "== extracting source =="
tar -xzf "$ARCHIVE" -C "$APP_DIR"
echo "== checking schedule refinements =="
grep -q "reception-toolbar-actions-right" "$APP_DIR/src/app/front-desk/page.tsx"
grep -q "grid-row:1" "$APP_DIR/src/app/globals.css"
grep -q "showPatientSearch={false}" "$APP_DIR/src/app/page.tsx"

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
echo "== deploy 56 completed =="
echo "Database backup: $BACKUP_DIR"
