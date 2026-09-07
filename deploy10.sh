#!/bin/bash
# Batch 10 deploy script for clinic-app
# 1) New "محتاج صور جديدة" reminder: any patient with a follow-up ("متابعة") visit
#    who has no photo/x-ray group (or none in the last 6 months) now gets a note -
#    a badge next to their name in the central schedule (front-desk and doctor home
#    both), plus a banner at the top of their medical file - even if the follow-up
#    was logged by reception, not a doctor.
# 2) "حجز الموعد القادم" moved out of the patient's medical file entirely. It now
#    appears inside the real billing box in the schedule (reception marking "تم",
#    after picking the service/payment) as an OPTIONAL date/time/duration box, same
#    room+doctor as the current appointment. The time dropdown only shows slots
#    that are actually free for the date picked. Submitting books it immediately.
# 3) Doctor selection in a patient's "سجل الكشوفات والزيارات" (manual visit log) is
#    now permission-based (new "override_visit_doctor" permission, settings page).
#    Default: a doctor's own name is used automatically, no picker at all. With the
#    new permission (clinic manager/admin by default, grantable per-doctor), an
#    extra optional "مقدم الخدمة الفعلي" field appears to log a different provider
#    (e.g. an assistant) WITHOUT changing who gets financial credit for the visit.
# Run as: bash deploy10.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch10.tar.gz
curl -L -o clinic-app-batch10.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch10.tar.gz?cachebust=$(date +%s)"

echo "== extracting update =="
tar -xzf clinic-app-batch10.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "override_visit_doctor" /opt/clinic-app/src/lib/permission-defs.ts; then
  echo "OK: permission-defs.ts has the new code."
else
  echo "PROBLEM: permission-defs.ts does NOT have the new code."
  echo "GitHub is still serving an old clinic-app-batch10.tar.gz - go re-upload it"
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
