#!/bin/bash
# Combined deploy script for clinic-app — batches 11 + 12 + 13 (never deployed
# to the live server before; this ships the FULL current src/ tree as one
# package, not an incremental diff, since batch 11 was also never deployed).
#
# Batch 11:
#   - "سجل الكشوفات والزيارات" renamed to "سجل الزيارات".
#   - "المعالجة" field is now a <textarea> (Enter = new line, not submit).
#   - Visits editable for 3 days after creation; edit_old_visits permission
#     after that. Invoice price auto-resyncs on service change if unpaid and
#     not manually overridden.
#
# Batch 12:
#   1. Service selection in "سجل الزيارات" is now a searchable combobox.
#   2. Admin-only "حذف الحالة" (delete patient) — cascades through visits,
#      invoices, appointments, image groups/files.
#   3. New edit_invoice_payments permission — editing a recorded invoice's
#      paid amount / price is now permission-gated (was open to anyone
#      before), logged to audit_log.
#   4. "+ مريض جديد" button on /front-desk.
#   5. Date filters on /front-desk and /invoices auto-submit on change.
#   6. New delete_visits permission (admin-only by default) — permanently
#      delete a single erroneous/duplicate visit + its invoice.
#   7. Payment method (cash/visa/instapay) now shown on /invoices and the
#      patient billing page; editable alongside amount/paid.
#   8. Week display now starts on Saturday instead of Sunday (settings page,
#      weekly shifts manager) — stored weekday numbers unchanged (0=Sunday..
#      6=Saturday), display order only.
#
# Batch 13:
#   1. Removed the standalone /appointments page entirely — it duplicated
#      the central schedule on /front-desk and, worse, let anyone revert a
#      "done" appointment's status with zero validation, breaking the
#      "done is final" rule from batch 8. Nav link and dashboard links now
#      point to /front-desk instead.
#   2. updateAppointmentStatusAction now refuses to change status on an
#      appointment that's already "done", enforced server-side (not just in
#      the central schedule's UI) regardless of caller.
#   3. The room's shift doctor is now pre-selected by default (labeled
#      "(صاحب الشيفت)") when booking from the central schedule, matching the
#      same convention already used in the front-desk daily log. Billing
#      already inherits the appointment's doctor automatically.
#   4. New view_invoice_totals permission — reception no longer sees the
#      totals cards, original price/discount/amount columns, or the
#      "تعديلات اليوم" audit section on /invoices; they still see patient,
#      service, doctor, paid, remaining, and payment method per row.
#
# Run as: bash deploy13.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch13.tar.gz
curl -L -o clinic-app-batch13.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch13.tar.gz?cachebust=$(date +%s)"

echo "== extracting update (full src/ tree — overwrites in place) =="
tar -xzf clinic-app-batch13.tar.gz -C /opt/clinic-app

echo "== removing the standalone /appointments page (deleted in this batch) =="
rm -f /opt/clinic-app/src/app/appointments/page.tsx
rm -f /opt/clinic-app/src/components/AppointmentForm.tsx
rm -f /opt/clinic-app/src/components/StatusSelect.tsx

echo "== verifying the new code actually landed on disk =="
if grep -q "view_invoice_totals" /opt/clinic-app/src/lib/permission-defs.ts && [ ! -f /opt/clinic-app/src/app/appointments/page.tsx ]; then
  echo "OK: permission-defs.ts has the new code, and the old /appointments page is gone."
else
  echo "PROBLEM: the new code did not land correctly."
  echo "GitHub may still be serving an old clinic-app-batch13.tar.gz - go re-upload it"
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
