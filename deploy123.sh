#!/usr/bin/env bash
set -Eeuo pipefail
cd /

APP_DIR="/opt/clinic-app"
SERVICE_NAME="clinic-app"
ARCHIVE="clinic-app-batch123.tar.gz"
ARCHIVE_SHA256="3FAB85AE6D28C4599E2947AAA714B5A355991FE7CACD0FF3B7E1FE64CC28FD5E"
REPO_RAW="https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-http://127.0.0.1:3000/login}"
STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_DIR="/opt/clinic-app-data.backup-batch123-$STAMP"
PREVIOUS_DIR="/opt/clinic-app.previous-batch123-$STAMP"
FAILED_DIR="/opt/clinic-app.failed-batch123-$STAMP"
TEMP_DIR="$(mktemp -d /tmp/clinic-app-batch123-deploy.XXXXXX)"
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
  if [[ -d "$TEMP_DIR" && "$TEMP_DIR" == /tmp/clinic-app-batch123-deploy.* ]]; then
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

# Batch 123 replaces the full source tree. The server is already on Batch 122,
# so reject any hotfix made to files this batch updates.
echo "== checking live batch-122 source before replacement =="
while read -r expected relative; do
  live_file="$APP_DIR/$relative"
  [[ -f "$live_file" ]] || fail "Live source file is missing: $live_file"
  actual="$(sha256sum "$live_file" | awk '{print tolower($1)}')"
  if [[ "$actual" != "$expected" ]]; then
    fail "Live source differs from batch 122: $relative. Merge the server-side change (or deploy batch 122 first) before deploying batch 123."
  fi
done <<'BATCH122_BASELINE_HASHES'
ea929990fd92bc762a8da05130b139c6f53219502e03f66eb986d06ed6396a61 src/app/appointments/actions.ts
e173ed2e3e0ae67a91f064d39f9dc5d929f1968a3b9bd1dd4d239bd72598c5a3 src/app/front-desk/page.tsx
f57cce0a498107189c4e682e07f18bac26154ef6c26627d42504db62fdee9b16 src/app/globals.css
a30420b93e0ab2990016c8bcaf144dfbf51db00b22c1d6d9ffa99097a0b1c8dd src/app/page.tsx
d34deae953d05200dbaf27d50e0b368d1086c9dc8c9c68061ebb384c96ac3437 src/components/CentralSchedule.tsx
8e959717940c823f1c1f9b0837c1a52c384aa9b89590792a16b5ef9d1ed97ab3 src/lib/db/client.ts
15e33b251dad059ac0952ac0b5b3a5abaa1699258673f7f3b3f26cbc940892a9 src/lib/db/schema.sql
f42c90cee6e74ebe5a17d6848e30c80c01a8fe446012002ed72d9277a561fe8b src/lib/db/types.ts
BATCH122_BASELINE_HASHES
require_file "$APP_DIR/src/components/ReportSubnav.tsx"

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
# Superseded by batch 109: view_patient_duration_report was consolidated into
# view_patient_reports (checked in the batch 109 section further down) -
# no longer required to exist as its own key.
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

# The patient reports navigation was redesigned in Batch 122. Each report has
# its own sub-navigation item, so the old combined ortho/referrals panel is no
# longer present. Verify the new structure before accepting the release.
grep -q "defaultOpen" "$STAGE_DIR/src/components/WhatsAppOperationalReports.tsx" \
  || fail "Batch 103: the defaultOpen prop is missing from WhatsAppOperationalReports.tsx."
require_file "$STAGE_DIR/src/components/ReportsWorkspace.tsx"
grep -q "ReportsWorkspace" "$STAGE_DIR/src/app/reports/page.tsx" || fail "Batch 122: reports side navigation is not wired."
for report_key in 'key: "ortho"' 'key: "referrals"' 'key: "duration"' 'key: "incomplete"'; do
  grep -q "$report_key" "$STAGE_DIR/src/app/reports/page.tsx" \
    || fail "Batch 122: a required patient report navigation item is missing: $report_key"
done

