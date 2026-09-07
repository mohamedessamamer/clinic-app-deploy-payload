#!/bin/bash
# Batch 11 deploy script for clinic-app
# 1) Renamed the visits-history section heading from "سجل الكشوفات والزيارات"
#    to just "سجل الزيارات" (patient medical file page).
# 2) The "المعالجة" (treatment/notes) field in "إضافة زيارة" is now a
#    <textarea> instead of a single-line <input> — Enter now creates a new
#    line instead of submitting the form. Submission only happens via the
#    "+ إضافة زيارة" button. Saved line breaks now render correctly in the
#    table too (whitespace-pre-wrap).
# 3) Visits in "سجل الزيارات" are now editable (date / service / notes) for
#    3 days after they were added — enough to fix a data-entry mistake.
#    After 3 days, editing requires the new "edit_old_visits" permission
#    (clinic manager/admin by default, grantable per-doctor from Settings,
#    same pattern as override_visit_doctor). If the edited service's invoice
#    hasn't been collected yet and its price wasn't manually overridden, the
#    invoice amount is automatically resynced to the new service's price.
# Run as: bash deploy11.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch11.tar.gz
curl -L -o clinic-app-batch11.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch11.tar.gz?cachebust=$(date +%s)"

echo "== extracting update =="
tar -xzf clinic-app-batch11.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "edit_old_visits" /opt/clinic-app/src/lib/permission-defs.ts; then
  echo "OK: permission-defs.ts has the new code."
else
  echo "PROBLEM: permission-defs.ts does NOT have the new code."
  echo "GitHub is still serving an old clinic-app-batch11.tar.gz - go re-upload it"
  echo "(overwrite, exact same filename), wait a minute, then run this again."
  systemctl start clinic-app
  exit 1
fi

echo "== clearing old build cache =="
cd /opt/clinic-app
rm -rf .next

echo "== rebuilding app (next start serves a pre-built .next - without this step the new"
echo "   source files sit on disk but next start keeps serving the OLD compiled build) =="
npm run build

echo "== starting app =="
systemctl start clinic-app

sleep 2
echo "== status =="
systemctl status clinic-app --no-pager
