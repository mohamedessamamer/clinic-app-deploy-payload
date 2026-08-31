#!/bin/bash
# Clinic app — batch 50: unified typography, patient record/financial layouts,
# compact reception controls, validation fixes, and crown-only orthodontic chart.
set -euo pipefail

APP_DIR="/opt/clinic-app"
ARCHIVE="clinic-app-batch50.tar.gz"
REPO_RAW="https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main"
BACKUP_DIR="/opt/clinic-app/data.backup-batch50-$(date +%Y%m%d%H%M%S)"

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

echo "== downloading batch 50 =="
cd /tmp
rm -f "$ARCHIVE"
curl --fail --location --output "$ARCHIVE" "$REPO_RAW/$ARCHIVE?cachebust=$(date +%s)"
tar -tzf "$ARCHIVE" >/dev/null

echo "== extracting source =="
tar -xzf "$ARCHIVE" -C "$APP_DIR"
echo "== checking batch 50 =="
grep -q "MedicalTimeline" "$APP_DIR/src/app/patients/[id]/page.tsx"
grep -q "QuickPatientSearch" "$APP_DIR/src/app/front-desk/page.tsx"
grep -q "ortho-crown" "$APP_DIR/src/components/ortho/InteractiveToothChart.tsx"
grep -q "clinic-theme-v2" "$APP_DIR/src/components/ThemeToggle.tsx"

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
echo "== deploy 50 completed =="
echo "Database backup: $BACKUP_DIR"