# Renamed panel titles: the generic "التقارير التشغيلية عند الطلب" heading is
# gone from both places it used to say it - the financial tab now names the
# single report it holds, and the patients tab names what it actually shows.
grep -q "title?: string" "$STAGE_DIR/src/components/WhatsAppOperationalReports.tsx" \
  || fail "Batch 103: the title prop is missing from WhatsAppOperationalReports.tsx."
grep -q 'only={\["unpaid"\]} title="تم بدون دفع"' "$STAGE_DIR/src/app/reports/page.tsx" \
  || fail "Batch 103: the financial-tab panel is not titled 'تم بدون دفع' in src/app/reports/page.tsx."
grep -q 'title="متابعة تقويم متأخرة"' "$STAGE_DIR/src/app/reports/page.tsx" \
  || fail "Batch 122: the overdue orthodontic follow-up report title is missing."
grep -q 'title="التحويلات"' "$STAGE_DIR/src/app/reports/page.tsx" \
  || fail "Batch 122: the referrals report title is missing."

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

# --------------------------------------------------------------------------
# Batch 108: HOTFIX for a production outage. Every "خامات" (supplier
# invoice/payment) action that ran logAdminEvent() from INSIDE
# db.transaction().execute(async (trx) => {...}) deadlocked the entire app
# for every user, not just the one clicking the button: logAdminEvent() uses
# the module-level `db` object, but the SqliteDialect connection is a single
# shared connection guarded by one JS-level mutex. The outer transaction
# holds that mutex until its callback returns; calling db.<query>() from
# inside the same callback tries to re-acquire the same mutex and waits
# forever - a promise that can never resolve, since only returning from the
# callback releases it. No SQLite-level busy_timeout catches this (it is a
# JS-level lock, not a SQLite one), so it does not error out or log
# anything: the request just hangs (Network tab shows "pending" forever),
# and every other request needing the database hangs behind it too. Only a
# manual `systemctl restart clinic-app` recovers.
# Fix: logAdminEvent() is now called AFTER each transaction has returned and
# released the connection, using data returned out of the transaction
# instead of being called from inside it. Checked below by intent (no
# logAdminEvent/logOverride call sits inside a db.transaction().execute(...)
# block anywhere in this file), not by a single string, so a future
# regression of the same kind is also caught.
# --------------------------------------------------------------------------
echo "== checking for the batch-108 deadlock class (logAdminEvent inside db.transaction) =="
node - "$STAGE_DIR/src/app/expenses/actions.ts" <<'NODEEOF' || fail "Batch 108: logAdminEvent/logOverride is still called from inside a db.transaction().execute() block in expenses/actions.ts - this is the exact deadlock that took the whole app down."
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf-8");
const re = /db\.transaction\(\)\.execute\(async\s*\(trx\)\s*=>\s*\{/g;
let m, bad = false;
while ((m = re.exec(src))) {
  let depth = 0, i = m.index + m[0].length - 1;
  for (; i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}") { depth--; if (depth === 0) break; }
  }
  const body = src.slice(m.index + m[0].length - 1, i + 1);
  if (/logAdminEvent\(|logOverride\(/.test(body)) bad = true;
}
process.exit(bad ? 1 : 0);
NODEEOF
grep -q "addSupplierInvoiceAction" "$STAGE_DIR/src/app/expenses/actions.ts" \
  || fail "Batch 108: addSupplierInvoiceAction went missing from expenses/actions.ts."

# --------------------------------------------------------------------------
# Batch 109: (1) new "الكشوفات غير المكتملة" report, (2) the three separate
# patient-report permissions (ortho followup, referrals, patient duration)
# consolidated into one new permission view_patient_reports (تقييمات المرضى
# stays on its own untouched permission), (3) the patients-list permission
# now applies to every role, not just doctors - only admin sees it by
# default until granted per user.
# --------------------------------------------------------------------------
for removed in view_ortho_followup_report view_referral_report view_patient_duration_report; do
  if grep -rq "$removed" "$STAGE_DIR/src"; then
    fail "Batch 109: the removed permission key $removed is still referenced somewhere in src/ - the consolidation into view_patient_reports is incomplete."
  fi
done
grep -q '"view_patient_reports"' "$STAGE_DIR/src/lib/permission-defs.ts" \
  || fail "Batch 109: the consolidated view_patient_reports permission is missing from permission-defs.ts."
grep -q '"view_patient_review_report"' "$STAGE_DIR/src/lib/permission-defs.ts" \
  || fail "Batch 109: view_patient_review_report must stay untouched - it went missing from permission-defs.ts."
require_file "$STAGE_DIR/src/app/reports/incomplete-checkup-actions.ts"
require_file "$STAGE_DIR/src/components/IncompleteCheckupReport.tsx"
grep -q "getIncompleteCheckupReportAction" "$STAGE_DIR/src/app/reports/incomplete-checkup-actions.ts" \
  || fail "Batch 109: getIncompleteCheckupReportAction is missing from incomplete-checkup-actions.ts."
grep -q "view_patient_reports" "$STAGE_DIR/src/app/reports/incomplete-checkup-actions.ts" \
  || fail "Batch 109: the incomplete-checkup report is not gated by view_patient_reports."
grep -q "IncompleteCheckupReport" "$STAGE_DIR/src/app/reports/page.tsx" \
  || fail "Batch 109: IncompleteCheckupReport is not wired into reports/page.tsx."
# Patients-list permission must apply to every role now - no more doctor-only
# carve-out. Keep this check on the same source line as view_patients_list;
# nearby doctor-specific features (such as the attendance queue in batch 110)
# must not be mistaken for a permission bypass.
if grep -E 'role !== "doctor".*view_patients_list|view_patients_list.*role !== "doctor"|isDoctorRole.*hasPermission.*view_patients_list|hasPermission.*view_patients_list.*isDoctorRole' \
    "$STAGE_DIR/src/app/layout.tsx" "$STAGE_DIR/src/app/patients/page.tsx" >/dev/null 2>&1; then
  fail "Batch 109: view_patients_list still looks bypassed by a doctor-only role check in layout.tsx or patients/page.tsx."
fi
# Batch 110: schedule readability/status, full patient search, doctor future
# schedule, queue visibility, follow-up billing repair, and medical-record filters.
require_file "$STAGE_DIR/src/components/MedicalVisitHistory.tsx"
if grep -q 'limit(500)' "$STAGE_DIR/src/app/page.tsx" "$STAGE_DIR/src/app/front-desk/page.tsx"; then
  fail "Batch 110: the booking patient search still has the 500-patient cap."
fi
grep -q 'normalizePhoneNumber' "$STAGE_DIR/src/components/QuickPatientSearch.tsx" \
  || fail "Batch 110: phone normalization is missing from QuickPatientSearch."
grep -q 'phone:p.phone' "$STAGE_DIR/src/app/page.tsx" \
  || fail "Batch 110: the doctor schedule does not pass patient phone numbers to search."
grep -q 'phone:p.phone' "$STAGE_DIR/src/app/front-desk/page.tsx" \
  || fail "Batch 110: the front-desk schedule does not pass patient phone numbers to search."
grep -q 'clinicDateOffset(today, 90)' "$STAGE_DIR/src/app/page.tsx" \
  || fail "Batch 110: the doctor's 90-day future schedule window is missing."
grep -q 'showAttendanceQueue' "$STAGE_DIR/src/app/layout.tsx" "$STAGE_DIR/src/components/NavBar.tsx" \
  || fail "Batch 110: attendance-queue visibility is not wired through layout/NavBar."
grep -q 'schedule-appointment-cell--attended' "$STAGE_DIR/src/app/globals.css" "$STAGE_DIR/src/components/CentralSchedule.tsx" \
  || fail "Batch 110: the full attended-cell colour is missing."
grep -q 'FOLLOWUP_SERVICE_CODE' "$STAGE_DIR/src/components/EditInvoiceButton.tsx" "$STAGE_DIR/src/app/patients/[id]/billing/actions.ts" \
  || fail "Batch 110: follow-up billing type is not derived from the selected service."
if grep -rq 'isFollowupRow' "$STAGE_DIR/src/components/EditInvoiceButton.tsx" "$STAGE_DIR/src/app/patients/[id]/billing/page.tsx"; then
  fail "Batch 110: the stale isFollowupRow prop is still present."
fi
grep -q 'primary_doctor_id === selectedDoctorId' "$STAGE_DIR/src/components/MedicalVisitHistory.tsx" \
  || fail "Batch 110: primary-doctor medical-record filtering is missing."
grep -q 'performing_doctor_id === selectedDoctorId' "$STAGE_DIR/src/components/MedicalVisitHistory.tsx" \
  || fail "Batch 110: assistant/performing-doctor medical-record filtering is missing."
grep -q 'visit.ortho_visit_id != null' "$STAGE_DIR/src/components/MedicalVisitHistory.tsx" \
  || fail "Batch 110: General/Ortho medical-record filtering is missing."

# Batch 112: inventory lock, per-tooth tube stock, actionable tasks, and
# doctor schedule editing for the authorized 90-day window.
for relative in \
  src/app/tasks/actions.ts \
  src/components/InventoryDeductionToggle.tsx \
  src/components/OrthodonticTubeStock.tsx \
  src/components/PatientTaskButton.tsx \
  src/components/TaskCenter.tsx \
  src/lib/appointment-edit.ts \
  src/lib/inventory-control.ts \
  src/lib/ortho/tube-stock.ts \
  src/lib/tasks.ts; do
  require_file "$STAGE_DIR/$relative"
done
grep -q '111_tasks_inventory_switch_tube_stock' "$STAGE_DIR/src/lib/db/client.ts" \
  || fail "Batch 112: database migration is missing."
grep -q 'inventory_deductions_enabled' "$STAGE_DIR/src/lib/inventory-control.ts" "$STAGE_DIR/src/components/InventoryDeductionToggle.tsx" \
  || fail "Batch 112: inventory master switch is not wired end-to-end."
grep -q 'TUBE_6_TEETH = \[16, 26, 36, 46\]' "$STAGE_DIR/src/lib/ortho/tube-stock.ts" \
  || fail "Batch 112: Tube 6 cell mapping is wrong or missing."
grep -q 'TUBE_7_TEETH = \[17, 27, 37, 47\]' "$STAGE_DIR/src/lib/ortho/tube-stock.ts" \
  || fail "Batch 112: Tube 7 cell mapping is wrong or missing."
grep -q 'insertInto("tasks")' "$STAGE_DIR/src/app/referrals/actions.ts" \
  || fail "Batch 112: referrals are not being created as tasks."
grep -q 'autoCloseReferralTasksForAppointment' "$STAGE_DIR/src/app/appointments/actions.ts" "$STAGE_DIR/src/app/appointments/billing-actions.ts" \
  || fail "Batch 112: referral tasks are not linked to appointment completion."
grep -q 'canEditAppointmentSlot' "$STAGE_DIR/src/app/appointments/actions.ts" \
  || fail "Batch 112: server-side doctor schedule authorization is missing."
grep -q 'canEditSelectedDate && canEditSchedule' "$STAGE_DIR/src/app/page.tsx" \
  || fail "Batch 112: future schedule editing is not enabled in the doctor UI."

# Batch 113: synchronized orthodontic-chart summaries and their managed lists.
for relative in \
  src/components/OrthoChartSummaryOptionsForm.tsx \
  src/components/ortho/DiagnosticChart.tsx \
  src/components/ortho/InteractiveToothChart.tsx \
  src/components/ortho/OrthoChartV2.tsx; do
  require_file "$STAGE_DIR/$relative"
done
grep -q 'diagnosis_summary TEXT' "$STAGE_DIR/src/lib/db/schema.sql" "$STAGE_DIR/src/lib/db/client.ts" \
  || fail "Batch 113: diagnosis summary database field is missing."
grep -q 'manage_ortho_chart_options' "$STAGE_DIR/src/lib/permission-defs.ts" "$STAGE_DIR/src/app/settings/actions.ts" \
  || fail "Batch 113: orthodontic chart options permission is not wired."
grep -q 'saveOrthoChartSummaryAction' "$STAGE_DIR/src/app/patients/[id]/orthodontics/ortho-v2-actions.ts" "$STAGE_DIR/src/components/ortho/OrthoChartV2.tsx" \
  || fail "Batch 113: automatic chart-summary saving is not wired."
grep -q 'chief_complaint' "$STAGE_DIR/src/components/ortho/InteractiveToothChart.tsx" \
  || fail "Batch 113: Chief complaint chart tab is missing."
grep -q 'diagnosis' "$STAGE_DIR/src/components/ortho/InteractiveToothChart.tsx" \
  || fail "Batch 113: Diagnosis chart tab is missing."

# Batch 114: wide chart editor and compact clinic favicon.
grep -q 'width:calc(100% - 3rem)' "$STAGE_DIR/src/app/globals.css" \
  || fail "Batch 114: chart summary editor does not use the intended wide layout."
grep -q 'icon.png?v=114' "$STAGE_DIR/src/app/layout.tsx" \
  || fail "Batch 114: versioned compact favicon is not wired."
require_file "$STAGE_DIR/src/app/favicon.ico"

# Batch 115: patient archive, outreach exclusion, tube quadrants and final
# chart-editor spacing/type adjustments.
for relative in \
  src/lib/patient-archive.ts \
  src/components/PatientArchiveButton.tsx \
  src/components/OrthodonticTubeStock.tsx; do
  require_file "$STAGE_DIR/$relative"
done
grep -q 'archived_at' "$STAGE_DIR/src/lib/db/schema.sql" "$STAGE_DIR/src/lib/db/client.ts" \
  || fail "Batch 115: patient archive database fields are missing."
grep -q 'archiveInactivePatients' "$STAGE_DIR/src/app/patients/page.tsx" \
  || fail "Batch 115: automatic inactive-patient archiving is missing."
grep -q '__clinicPatientArchiveTimer' "$STAGE_DIR/src/instrumentation.ts" \
  || fail "Batch 115: scheduled inactive-patient archiving is missing."
grep -q 'reactivatePatientForCare' "$STAGE_DIR/src/app/appointments/actions.ts" "$STAGE_DIR/src/app/patients/[id]/actions.ts" "$STAGE_DIR/src/app/patients/[id]/billing/actions.ts" \
  || fail "Batch 115: patient reactivation after care is missing."
grep -q 'patients.archived_at' "$STAGE_DIR/src/lib/whatsapp/appointment-reminders.ts" "$STAGE_DIR/src/app/appointment-reminders/report-actions.ts" \
  || fail "Batch 115: archived patients are not excluded from proactive WhatsApp messaging."
grep -q 'TUBE_ROWS' "$STAGE_DIR/src/components/OrthodonticTubeStock.tsx" \
  || fail "Batch 115: tube stock is not arranged by upper/lower quadrants."
grep -q 'top:28rem' "$STAGE_DIR/src/app/globals.css" \
  || fail "Batch 115: chart editor was not moved one line lower."
grep -q 'font-size:1.08rem' "$STAGE_DIR/src/app/globals.css" \
  || fail "Batch 115: chart editor text was not enlarged."

# Every "use server" file must still export only async functions.
node "$STAGE_DIR/scripts/check-use-server.mjs" "$STAGE_DIR/src" \
  || fail "Batch 107: a \"use server\" file exports something other than an async function."

# --------------------------------------------------------------------------
# Batch 123: clinic-status context menu, «الاستقبال» row, no-show/cancel
# confirmation, no-show kept on home, doctor sees own in-clinic patient, and
# the 3-minute in-clinic rule (no-show/cancel blocked, «تم» only).
# --------------------------------------------------------------------------
require_file "$STAGE_DIR/src/lib/clinic-visit.ts"
require_file "$STAGE_DIR/docs/BATCH123.md"
grep -q "CLINIC_CONFIRM_MS = 3 \* 60_000" "$STAGE_DIR/src/lib/clinic-visit.ts" \
  || fail "Batch 123: the 3-minute in-clinic threshold is missing from clinic-visit.ts."
grep -q "left_clinic_at TEXT" "$STAGE_DIR/src/lib/db/client.ts" "$STAGE_DIR/src/lib/db/schema.sql" \
  || fail "Batch 123: left_clinic_at column is missing."
grep -q "123_clinic_exit_reception" "$STAGE_DIR/src/lib/db/client.ts" \
  || fail "Batch 123: database migration is missing."
awk '/^export async function updateAppointmentStatusAction/{f=1} f{print} f&&/^}/{exit}' "$STAGE_DIR/src/app/appointments/actions.ts" \
  | grep -q "isClinicVisitConfirmed" || fail "Batch 123: server-side 3-minute guard is missing from updateAppointmentStatusAction."
awk '/^export async function clearAppointmentAttendanceAction/{f=1} f{print} f&&/^}/{exit}' "$STAGE_DIR/src/app/appointments/actions.ts" \
  | grep -q "isClinicVisitConfirmed" || fail "Batch 123: server-side 3-minute guard is missing from clearAppointmentAttendanceAction."
awk '/^export async function setAppointmentEnteredRoomAction/{f=1} f{print} f&&/^}/{exit}' "$STAGE_DIR/src/app/appointments/actions.ts" \
  | grep -q "left_clinic_at: now" || fail "Batch 123: entering an occupied clinic does not move the previous patient to reception."
grep -q "home-clinic-reception" "$STAGE_DIR/src/components/CentralSchedule.tsx" \
  || fail "Batch 123: the reception row is missing from the home clinic status."
grep -q "statusConfirm" "$STAGE_DIR/src/components/CentralSchedule.tsx" \
  || fail "Batch 123: no-show/cancel confirmation dialog is missing."
grep -q 'a.status === "no_show"' "$STAGE_DIR/src/components/CentralSchedule.tsx" \
  || fail "Batch 123: no-show appointments are not kept on the home list."
grep -q "clinicRooms={embeddedHome ? clinicRooms : \[\]}" "$STAGE_DIR/src/app/front-desk/page.tsx" \
  || fail "Batch 123: clinic rooms (incl. doctor's entered rooms) are not passed to the home schedule."
if grep -q "HomeClinicStatus" "$STAGE_DIR/src/app/page.tsx"; then
  fail "Batch 123: page.tsx still renders the old static HomeClinicStatus (no context menu)."
fi

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
  CLINIC_DB_PATH="$STAGE_DIR/.build/clinic.db" npm run build -- --webpack \
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

echo "== verifying Batch 112 through 123 database changes =="
SUCCESS=0
CLINIC_DB_PATH="$APP_DIR/data/clinic.db" node - <<'NODE' \
  || fail "Batch 112-123 database verification failed."
const Database = require("better-sqlite3");
const db = new Database(process.env.CLINIC_DB_PATH, { readonly: true });
const migration = db.prepare("SELECT 1 AS ok FROM schema_migrations WHERE name = ?").get("111_tasks_inventory_switch_tube_stock");
const setting = db.prepare("SELECT value FROM clinic_settings WHERE key = ?").get("inventory_deductions_enabled");
const tubeCells = db.prepare("SELECT COUNT(*) AS total FROM orthodontic_tube_stock").get();
const foreignKeys = db.pragma("foreign_key_check");
const orthoColumns = db.prepare("PRAGMA table_info(orthodontic_charts)").all().map((column) => column.name);
const patientColumns = db.prepare("PRAGMA table_info(patients)").all().map((column) => column.name);
const appointmentColumns = db.prepare("PRAGMA table_info(appointments)").all().map((column) => column.name);
const migration123 = db.prepare("SELECT 1 AS ok FROM schema_migrations WHERE name = ?").get("123_clinic_exit_reception");
if (!migration123 || !appointmentColumns.includes("left_clinic_at") || !appointmentColumns.includes("clinic_confirmed_at")) process.exit(1);
if (!migration || !["0", "1"].includes(setting?.value) || Number(tubeCells?.total) !== 8 || !orthoColumns.includes("diagnosis_summary") || !patientColumns.includes("archived_at") || !patientColumns.includes("archive_activity_at") || foreignKeys.length !== 0) process.exit(1);
NODE
SUCCESS=1

# Preserve backups; cleanup is a separate operator decision.
echo "Deploy completed successfully."
echo "Data backup: $BACKUP_DIR"
echo "Previous release: $PREVIOUS_DIR"
echo
echo "== Batch 123 =="
echo "Clinic status right-click menu + reception row for patients who left the clinic."
echo "No-show/cancel confirmation; no-show stays on home; doctors see their in-clinic patient without a shift."
echo "After 3 minutes inside a clinic, no-show/cancel are blocked - only done."
