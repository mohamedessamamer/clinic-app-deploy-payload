#!/bin/bash
# Clinic app — batch 31
# Full release: pending collection details, safe patient details completion,
# per-user English medical record, and one-time cleanup of test doctors.
set -euo pipefail

APP_DIR="/opt/clinic-app"
ARCHIVE="clinic-app-batch31.tar.gz"
REPO_RAW="https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main"
BACKUP_DIR="/opt/clinic-app/data.backup-batch31-$(date +%Y%m%d%H%M%S)"

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

echo "== downloading batch 31 =="
cd /tmp
rm -f "$ARCHIVE"
curl --fail --location --output "$ARCHIVE" "$REPO_RAW/$ARCHIVE?cachebust=$(date +%s)"
tar -tzf "$ARCHIVE" >/dev/null

echo "== extracting source =="
tar -xzf "$ARCHIVE" -C "$APP_DIR"

echo "== checking critical files =="
grep -q "requestedCollectionLabel" "$APP_DIR/src/components/CentralSchedule.tsx"
grep -q "medical_ui_language" "$APP_DIR/src/lib/db/schema.sql"
grep -q "missingPatientDetails" "$APP_DIR/src/lib/patient-details.ts"

echo "== removing the two agreed test doctors and their test records =="
cd "$APP_DIR"
node <<'NODE'
const Database = require("better-sqlite3");
const db = new Database("data/clinic.db");
db.pragma("foreign_keys = ON");
const doctorIds = db
  .prepare("SELECT id FROM doctors WHERE REPLACE(full_name, ' ', '') IN ('د.محمد', 'د.كريم')")
  .all()
  .map((row) => row.id);

if (doctorIds.length === 0) {
  console.log("Test doctors already absent; cleanup skipped.");
} else {
  const ids = doctorIds.map(() => "?").join(",");
  const run = (statement) => db.prepare(statement.replaceAll(":ids", ids)).run(...doctorIds);
  db.transaction(() => {
    run("DELETE FROM ortho_inventory_deductions WHERE visit_id IN (SELECT id FROM ortho_visits WHERE doctor_id IN (:ids))");
    run("DELETE FROM ortho_visits WHERE doctor_id IN (:ids)");
    run("DELETE FROM collection_requests WHERE doctor_id IN (:ids) OR appointment_id IN (SELECT id FROM appointments WHERE doctor_id IN (:ids))");
    run("DELETE FROM patient_credits WHERE appointment_id IN (SELECT id FROM appointments WHERE doctor_id IN (:ids))");
    run("UPDATE invoices SET parent_invoice_id = NULL WHERE parent_invoice_id IN (SELECT id FROM invoices WHERE doctor_id IN (:ids) OR appointment_id IN (SELECT id FROM appointments WHERE doctor_id IN (:ids)) OR visit_id IN (SELECT id FROM visits WHERE primary_doctor_id IN (:ids) OR performing_doctor_id IN (:ids)))");
    run("UPDATE appointments SET purpose_linked_invoice_id = NULL WHERE purpose_linked_invoice_id IN (SELECT id FROM invoices WHERE doctor_id IN (:ids) OR appointment_id IN (SELECT id FROM appointments WHERE doctor_id IN (:ids)) OR visit_id IN (SELECT id FROM visits WHERE primary_doctor_id IN (:ids) OR performing_doctor_id IN (:ids)))");
    run("DELETE FROM invoices WHERE doctor_id IN (:ids) OR appointment_id IN (SELECT id FROM appointments WHERE doctor_id IN (:ids)) OR visit_id IN (SELECT id FROM visits WHERE primary_doctor_id IN (:ids) OR performing_doctor_id IN (:ids))");
    run("DELETE FROM visits WHERE primary_doctor_id IN (:ids) OR performing_doctor_id IN (:ids)");
    run("DELETE FROM appointments WHERE doctor_id IN (:ids)");
    run("DELETE FROM doctor_date_shifts WHERE doctor_id IN (:ids)");
    run("DELETE FROM doctor_weekly_shifts WHERE doctor_id IN (:ids)");
    run("DELETE FROM shifts WHERE doctor_id IN (:ids)");
    run("DELETE FROM service_doctors WHERE doctor_id IN (:ids)");
    run("DELETE FROM consultant_assistants WHERE consultant_doctor_id IN (:ids) OR assistant_doctor_id IN (:ids)");
    run("DELETE FROM user_permissions WHERE user_id IN (SELECT id FROM users WHERE doctor_id IN (:ids))");
    run("UPDATE users SET doctor_id = NULL, active = 0 WHERE doctor_id IN (:ids)");
    run("DELETE FROM doctors WHERE id IN (:ids)");
  })();
  console.log(`Removed ${doctorIds.length} test doctor(s) and their related test records.`);
}
db.close();
NODE

echo "== installing dependencies and building =="
npm ci
rm -rf .next
npm run build

echo "== starting app =="
systemctl start clinic-app
sleep 2
systemctl is-active --quiet clinic-app
systemctl status clinic-app --no-pager

echo "== deploy 31 completed =="
echo "Database backup: $BACKUP_DIR"
