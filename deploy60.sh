#!/bin/bash
# Clinic app — batch 60: fixed orthodontic image strip and mobile-friendly unified navigation.
set -euo pipefail

APP_DIR="/opt/clinic-app"
ARCHIVE="clinic-app-batch60.tar.gz"
REPO_RAW="https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main"
BACKUP_DIR="/opt/clinic-app/data.backup-batch60-$(date +%Y%m%d%H%M%S)"

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

echo "== downloading batch 60 =="
cd /tmp
rm -f "$ARCHIVE"
curl --fail --location --output "$ARCHIVE" "$REPO_RAW/$ARCHIVE?cachebust=$(date +%s)"
tar -tzf "$ARCHIVE" >/dev/null

echo "== extracting source =="
tar -xzf "$ARCHIVE" -C "$APP_DIR"
echo "== checking mobile navigation and image strip =="
grep -q "clinic-mobile-account-trigger" "$APP_DIR/src/components/NavBar.tsx"
grep -q "ortho-live-photo-gallery-shell" "$APP_DIR/src/components/ortho/OrthoImageGallery.tsx"
grep -q "ortho-live-upload-tile" "$APP_DIR/src/app/globals.css"

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
echo "== deploy 60 completed =="
echo "Database backup: $BACKUP_DIR"
