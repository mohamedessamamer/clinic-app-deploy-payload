#!/bin/bash
# Deploy script for clinic-app — batch 14 (ships on top of batches 11+12+13,
# which are already live on the server). Ships the FULL current src/ tree as
# one package (not an incremental diff), so it's safe regardless of exactly
# which files changed since the last deploy.
#
# Batch 14:
#   1. Fixed a real double-billing bug: when a doctor (no collect_payments
#      permission) marks an appointment "تم" and only logs the expected
#      service/price ("المطلوب دفعه"), the appointment sits flagged "محتاج
#      تحصيل" in the central schedule until reception finalizes it via
#      right-click → "تسجيل التحصيل". In practice, reception often used the
#      separate "إضافة خدمة" quick-entry box on /front-desk instead (it's
#      the more familiar/visible form) — that box had zero awareness of
#      appointments, so it created a second, disconnected visit+invoice with
#      no link back to the appointment. The "محتاج تحصيل" flag never
#      cleared, so if anyone later did "تسجيل التحصيل" on the same
#      still-flagged appointment, the same service got billed a second time.
#      Fix: the "إضافة خدمة" box now auto-detects a pending appointment for
#      whichever patient is selected, shows a banner explaining it, pre-fills
#      the service/price/discount/doctor from the appointment's pending data,
#      and on submit links the new visit to that appointment (appointment_id)
#      and clears its pending_* fields — so it resolves the SAME appointment
#      instead of creating an untracked duplicate. Verified locally end to
#      end (doctor marks "تم" pending → reception picks same patient in
#      "إضافة خدمة", sees the banner, submits → exactly one visit/invoice in
#      the DB, linked to the appointment, and the "محتاج تحصيل" badge clears).
#
# Run as: bash deploy14.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch14.tar.gz
curl -L -o clinic-app-batch14.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch14.tar.gz?cachebust=$(date +%s)"

echo "== extracting update (full src/ tree — overwrites in place) =="
tar -xzf clinic-app-batch14.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "linkedAppointmentId" /opt/clinic-app/src/app/front-desk/actions.ts; then
  echo "OK: front-desk/actions.ts has the new auto-link code."
else
  echo "PROBLEM: the new code did not land correctly."
  echo "GitHub may still be serving an old clinic-app-batch14.tar.gz - go re-upload it"
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
