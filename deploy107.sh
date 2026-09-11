#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/clinic-app"
SERVICE_NAME="clinic-app"
ARCHIVE="clinic-app-batch107.tar.gz"
ARCHIVE_SHA256="D299DA63567AB789460C88437E508E071459C6870B0F97D792613A552786592A"
REPO_RAW="https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-http://127.0.0.1:3000/login}"
STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_DIR="/opt/clinic-app-data.backup-batch107-$STAMP"
PREVIOUS_DIR="/opt/clinic-app.previous-batch107-$STAMP"
FAILED_DIR="/opt/clinic-app.failed-batch107-$STAMP"
TEMP_DIR="$(mktemp -d /tmp/clinic-app-batch107-deploy.XXXXXX)"
STAGE_DIR="$(mktemp -d /opt/clinic-app.release.XXXXXX)"
APP_STOPPED=0
OLD_MOVED=0
NEW_MOVED=0
DATA_MOVED=0
SUCCESS=0
FAIL_REASON=""

cleanup() {
  local status=$?
  trap - EXIT
  if (( status != 0 && SUCCESS == 0 )); then
    echo "Deploy failed; restoring the previous release." >&2
    if [[ -n "$FAIL_REASON" ]]; then
      echo "Reason: $FAIL_REASON" >&2
    fi
    if (( APP_STOPPED == 1 || NEW_MOVED == 1 )); then
      systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    if (( NEW_MOVED == 1 )) && [[ -d "$APP_DIR" ]]; then
      mv "$APP_DIR" "$FAILED_DIR" || true
    fi
    if (( DATA_MOVED == 1 )) && [[ -d "$BACKUP_DIR" ]] && [[ -d "$PREVIOUS_DIR" ]] && [[ ! -e "$PREVIOUS_DIR/data" ]]; then
      # The failed release may already have run forward-only migrations. Restore
      # the pre-deploy snapshot for the old code; keep failed/data quarantined so
      # any writes made during the health-check window can be inspected/reconciled.
      cp -a "$BACKUP_DIR" "$PREVIOUS_DIR/data" || \
        echo "CRITICAL: automatic database restore failed; data remains in $FAILED_DIR/data and $BACKUP_DIR" >&2
    fi
    if (( OLD_MOVED == 1 )) && [[ -d "$PREVIOUS_DIR" ]] && [[ ! -e "$APP_DIR" ]]; then
      mv "$PREVIOUS_DIR" "$APP_DIR" || true
    fi
    if (( APP_STOPPED == 1 || OLD_MOVED == 1 )); then
      systemctl start "$SERVICE_NAME" || true
    fi
  fi
  if [[ -d "$TEMP_DIR" && "$TEMP_DIR" == /tmp/clinic-app-batch107-deploy.* ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
  if [[ -d "$STAGE_DIR" && "$STAGE_DIR" == /opt/clinic-app.release.* ]]; then
    rm -rf -- "$STAGE_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT

fail() {
  FAIL_REASON="$1"
  echo "ERROR: $1" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "expected file is missing from the extracted archive: $1"
}

require_absent() {
  [[ ! -e "$1" ]] || fail "unexpected file/dir found in the extracted archive (should have been removed): $1"
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  fail "Run this script as root."
fi

for command in curl sha256sum tar npm node systemctl runuser; do
  command -v "$command" >/dev/null 2>&1 || fail "Missing required command: $command"
done

[[ -d "$APP_DIR/data" ]] || fail "Missing persistent data directory: $APP_DIR/data"

if [[ -f "$APP_DIR/.env.production.local" ]]; then
  ENV_FILE="$APP_DIR/.env.production.local"
  ENV_NAME=".env.production.local"
elif [[ -f "$APP_DIR/.env.production" ]]; then
  ENV_FILE="$APP_DIR/.env.production"
  ENV_NAME=".env.production"
else
  fail "Missing .env.production.local or .env.production in $APP_DIR"
fi

required_env=(
  SESSION_SECRET
  NEXT_SERVER_ACTIONS_ENCRYPTION_KEY
  WHATSAPP_APP_ID
  WHATSAPP_APP_SECRET
  WHATSAPP_CONFIG_ID
  WHATSAPP_WEBHOOK_VERIFY_TOKEN
  WHATSAPP_TOKEN_ENC_KEY
  NEXT_PUBLIC_WHATSAPP_APP_ID
  NEXT_PUBLIC_WHATSAPP_CONFIG_ID
)
for key in "${required_env[@]}"; do
  grep -Eq "^${key}=.+$" "$ENV_FILE" || fail "Missing or empty environment variable: $key in $ENV_FILE"
done

# A .env file is NOT a shell script: it never executes commands. A value written
# as $(openssl rand -hex 32) is stored as that literal 23-character string.
# On 2026-09-10 SESSION_SECRET held exactly that literal, which meant every
# session cookie was signed with a publicly documented placeholder - and the
# old "is it non-empty" check above happily passed it. Reject it explicitly.
for key in "${required_env[@]}"; do
  value="$(sed -n "s/^${key}=//p" "$ENV_FILE" | head -1)"
  case "$value" in
    *'$('*|*'`'*)
      fail "$key in $ENV_FILE contains a literal shell substitution, e.g. \$(openssl ...). A .env file does not run commands, so this is stored as plain text. Generate the value yourself (openssl rand -hex 32) and paste the result."
      ;;
  esac
done

# Length matters for signing keys, not just presence. A short SESSION_SECRET
# still boots and still serves /login (a public path that never touches the
# key) - so the health check below passes while every authenticated page 500s.
for key in SESSION_SECRET NEXT_SERVER_ACTIONS_ENCRYPTION_KEY WHATSAPP_TOKEN_ENC_KEY; do
  value="$(sed -n "s/^${key}=//p" "$ENV_FILE" | head -1)"
  if (( ${#value} < 32 )); then
    fail "$key in $ENV_FILE is only ${#value} characters; at least 32 are required. Generate one with: openssl rand -hex 32"
  fi
done

if ! command -v make >/dev/null 2>&1; then
  apt-get update
  apt-get install -y build-essential
fi

echo "== downloading release =="
curl --fail --location --output "$TEMP_DIR/$ARCHIVE" "$REPO_RAW/$ARCHIVE?cachebust=$(date +%s)" \
  || fail "Failed to download $ARCHIVE from $REPO_RAW (check the file was pushed to GitHub with that exact name)."
echo "Downloaded: $(du -h "$TEMP_DIR/$ARCHIVE" | cut -f1) -> $TEMP_DIR/$ARCHIVE"

echo "== verifying checksum =="
ACTUAL_SHA256="$(sha256sum "$TEMP_DIR/$ARCHIVE" | awk '{print toupper($1)}')"
EXPECTED_SHA256="$(echo "$ARCHIVE_SHA256" | tr '[:lower:]' '[:upper:]')"
echo "Expected: $EXPECTED_SHA256"
echo "Actual:   $ACTUAL_SHA256"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  fail "SHA256 mismatch on $ARCHIVE. The file on GitHub does not match the expected release (re-upload it, or this deploy script is out of date)."
fi
echo "Checksum OK."

echo "== checking archive paths are safe =="
if tar -tzf "$TEMP_DIR/$ARCHIVE" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  fail "Archive contains an unsafe path (absolute path or ../ traversal)."
fi

echo "== extracting and checking expected files =="
tar -xzf "$TEMP_DIR/$ARCHIVE" -C "$STAGE_DIR" || fail "Failed to extract $ARCHIVE (corrupt archive?)."
echo "Extracted archive top-level entries:"
ls -A "$STAGE_DIR" | sed 's/^/  /'

require_file "$STAGE_DIR/package-lock.json"
require_file "$STAGE_DIR/src/app/api/patient-files/upload/route.ts"
require_file "$STAGE_DIR/src/lib/patient-file-upload.ts"
require_file "$STAGE_DIR/src/components/AddImageGroupForm.tsx"
require_file "$STAGE_DIR/src/components/ortho/OrthoAddImageGroupForm.tsx"
require_absent "$STAGE_DIR/src/lib/image-compress.ts"
require_file "$STAGE_DIR/src/app/api/hr-documents/upload/route.ts"
require_file "$STAGE_DIR/src/app/hr/page.tsx"
require_file "$STAGE_DIR/src/app/hr/actions.ts"
require_file "$STAGE_DIR/src/components/HrWorkspace.tsx"
require_file "$STAGE_DIR/src/components/HrDocumentUploader.tsx"
require_file "$STAGE_DIR/src/components/HrPayrollTable.tsx"
require_file "$STAGE_DIR/src/lib/hr-payroll.ts"
require_file "$STAGE_DIR/src/lib/hr-payroll-math.ts"
require_file "$STAGE_DIR/src/components/AttendanceQueue.tsx"
require_file "$STAGE_DIR/src/components/ChatSoundPicker.tsx"
require_file "$STAGE_DIR/src/components/WhatsAppTomorrowSender.tsx"
require_file "$STAGE_DIR/src/components/WhatsAppAutomationRules.tsx"
require_file "$STAGE_DIR/src/components/PatientReviewForm.tsx"
require_file "$STAGE_DIR/src/components/PatientReviewReport.tsx"
require_file "$STAGE_DIR/src/components/WhatsAppManualTemplates.tsx"
require_file "$STAGE_DIR/src/components/WhatsAppOperationalReports.tsx"
require_file "$STAGE_DIR/src/components/BrowserNotificationPrompt.tsx"
require_file "$STAGE_DIR/src/lib/patient-review.ts"
require_file "$STAGE_DIR/src/lib/whatsapp/client-url.ts"
require_file "$STAGE_DIR/src/app/appointment/manage/[token]/page.tsx"
require_file "$STAGE_DIR/src/app/appointment-reminders/report-actions.ts"
require_file "$STAGE_DIR/src/app/whatsapp/automation-actions.ts"
require_file "$STAGE_DIR/src/app/review/[token]/page.tsx"
require_file "$STAGE_DIR/src/app/api/whatsapp/webhook/route.ts"
require_file "$STAGE_DIR/src/instrumentation.ts"
require_file "$STAGE_DIR/public/premier-whatsapp-logo.png"
require_file "$STAGE_DIR/src/components/ClearExpensesDataButton.tsx"
require_absent "$STAGE_DIR/src/lib/doctor-payroll.ts"
# Batch 92: reverted the doctor-active/user-account coupling from batch91 (not
# wanted), and hardened "stop rule"/"delete rule" to call the server action
# directly (useTransition) instead of relying on formAction inside a shared
# <form> with other required fields. Confirm both landed in this archive.
if grep -q "endHrDoctorAction" "$STAGE_DIR/src/app/hr/actions.ts" "$STAGE_DIR/src/components/HrWorkspace.tsx" 2>/dev/null; then
  fail "endHrDoctorAction is still present — the batch91 revert did not make it into this archive."
fi
# Batch 92 fix: the stop/delete rule buttons must call the server action
# DIRECTLY (via startTransition), never through formAction inside a shared
# <form> that has other required fields - that is what made them fail silently.
# Checked by intent, not by an exact string, so reformatting the call does not
# break the check while a real regression still does.
if ! grep -q "startTransition" "$STAGE_DIR/src/components/HrWorkspace.tsx" \
  || ! grep -q "await stopHrCompensationRuleAction" "$STAGE_DIR/src/components/HrWorkspace.tsx"; then
  fail "the direct-call fix for stopHrCompensationRuleAction is missing from src/components/HrWorkspace.tsx - batch92 fix did not make it into this archive."
fi
if grep -q "formAction={stopHrCompensationRuleAction\|formAction={deleteHrCompensationRuleAction" "$STAGE_DIR/src/components/HrWorkspace.tsx"; then
  fail "the stop/delete rule buttons went back to formAction inside a <form> - that is the batch91/92 silent-failure bug."
fi
# Batch 93: the per-user Revere/Medical chooser must be present across the
# account menu, server action, schema migration and theme CSS.
if ! grep -q "ألوان النظام" "$STAGE_DIR/src/components/AccountMenu.tsx"; then
  fail "Batch 93 system-color submenu is missing from AccountMenu.tsx."
fi
if ! grep -q "setColorThemeAction" "$STAGE_DIR/src/app/account/actions.ts"; then
  fail "Batch 93 color-theme server action is missing."
fi
if ! grep -q "color_theme TEXT NOT NULL DEFAULT 'revere'" "$STAGE_DIR/src/lib/db/schema.sql"; then
  fail "Batch 93 color_theme database column is missing."
fi
if ! grep -q 'body\[data-color-theme="medical"\]' "$STAGE_DIR/src/app/globals.css"; then
  fail "Batch 93 Medical palette CSS is missing."
fi
# Batch 103 (security batch): every item below must actually be in the archive.
# A failure here means the archive was built from older code - the worst
# outcome would be deploying a half-applied security batch and assuming it landed.
# NOTE: the default password stays "123" on purpose (explicit client request).
# What changed: an account still on it is prompted to change it at every login,
# skippable until DEFAULT_PASSWORD_DEADLINE, mandatory after that date.
if ! grep -q 'DEFAULT_PASSWORD = "123"' "$STAGE_DIR/src/lib/auth.ts"; then
  fail "Batch 103: DEFAULT_PASSWORD constant is missing from src/lib/auth.ts (the change-password flow is not in this archive)."
fi
require_file "$STAGE_DIR/src/app/change-password/page.tsx"
require_file "$STAGE_DIR/src/app/change-password/actions.ts"
require_file "$STAGE_DIR/src/app/change-password/ChangePasswordForm.tsx"
require_file "$STAGE_DIR/src/lib/login-attempts.ts"
require_file "$STAGE_DIR/scripts/backup.sh"
if ! grep -q "DEFAULT_PASSWORD_DEADLINE = \"2026-10-01\"" "$STAGE_DIR/src/lib/auth.ts"; then
  fail "Batch 103: DEFAULT_PASSWORD_DEADLINE is missing from src/lib/auth.ts."
fi
if ! grep -q "must_change_password INTEGER NOT NULL DEFAULT 1" "$STAGE_DIR/src/lib/db/client.ts"; then
  fail "Batch 103: the must_change_password column migration is missing from src/lib/db/client.ts."
fi
if ! grep -q "getSessionSecret" "$STAGE_DIR/src/lib/auth.ts"; then
  fail "Batch 103: the SESSION_SECRET check is missing from src/lib/auth.ts."
fi
# الأكشنات اللي كانت من غير أي فحص صلاحية لازم تبقى محروسة دلوقتي.
for guarded in saveSettingsAction addServiceAction updateServiceAction; do
  if ! grep -A 8 "^export async function ${guarded}(" "$STAGE_DIR/src/app/settings/actions.ts" \
      | grep -q 'session.role !== "admin"'; then
    fail "Batch 103: ${guarded} still has no admin check in src/app/settings/actions.ts."
  fi
done
if ! grep -q 'segments\[0\] === "hr-documents"' "$STAGE_DIR/src/app/patient-files/[...path]/route.ts"; then
  fail "Batch 103: the HR-document read guard is missing from the patient-files route."
fi
if ! grep -q "must_change_password" "$STAGE_DIR/src/lib/session.ts"; then
  fail "Batch 103: the per-request user re-check is missing from src/lib/session.ts."
fi
# Dead code removed in batch 94 must stay removed.
require_absent "$STAGE_DIR/src/components/prototype"
require_absent "$STAGE_DIR/src/lib/prototype"
require_absent "$STAGE_DIR/src/app/prototype"
require_absent "$STAGE_DIR/src/components/HrRulesManager.tsx"
require_absent "$STAGE_DIR/src/components/ToothPicker.tsx"
# Batch 103: audit-log coverage for the destructive/sensitive actions.
for pair in \
  "src/app/hr/actions.ts:save_compensation_rule" \
  "src/app/hr/actions.ts:delete_compensation_rule" \
  "src/app/hr/actions.ts:end_employment" \
  "src/app/expenses/actions.ts:delete_expense" \
  "src/app/settings/actions.ts:deactivate_user" \
  "src/app/patients/[id]/actions.ts:delete_visit" ; do
  file="${pair%%:*}"
  event="${pair##*:}"
  grep -q "$event" "$STAGE_DIR/$file" || fail "Batch 103: audit event '$event' is missing from $file."
done
grep -q "logAdminEvent" "$STAGE_DIR/src/lib/audit.ts" || fail "Batch 103: logAdminEvent helper is missing from src/lib/audit.ts."
grep -q "CLINIC_BACKUP_UPLOADS" "$STAGE_DIR/scripts/backup.sh" || fail "Batch 103: the database-only backup switch is missing from scripts/backup.sh."

# Batch 103 (was 96 for HR/expenses): every form screen must tell the user why
# an action did nothing. The rule: the ONLY bare `return;` allowed in these
# action files is a permission guard - and the page already blocks those users
# anyway, so a real user never sees it. Any other silent exit is a bug.
for helper in "src/app/hr/actions.ts:hrError" "src/app/expenses/actions.ts:expenseError" \
              "src/app/settings/actions.ts:settingsError" "src/app/inventory/actions.ts:inventoryError"; do
  file="${helper%%:*}"
  name="${helper##*:}"
  grep -q "function $name" "$STAGE_DIR/$file" || fail "Batch 103: the $name helper is missing from $file."
done
for pair in "src/app/hr/page.tsx:HR_ERRORS" "src/app/expenses/page.tsx:EXPENSE_ERRORS" \
            "src/app/settings/page.tsx:SETTINGS_ERRORS" "src/app/inventory/page.tsx:INVENTORY_ERRORS"; do
  file="${pair%%:*}"
  name="${pair##*:}"
  grep -q "$name" "$STAGE_DIR/$file" || fail "Batch 103: the $name message map is missing from $file."
done
GUARD_RE='(canManageHr|canManageExpenses|require[A-Z][A-Za-z]*\(\)|session\.role !== "admin"|!session)[^;]*\) return;[[:space:]]*$'
for target in src/app/hr/actions.ts src/app/expenses/actions.ts src/app/settings/actions.ts src/app/inventory/actions.ts; do
  leftover="$(grep -cE '\) return;[[:space:]]*$' "$STAGE_DIR/$target" || true)"
  guards="$(grep -cE "$GUARD_RE" "$STAGE_DIR/$target" || true)"
  if (( leftover != guards )); then
    fail "Batch 103: $target still has $(( leftover - guards )) silent return(s) that give the user no message."
  fi
done

# Batch 103: reports screen reorganised into three tabs, system log report added,
# and the six missing audit events covered - patient deletion above all.
require_file "$STAGE_DIR/src/components/SystemLogReport.tsx"
require_file "$STAGE_DIR/src/app/reports/system-log-actions.ts"
grep -q "view_system_log" "$STAGE_DIR/src/lib/permission-defs.ts" || fail "Batch 103: the view_system_log permission is missing from permission-defs.ts."
grep -q "renderReportTabs" "$STAGE_DIR/src/app/reports/page.tsx" || fail "Batch 103: the reports tab layout is missing from src/app/reports/page.tsx."
grep -q 'only={\["unpaid"\]}' "$STAGE_DIR/src/app/reports/page.tsx" || fail "Batch 103: the unpaid report did not move to the financial tab."
# The audit section must be GONE from the invoices screen - it lives in the
# system-log tab now, with a full date range instead of a single day.
# Checked on the QUERY, not on a heading string: a comment mentioning the old
# report would false-positive, and a renamed heading would false-negative.
# If the invoices page no longer reads audit_log, the section is really gone.
if grep -q "audit_log" "$STAGE_DIR/src/app/invoices/page.tsx"; then
  fail "Batch 103: the invoices screen still queries audit_log; the section should have moved to the reports system tab."
fi
# Patient deletion wipes the patient, visits, invoices and image files forever.
# It MUST be recorded, with the details captured BEFORE the delete transaction.
grep -q "delete_patient" "$STAGE_DIR/src/app/patients/actions.ts" || fail "Batch 103: patient deletion is still not recorded in the audit log."
if ! awk '/const patientRow = await db/{before=NR} /deleteFrom\("patients"\)/{if(!before||NR<before) exit 1} END{exit !before}' \
    "$STAGE_DIR/src/app/patients/actions.ts"; then
  fail "Batch 103: the patient details must be read BEFORE the delete transaction - after it there is nothing left to read."
fi
for pair in "src/app/patients/[id]/actions.ts:update_patient" \
            "src/app/appointments/actions.ts:appointment_status" \
            "src/app/settings/actions.ts:create_user"; do
  file="${pair%%:*}"
  event="${pair##*:}"
  grep -q "$event" "$STAGE_DIR/$file" || fail "Batch 103: audit event '$event' is missing from $file."
done

# --------------------------------------------------------------------------
# Batch 103: the fix for the crash batch 98 shipped, plus the check that stops
# that whole class of bug from ever reaching the clinic again.
#
# What went wrong: a "use server" file may only export async functions. Batch 98
# exported a plain object (EVENT_LABELS) from src/app/reports/system-log-actions.ts.
# `next build` accepted it, every check passed, and /reports then died in the
# browser with:
#     Error: A "use server" file can only export async functions, found object.
# So the build is NOT evidence that the page works. This check is.
# --------------------------------------------------------------------------
require_file "$STAGE_DIR/src/lib/system-log-labels.ts"
require_file "$STAGE_DIR/scripts/check-use-server.mjs"

# The labels must be imported from the plain module, not from the actions file.
grep -q 'from "@/lib/system-log-labels"' "$STAGE_DIR/src/components/SystemLogReport.tsx" \
  || fail "Batch 103: SystemLogReport.tsx does not import the labels from @/lib/system-log-labels - the crash fix is not in this archive."
if grep -qE '^export (const|let|var|default|function) ' "$STAGE_DIR/src/app/reports/system-log-actions.ts"; then
  fail "Batch 103: system-log-actions.ts still has a non-async export - this is exactly what crashed /reports in batch 98."
fi

# The same rule, enforced across EVERY "use server" file in the archive, not
# just the one that happened to break. Runs on the staged source before the
# build, so a bad archive is rejected before the app is ever stopped.
echo "== checking every \"use server\" file exports async functions only =="
node "$STAGE_DIR/scripts/check-use-server.mjs" "$STAGE_DIR/src" \
  || fail "Batch 103: a \"use server\" file exports something other than an async function. It would build fine and then crash the page in the browser. Deploy stopped."

# --------------------------------------------------------------------------
# Batch 103: patient duration-in-clinic report (attended_at -> completed_at),
# new tab in "تقارير المرضى", with a per-doctor average and an explicit count
# of appointments missing attended_at (some "done" appointments never pass
# through "attended", so a duration can't be computed for them).
# --------------------------------------------------------------------------
require_file "$STAGE_DIR/src/app/reports/patient-duration-actions.ts"
require_file "$STAGE_DIR/src/components/PatientDurationReport.tsx"
grep -q "view_patient_duration_report" "$STAGE_DIR/src/lib/permission-defs.ts" \
  || fail "Batch 103: the view_patient_duration_report permission is missing from permission-defs.ts."
grep -q "PatientDurationReport" "$STAGE_DIR/src/app/reports/page.tsx" \
  || fail "Batch 103: the patient duration report is not wired into src/app/reports/page.tsx."
grep -q "missingAttendedAt" "$STAGE_DIR/src/app/reports/patient-duration-actions.ts" \
  || fail "Batch 103: the missing-attended_at count is missing from patient-duration-actions.ts - averages would look precise when part of the data can't be measured."
# Same class of bug as batch 98 - this file is "use server" too, so it must
# export only async functions. The static check below already covers this
# file as part of the whole src tree, but a direct check here fails fast
# with a message that points straight at the file.
if grep -qE '^export (const|let|var|default|function) ' "$STAGE_DIR/src/app/reports/patient-duration-actions.ts"; then
  fail "Batch 103: patient-duration-actions.ts has a non-async export - this is the same mistake that crashed /reports in batch 98."
fi

# Patient-name / file-number search on the duration report, added after the
# first cut of batch 101 shipped without it.
grep -q "patientQuery" "$STAGE_DIR/src/app/reports/patient-duration-actions.ts" \
  || fail "Batch 103: the patient name/file-number search filter is missing from patient-duration-actions.ts."
grep -q "patientQuery" "$STAGE_DIR/src/components/PatientDurationReport.tsx" \
  || fail "Batch 103: the patient search input is missing from PatientDurationReport.tsx."

# The ortho/referrals operational-report panel in the patients tab now opens
# expanded by default (it's already one click deep inside that tab, so a
# second collapsed layer on top was redundant).
grep -q "defaultOpen" "$STAGE_DIR/src/components/WhatsAppOperationalReports.tsx" \
  || fail "Batch 103: the defaultOpen prop is missing from WhatsAppOperationalReports.tsx."
if ! grep -q 'only={\["ortho", "referrals"\]} defaultOpen' "$STAGE_DIR/src/app/reports/page.tsx"; then
  fail "Batch 103: the patients-tab operational reports panel is not set to open by default in src/app/reports/page.tsx."
fi

# Renamed panel titles: the generic "التقارير التشغيلية عند الطلب" heading is
# gone from both places it used to say it - the financial tab now names the
# single report it holds, and the patients tab names what it actually shows.
grep -q "title?: string" "$STAGE_DIR/src/components/WhatsAppOperationalReports.tsx" \
  || fail "Batch 103: the title prop is missing from WhatsAppOperationalReports.tsx."
grep -q 'only={\["unpaid"\]} title="تم بدون دفع"' "$STAGE_DIR/src/app/reports/page.tsx" \
  || fail "Batch 103: the financial-tab panel is not titled 'تم بدون دفع' in src/app/reports/page.tsx."
grep -q 'title="تقرير المتابعات والتحويلات"' "$STAGE_DIR/src/app/reports/page.tsx" \
  || fail "Batch 103: the patients-tab panel is not titled 'تقرير المتابعات والتحويلات' in src/app/reports/page.tsx."

# --------------------------------------------------------------------------
# Batch 103: patient-name autocomplete on the duration report (type-to-search
# against the real patient list, same pattern as the central schedule's
# booking box - was a plain unconnected text box before), plus a real data
# bug found while testing it: the everyday payment-collection path marked an
# appointment "done" without recording completed_at, so most real completed
# visits could never show a duration at all.
# --------------------------------------------------------------------------
grep -q "getPatientDurationPatientsAction" "$STAGE_DIR/src/app/reports/patient-duration-actions.ts" \
  || fail "Batch 103: getPatientDurationPatientsAction is missing from patient-duration-actions.ts - the autocomplete has nothing to search."
grep -q "getPatientDurationPatientsAction" "$STAGE_DIR/src/components/PatientDurationReport.tsx" \
  || fail "Batch 103: PatientDurationReport.tsx does not load the patient list - the autocomplete dropdown was not wired in."
grep -q "patientSuggestions" "$STAGE_DIR/src/components/PatientDurationReport.tsx" \
  || fail "Batch 103: the autocomplete suggestions dropdown is missing from PatientDurationReport.tsx."
grep -q "isNewlyDone" "$STAGE_DIR/src/app/appointments/billing-actions.ts" \
  || fail "Batch 103: the completed_at fix on the payment-collection path is missing from billing-actions.ts."

# Real bug found live while testing this same report: "كل الفترة" used
# `new Date().toISOString()` for "today", which is UTC - the server is in
# Germany, the clinic is in Cairo (UTC+2/+3). From midnight to ~2-3am Cairo
# time, UTC is still "yesterday", so the report silently excluded that day's
# just-completed appointments. This is the exact same bug class already
# fixed once before (batch 28, see src/lib/clinic-date.ts) - reintroduced
# here by writing a fresh date computation instead of reusing that fix.
grep -q "CLINIC_TIMEZONE" "$STAGE_DIR/src/components/PatientDurationReport.tsx" \
  || fail "Batch 103: PatientDurationReport.tsx computes 'today' without the clinic timezone - this is the batch-28 UTC-vs-Cairo bug again."
# Checked on lines that aren't comments - the fix's own explanatory comment
# names toISOString() by way of describing the bug it replaces, which would
# false-positive a plain text search.
if grep -vE '^\s*//' "$STAGE_DIR/src/components/PatientDurationReport.tsx" | grep -q "toISOString"; then
  fail "Batch 103: PatientDurationReport.tsx still uses toISOString() for a date - that reads UTC, not clinic-local time."
fi

# --------------------------------------------------------------------------
# Batch 103: migrations ledger. Every startup migration before this batch
# (100+ tryAddColumn calls, several guarded table rebuilds) is left exactly
# as-is - each is already self-guarding (swallows "duplicate column", or
# checks sqlite_master before rebuilding), so nothing about them was actually
# unsafe to leave alone, and rewriting 100+ working migrations for a cosmetic
# win was not worth the risk. What was missing was a queryable record of what
# ran and when. schema_migrations + runMigration() fix that going forward:
# any future migration gets a unique name logged with a timestamp, checkable
# on the server with a plain SELECT instead of reading source code.
# --------------------------------------------------------------------------
grep -q "CREATE TABLE IF NOT EXISTS schema_migrations" "$STAGE_DIR/src/lib/db/client.ts" \
  || fail "Batch 103: the schema_migrations ledger table is missing from client.ts."
grep -q "function runMigration" "$STAGE_DIR/src/lib/db/client.ts" \
  || fail "Batch 103: the runMigration() helper is missing from client.ts."
grep -q "103_migrations_ledger_introduced" "$STAGE_DIR/src/lib/db/client.ts" \
  || fail "Batch 103: the migrations-ledger's own first entry is missing - runMigration() would ship unused."

# Batch 104 security hardening (password policy intentionally unchanged until
# the already-scheduled 2026-10-01 deadline).
require_file "$STAGE_DIR/src/lib/limited-upload.ts"
require_file "$STAGE_DIR/src/lib/money.ts"
require_file "$STAGE_DIR/src/lib/safe-redirect.ts"
require_file "$STAGE_DIR/tests/security/security-regressions.test.ts"
grep -q '"next": "16.3.4"' "$STAGE_DIR/package.json" \
  || fail "Batch 104: patched Next.js version is missing."
grep -q "ByteLimitTransform" "$STAGE_DIR/src/app/api/patient-files/upload/route.ts" \
  || fail "Batch 104: patient upload stream limit is missing."
grep -q "ByteLimitTransform" "$STAGE_DIR/src/app/api/hr-documents/upload/route.ts" \
  || fail "Batch 104: HR upload stream limit is missing."
grep -q "session_version" "$STAGE_DIR/src/lib/session.ts" \
  || fail "Batch 104: session revocation check is missing."
grep -q "104_invoice_integrity_guards" "$STAGE_DIR/src/lib/db/client.ts" \
  || fail "Batch 104: invoice database guards are missing."
grep -q "db.transaction().execute" "$STAGE_DIR/src/app/appointments/billing-actions.ts" \
  || fail "Batch 104: atomic appointment billing transaction is missing."
grep -q 'BACKUP_UPLOADS="${CLINIC_BACKUP_UPLOADS:-1}"' "$STAGE_DIR/scripts/backup.sh" \
  || fail "Batch 104: off-server upload backup is not enabled by default."
grep -q 'rclone copy "$UPLOADS_DIR"' "$STAGE_DIR/scripts/backup.sh" \
  || fail "Batch 104: uploads must use backup copy semantics, not destructive sync."

# --------------------------------------------------------------------------
# Batch 105: legacy visits/financials import (data up to 2026-09-08).
# Adds an internal import_external_refs ledger (no visible screen, no effect
# on existing data — see docs/batch105-import.md) plus a standalone,
# idempotent import script that is run manually AFTER this deploy, never
# automatically with --apply. The deploy only verifies the code landed and,
# once the app is healthy, runs the script in --report mode (read-only) so
# the operator sees the matching results immediately.
# --------------------------------------------------------------------------
require_file "$STAGE_DIR/scripts/import-legacy-visits.mjs"
require_file "$STAGE_DIR/scripts/rollback-legacy-visits.mjs"
require_file "$STAGE_DIR/docs/batch105-import.md"
grep -q "105_legacy_import_refs" "$STAGE_DIR/src/lib/db/client.ts" \
  || fail "Batch 105: the import_external_refs migration is missing from client.ts."
grep -q "CREATE TABLE IF NOT EXISTS import_external_refs" "$STAGE_DIR/src/lib/db/client.ts" \
  || fail "Batch 105: the import_external_refs table definition is missing from client.ts."
# The import script must never write without an explicit --apply flag, and
# must never invent a service/doctor/room match — both checked by intent
# (the exact guard names), not by a brittle full-text match.
grep -q '"--apply"' "$STAGE_DIR/scripts/import-legacy-visits.mjs" \
  || fail "Batch 105: import-legacy-visits.mjs has no --apply gate — it must default to a read-only report."
grep -q "unresolvedServices" "$STAGE_DIR/scripts/import-legacy-visits.mjs" \
  || fail "Batch 105: import-legacy-visits.mjs does not report unresolved services — it could silently skip or guess them."
node --check "$STAGE_DIR/scripts/import-legacy-visits.mjs" \
  || fail "Batch 105: scripts/import-legacy-visits.mjs has a syntax error."
node --check "$STAGE_DIR/scripts/rollback-legacy-visits.mjs" \
  || fail "Batch 105: scripts/rollback-legacy-visits.mjs has a syntax error."

# --------------------------------------------------------------------------
# Batch 107: edit-billing-entry, patients pagination/sort/live search, whole-
# table booking search, calendar click-area fix, low-stock-alert permission,
# suppliers under expenses, expenses summary boxes, financial reports split.
# --------------------------------------------------------------------------

# 1) Edit button on patient billing rows.
require_file "$STAGE_DIR/src/components/EditInvoiceButton.tsx"
grep -q "edit_patient_billing_entry" "$STAGE_DIR/src/lib/permission-defs.ts" \
  || fail "Batch 107: the edit_patient_billing_entry permission is missing from permission-defs.ts."
grep -q "editPatientBillingEntryAction" "$STAGE_DIR/src/app/patients/[id]/billing/actions.ts" \
  || fail "Batch 107: editPatientBillingEntryAction is missing from patients/[id]/billing/actions.ts."
grep -q "edit_billing_entry" "$STAGE_DIR/src/app/patients/[id]/billing/actions.ts" \
  || fail "Batch 107: the edit_billing_entry audit event is missing from patients/[id]/billing/actions.ts."
grep -q "EditInvoiceButton" "$STAGE_DIR/src/app/patients/[id]/billing/page.tsx" \
  || fail "Batch 107: EditInvoiceButton is not wired into patients/[id]/billing/page.tsx."

# 2) Patients list: pagination (100/page), sorting, live search.
require_file "$STAGE_DIR/src/components/PatientsSearchBar.tsx"
grep -q "PAGE_SIZE = 100" "$STAGE_DIR/src/app/patients/page.tsx" \
  || fail "Batch 107: patients page size is not 100."
grep -q "PatientsSearchBar" "$STAGE_DIR/src/app/patients/page.tsx" \
  || fail "Batch 107: the live search bar is not wired into src/app/patients/page.tsx."

# 3) Booking modal: whole-table search, no 500-row cap.
grep -q "searchPatientsForBookingAction" "$STAGE_DIR/src/app/appointments/actions.ts" \
  || fail "Batch 107: searchPatientsForBookingAction is missing from appointments/actions.ts."
grep -q "searchPatientsForBookingAction" "$STAGE_DIR/src/components/CentralSchedule.tsx" \
  || fail "Batch 107: CentralSchedule.tsx does not call searchPatientsForBookingAction - the booking search is still capped."

# 4) Calendar cell click-area fix: patient-name link must not stretch full width.
grep -q "inline-block" "$STAGE_DIR/src/components/CentralSchedule.tsx" \
  || fail "Batch 107: the patient-name link click-area fix (inline-block) is missing from CentralSchedule.tsx."

# 5) Low-stock alert recipients moved to a permission.
grep -q "receive_low_stock_alerts" "$STAGE_DIR/src/lib/permission-defs.ts" \
  || fail "Batch 107: the receive_low_stock_alerts permission is missing from permission-defs.ts."
grep -q "getUsersWithPermission" "$STAGE_DIR/src/lib/permissions.ts" \
  || fail "Batch 107: getUsersWithPermission helper is missing from permissions.ts."
if grep -q "inventory_low_stock_recipient_ids" "$STAGE_DIR/src/components/InventoryCatalogManager.tsx"; then
  fail "Batch 107: InventoryCatalogManager.tsx still references the old recipient-list setting."
fi

# 6) Suppliers rebuilt as an inline "خامات" section on /expenses (batch 107
# replaces the old /expenses/suppliers sub-page from batch 106 entirely).
require_absent "$STAGE_DIR/src/app/expenses/suppliers"
require_file "$STAGE_DIR/src/components/InventorySupplierManager.tsx"
grep -q "manage_suppliers" "$STAGE_DIR/src/lib/permission-defs.ts" \
  || fail "Batch 107: the manage_suppliers permission is missing from permission-defs.ts."
grep -q "106_supplier_invoices_payments" "$STAGE_DIR/src/lib/db/client.ts" \
  || fail "Batch 107: the supplier invoices/payments migration (from batch 106) is missing from client.ts."
grep -q "107_supplier_invoice_specialty" "$STAGE_DIR/src/lib/db/client.ts" \
  || fail "Batch 107: the per-invoice specialty migration is missing from client.ts."
grep -q "CREATE TABLE IF NOT EXISTS supplier_invoices" "$STAGE_DIR/src/lib/db/client.ts" \
  || fail "Batch 107: the supplier_invoices table definition is missing from client.ts."
grep -q "CREATE TABLE IF NOT EXISTS supplier_payments" "$STAGE_DIR/src/lib/db/client.ts" \
  || fail "Batch 107: the supplier_payments table definition is missing from client.ts."
grep -q "خامات" "$STAGE_DIR/src/app/expenses/page.tsx" \
  || fail "Batch 107: the inline 'خامات' section is missing from expenses/page.tsx."
grep -q "addSupplierInvoiceAction" "$STAGE_DIR/src/app/expenses/actions.ts" \
  || fail "Batch 107: addSupplierInvoiceAction is missing from expenses/actions.ts."
grep -q "recordSupplierInvoicePaymentAction" "$STAGE_DIR/src/app/expenses/actions.ts" \
  || fail "Batch 107: recordSupplierInvoicePaymentAction is missing from expenses/actions.ts."
# The owner explicitly rejected the "general/unlinked payment" concept in
# batch 107 - every payment must be tied to one specific invoice.
if grep -q "recordSupplierGeneralPaymentAction" "$STAGE_DIR/src/app/expenses/actions.ts"; then
  fail "Batch 107: recordSupplierGeneralPaymentAction should have been removed - there is no more general/unlinked supplier payment concept."
fi
for action in editSupplierInvoiceAction deleteSupplierInvoiceAction editSupplierPaymentAction deleteSupplierPaymentAction; do
  grep -q "$action" "$STAGE_DIR/src/app/expenses/actions.ts" \
    || fail "Batch 107: $action (edit/delete for suppliers, gated by manage_suppliers) is missing from expenses/actions.ts."
done
# Every recorded supplier payment must post an expenses row under category
# "suppliers" - checked by intent (the action body references the suppliers
# expense category), not by a single string.
awk '/^export async function recordSupplierInvoicePaymentAction/{f=1} f{print} f&&/^}/{exit}' \
    "$STAGE_DIR/src/app/expenses/actions.ts" | grep -q 'category: "suppliers"' \
  || fail "Batch 107: recordSupplierInvoicePaymentAction does not record an expenses row (category suppliers) - supplier payments would be missing from expense totals."
grep -q "is_ortho" "$STAGE_DIR/src/lib/db/types.ts" || fail "Batch 107: is_ortho column missing from db types."
grep -q "is_general" "$STAGE_DIR/src/lib/db/types.ts" || fail "Batch 107: is_general column missing from db types."
grep -q "specialty" "$STAGE_DIR/src/lib/db/types.ts" \
  || fail "Batch 107: the per-invoice specialty column is missing from db types."

# 7) Expenses page: new summary boxes, old boxes removed.
if grep -q "المحصل فعليا" "$STAGE_DIR/src/app/expenses/page.tsx"; then
  fail "Batch 107: 'المحصل فعليا' box should have been removed from expenses/page.tsx (moved to Reports)."
fi
if grep -q "صافي النقدية بعد المصروفات" "$STAGE_DIR/src/app/expenses/page.tsx"; then
  fail "Batch 107: 'صافي النقدية بعد المصروفات' box should have been removed from expenses/page.tsx (moved to Reports)."
fi
for label in "موردين" "معامل" "أخرى"; do
  grep -q "$label" "$STAGE_DIR/src/app/expenses/page.tsx" \
    || fail "Batch 107: the '$label' summary box is missing from expenses/page.tsx."
done
grep -q "مديونية" "$STAGE_DIR/src/app/expenses/page.tsx" \
  || fail "Batch 107: the total-debt 'مديونية' summary box is missing from expenses/page.tsx."

# 8) Financial reports: إيرادات/مصروفات split, صافي النقدية moved up, new detail reports.
grep -q "getPayrollDetailReport" "$STAGE_DIR/src/app/reports/page.tsx" \
  || fail "Batch 107: the detailed payroll report is missing from reports/page.tsx."
grep -q "getSuppliersDetailReport" "$STAGE_DIR/src/app/reports/page.tsx" \
  || fail "Batch 107: the detailed suppliers report is missing from reports/page.tsx."
grep -q "getMiscExpensesDetailReport" "$STAGE_DIR/src/app/reports/page.tsx" \
  || fail "Batch 107: the detailed misc-expenses report is missing from reports/page.tsx."
grep -q "is_ortho" "$STAGE_DIR/src/app/reports/page.tsx" \
  || fail "Batch 107: the suppliers report is not split by is_ortho/is_general in reports/page.tsx."

# 9) Round-2 fixes: inventory settings actually moved into /inventory, and
# phone search normalizes digits instead of a raw substring match.
if grep -q "إعدادات المخزن" "$STAGE_DIR/src/app/settings/page.tsx"; then
  fail "Batch 107: 'إعدادات المخزن' is still in settings/page.tsx - it must live only on /inventory."
fi
if grep -q "InventoryCatalogManager" "$STAGE_DIR/src/app/settings/page.tsx"; then
  fail "Batch 107: settings/page.tsx still renders InventoryCatalogManager - it must move to inventory/page.tsx."
fi
grep -q "إعدادات المخزن" "$STAGE_DIR/src/app/inventory/page.tsx" \
  || fail "Batch 107: 'إعدادات المخزن' is missing from inventory/page.tsx."
grep -q "InventoryCatalogManager" "$STAGE_DIR/src/app/inventory/page.tsx" \
  || fail "Batch 107: inventory/page.tsx does not render InventoryCatalogManager."
grep -q "normalizePhoneNumber" "$STAGE_DIR/src/app/patients/page.tsx" \
  || fail "Batch 107: patients/page.tsx phone search is not digit-normalized."
grep -q "normalizePhoneNumber" "$STAGE_DIR/src/app/appointments/actions.ts" \
  || fail "Batch 107: the booking search phone match is not digit-normalized."

# Every "use server" file must still export only async functions.
node "$STAGE_DIR/scripts/check-use-server.mjs" "$STAGE_DIR/src" \
  || fail "Batch 107: a \"use server\" file exports something other than an async function."

require_absent "$STAGE_DIR/.env.production"
require_absent "$STAGE_DIR/.env.production.local"
require_absent "$STAGE_DIR/data"
echo "== installing and building in staging =="
cd "$STAGE_DIR"
BUILD_USER="${BUILD_USER:-nobody}"
id "$BUILD_USER" >/dev/null 2>&1 || fail "Unprivileged build user does not exist: $BUILD_USER"
BUILD_GROUP="$(id -gn "$BUILD_USER")"
chown -R "$BUILD_USER:$BUILD_GROUP" "$STAGE_DIR"
runuser -u "$BUILD_USER" -- env npm_config_cache="$STAGE_DIR/.npm-cache" npm ci \
  || fail "npm ci failed in staging directory."
runuser -u "$BUILD_USER" -- env npm_config_cache="$STAGE_DIR/.npm-cache" npm run test:security \
  || fail "Security regression tests failed in staging directory."
runuser -u "$BUILD_USER" -- env npm_config_cache="$STAGE_DIR/.npm-cache" npm run typecheck \
  || fail "TypeScript validation failed in staging directory."
# Dependencies and their lifecycle scripts are finished before production
# secrets enter the staging tree. The trusted application build still gets the
# same environment file it had before.
cp -a "$ENV_FILE" "$STAGE_DIR/$ENV_NAME"
chown "$BUILD_USER:$BUILD_GROUP" "$STAGE_DIR/$ENV_NAME"
runuser -u "$BUILD_USER" -- env npm_config_cache="$STAGE_DIR/.npm-cache" \
  CLINIC_DB_PATH="$STAGE_DIR/.build/clinic.db" npm run build \
  || fail "npm run build failed in staging directory."
rm -rf -- "$STAGE_DIR/.build" "$STAGE_DIR/.npm-cache"
chown -R root:root "$STAGE_DIR"
chmod 0755 "$STAGE_DIR"

echo "== stopping app and backing up persistent data =="
systemctl stop "$SERVICE_NAME"
APP_STOPPED=1
cp -a "$APP_DIR/data" "$BACKUP_DIR"

echo "== switching releases =="
mv "$APP_DIR" "$PREVIOUS_DIR"
OLD_MOVED=1
mv "$STAGE_DIR" "$APP_DIR"
NEW_MOVED=1
mv "$PREVIOUS_DIR/data" "$APP_DIR/data"
DATA_MOVED=1

systemctl start "$SERVICE_NAME"
APP_STOPPED=0

# /login is a PUBLIC path: proxy.ts lets it through without ever reading the
# session cookie or touching SESSION_SECRET. Checking only that page is how a
# broken signing key shipped as a "successful" deploy on 2026-09-10. So we also
# request a protected path and require a redirect to /login (302) - reaching
# that decision means the session layer actually ran. A 500 there means the app
# is up but every real page is broken, and that must fail the deploy.
PROTECTED_URL="${PROTECTED_URL:-http://127.0.0.1:3000/patients}"
for _ in {1..20}; do
  if systemctl is-active --quiet "$SERVICE_NAME" && curl --fail --silent --output /dev/null "$HEALTHCHECK_URL"; then
    PROTECTED_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' "$PROTECTED_URL")"
    if [[ "$PROTECTED_CODE" == "302" || "$PROTECTED_CODE" == "307" ]]; then
      SUCCESS=1
      break
    fi
  fi
  sleep 2
done

if (( SUCCESS != 1 )); then
  if [[ "${PROTECTED_CODE:-}" == "500" ]]; then
    fail "The app started and /login answers, but $PROTECTED_URL returns 500. Every authenticated page is broken - check 'journalctl -u $SERVICE_NAME -n 50' (a bad SESSION_SECRET looks exactly like this)."
  fi
  fail "Health check failed: $HEALTHCHECK_URL (protected path returned ${PROTECTED_CODE:-no response})"
fi

# Prune old copies: every deploy left a data backup AND a full previous release
# (node_modules included) on the same disk, and nothing was ever removed. After
# 90+ deploys that fills the disk - and a full disk means the service stops and
# the SQLite file risks corruption. Keep the newest 3 of each kind.
echo "== pruning old backups and releases (keeping newest 3) =="
shopt -s nullglob
for prefix in /opt/clinic-app-data.backup-batch /opt/clinic-app.previous-batch /opt/clinic-app.failed-batch; do
  # NOT `ls -t`: cp -a and mv preserve the source mtime, so a backup created
  # seconds ago can look years old and get pruned as "oldest" - which is how
  # the batch94 deploy deleted its own fresh data backup. The STAMP inside each
  # directory name is YYYYmmddHHMMSS, so sorting by NAME is the real order.
  # `|| true`: with `set -Eeuo pipefail`, a prefix that matches nothing makes
  # `ls` exit non-zero, which failed the whole pipeline and killed the script
  # at its very last step - the batch95 deploy ended without ever printing
  # "Deploy completed successfully", and exited non-zero on a good deploy.
  # That is a silent failure in the one script that must never have one.
  candidates=("$prefix"*)
  (( ${#candidates[@]} <= 3 )) && continue
  printf '%s\n' "${candidates[@]}" \
    | awk -F- '{ print $NF "\t" $0 }' \
    | sort -r \
    | tail -n +4 \
    | cut -f2- \
    | while IFS= read -r old; do
    echo "  removing: $old"
    rm -rf -- "$old"
  done || true
done

echo "Deploy completed successfully."
echo "Data backup: $BACKUP_DIR"
echo "Previous release: $PREVIOUS_DIR"
echo
echo "Batch 107 is a superset of everything since the last deploy (the batch106"
echo "you had live was the first, un-patched version). It adds/fixes:"
echo "  - edit button on patient billing rows (تعديل جنب حذف)"
echo "  - patients list: pagination (100/page), sorting, live search"
echo "  - phone search now matches digits regardless of spaces/+20/leading 0"
echo "  - whole-database booking search (the 500-row cap is gone)"
echo "  - إضافة خدمة vs. حضر/تم click-area fix on the front-desk calendar"
echo "  - receive_low_stock_alerts permission (replacing the settings recipient list)"
echo "  - إعدادات المخزن moved for real into the /inventory page (collapsible section)"
echo "  - 'خامات': supplier invoices/payments now live INLINE on the Expenses"
echo "    page (no more separate /expenses/suppliers page) - per-invoice"
echo "    specialty, always-open سداد box, red المتبقي/المديونية figures,"
echo "    edit/delete gated by the manage_suppliers permission"
echo "  - Expenses page summary boxes: موردين/معامل/أخرى + a red مديونية box"
echo "    at the end (only the first and last box are red now)"
echo "  - Financial Reports split into إيرادات/مصروفات with detailed payroll,"
echo "    suppliers (تقويم/جينيرال) and misc-expense reports"
echo
echo "Batch 105's legacy visits/financials import tooling (data up to"
echo "2026-09-08) is still present and unchanged — it still does NOTHING"
echo "automatically; run it yourself if you haven't already."
echo
echo "== النقطة المهمة: مفيش استيراد بيانات اتنفذ لسه =="
echo "الديبلوي وقف هنا عمدًا. الخطوة الجاية يدوية بالكامل، من عندك:"
echo
echo "  1) ارفع ملف الإكسل على السيرفر، مثلاً:"
echo "       $APP_DIR/data-import/legacy.xlsx"
echo
echo "  2) شغّل تقرير المطابقة (بدون أي كتابة في القاعدة):"
echo "       cd $APP_DIR"
echo "       node scripts/import-legacy-visits.mjs $APP_DIR/data-import/legacy.xlsx --report"
echo
echo "  3) راجع الملفات دي كويس قبل أي كتابة فعلية:"
echo "       import-report-batch105/report.json"
echo "       import-report-batch105/unresolved-services.json"
echo "       import-report-batch105/unlinked-transactions.json"
echo
echo "  4) التعليمات الكاملة (عينة تجريبية، الرفع الكامل، التراجع):"
echo "       cat $APP_DIR/docs/batch105-import.md"
echo
if command -v node >/dev/null 2>&1 && [[ -n "${LEGACY_XLSX_PATH:-}" ]] && [[ -f "${LEGACY_XLSX_PATH:-}" ]]; then
  echo "== LEGACY_XLSX_PATH موجود - بنشغّل تقرير المطابقة تلقائيًا (بدون أي كتابة) =="
  (cd "$APP_DIR" && node scripts/import-legacy-visits.mjs "$LEGACY_XLSX_PATH" --report) \
    || echo "تحذير: تقرير المطابقة التلقائي فشل - شغّله يدويًا بنفسك (خطوة 2 فوق)." >&2
else
  echo "(لو حابب التقرير يتشغل تلقائي آخر الديبلوي، ابعت متغير البيئة LEGACY_XLSX_PATH"
  echo " بمسار الإكسل على السيرفر قبل تشغيل السكربت ده.)"
fi
