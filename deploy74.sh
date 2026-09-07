#!/bin/bash
# Clinic app — batch 74: doctor schedule alerts, report unlock fix, appointment completion, and orthodontic chart layout.
set -euo pipefail

APP_DIR="/opt/clinic-app"
ARCHIVE="clinic-app-batch74.tar.gz"
REPO_RAW="https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main"
BACKUP_DIR="/opt/clinic-app/data.backup-batch74-$(date +%Y%m%d%H%M%S)"

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

echo "== downloading batch 74 =="
cd /tmp
rm -f "$ARCHIVE"
curl --fail --location --output "$ARCHIVE" "$REPO_RAW/$ARCHIVE?cachebust=$(date +%s)"
tar -tzf "$ARCHIVE" >/dev/null

echo "== extracting source =="
tar -xzf "$ARCHIVE" -C "$APP_DIR"
echo "== checking batch 74 files =="
test -f "$APP_DIR/src/lib/appointment-purpose.ts"
grep -q "mark_appointment_done" "$APP_DIR/src/lib/permission-defs.ts"
grep -q "isHttpsRequest" "$APP_DIR/src/app/reports/actions.ts"
grep -q "schedule-appointment-cell--done" "$APP_DIR/src/app/globals.css"
grep -q "ortho-chart-section-header" "$APP_DIR/src/components/ortho/OrthoChartV2.tsx"
grep -q "isOrthodonticAppointmentPurpose" "$APP_DIR/src/components/CentralSchedule.tsx"

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
echo "== deploy 74 completed =="
echo "Database backup: $BACKUP_DIR"
