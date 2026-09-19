#!/usr/bin/env bash
set -Eeuo pipefail
cd /

APP_DIR="/opt/clinic-app"
SERVICE_NAME="clinic-app"
ARCHIVE="clinic-app-batch129.tar.gz"
ARCHIVE_SHA256="B5C605F15B16DA8B23C647FADF1732C9A061857BBE34E9FFF83537103BD7350B"
REPO_RAW="https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-http://127.0.0.1:3000/login}"
STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_DIR="/opt/clinic-app-data.backup-batch129-$STAMP"
PREVIOUS_DIR="/opt/clinic-app.previous-batch129-$STAMP"
FAILED_DIR="/opt/clinic-app.failed-batch129-$STAMP"
TEMP_DIR="$(mktemp -d /tmp/clinic-app-batch129-deploy.XXXXXX)"
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
  if [[ -d "$TEMP_DIR" && "$TEMP_DIR" == /tmp/clinic-app-batch129-deploy.* ]]; then
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

# Batch 129 upgrades the published Batch 128 (== batch127's content, republished
# by the clinic owner under a new number since 127 was already live).
# Refuse to overwrite unreviewed server-side changes before stopping the app.
#
# NOTE (flagged for manual verification before running this script for real):
# the previous deploy128.sh baseline block for "src/app/patients/[id]/actions.ts"
# listed 982698021e2485beebd4ba8fa68de0e8f6165edc8812eda012665b8aed8fa2ff — that
# is the batch126 (pre-127) hash of this file, not the batch127/128 one. It also
# had "require_absent" for src/lib/images/hash.ts and orientation.ts, which
# contradicts those files having been added BY batch127. Both look like a
# baseline that was written without directly querying the live server. Before
# running deploy129.sh for real, run on the live server:
#   sha256sum /opt/clinic-app/src/app/patients/[id]/actions.ts
#   sha256sum /opt/clinic-app/src/lib/images/hash.ts
#   sha256sum /opt/clinic-app/src/lib/images/orientation.ts
# and compare against the values below (recomputed directly from the actual
# uploaded clinic-app-batch128.tar.gz). If the live actions.ts hash does NOT
# match c3fcf08e0355fcca41c7628bfb0aa5b85dc73167d18a030e6f5b77e727184763 below,
# STOP and tell us — it would mean the live server is not actually running the
# rotateImageAction rewrite, which changes our diagnosis of the rotation bug.
echo "== checking live batch-128 source before replacement =="
while read -r expected relative; do
  live_file="$APP_DIR/$relative"
  [[ -f "$live_file" ]] || fail "Live source file is missing: $live_file"
  actual="$(sha256sum "$live_file" | awk '{print tolower($1)}')"
  if [[ "$actual" != "$expected" ]]; then
    fail "Live source differs from published batch 128: $relative. Merge the server-side change before deploying batch 129."
  fi
done <<'BATCH128_BASELINE_HASHES'
f4522e0e8253eebd2c05c30121341cb8d70e4a4421f285b56a32b4f030becd31 src/app/api/patient-files/upload/route.ts
c3fcf08e0355fcca41c7628bfb0aa5b85dc73167d18a030e6f5b77e727184763 src/app/patients/[id]/actions.ts
a2e06d4f9c02066dfa9dd953e238937c3e82ffca6793f8d23f6e387976f82b62 src/app/patients/[id]/billing/page.tsx
7f20611d75ade316929c86d009d1445a5e08b33f554b4cea97261efaa415f5ea src/app/patients/[id]/images/template-actions.ts
1a492ad8d9020610280bdccdf01f677f280205a684927fa72d3bf231b70e274b src/components/AddImageGroupForm.tsx
411bcd7afba8aa2dd01443a7f38b801208701ed82ebcbb469aaab06437bf00fb src/components/PatientAvatar.tsx
18514b6b1109e5dbb611b9593a0d91e00501f4de5badedf094844f241b84df5d src/components/ortho/ImageTemplateBoard.tsx
1eb3f1a94cb7858fccf2449718cd1ead2013a3ab0c6198080924da2589b3238a src/components/ortho/OrthoAddImageGroupForm.tsx
4ddd4b4cde985045497900bcc500e5cb5d0be05f9c1fcb5088d4c60493594b12 src/components/ortho/OrthoImageGallery.tsx
d7f9b924accb582e100aa7984fd86e88f86e2a39d46442ddfa85782fe42c44ac src/components/ortho/OrthoChartV2.tsx
0bac889fa06d52bf8f3bfe02f631e2800fe9ea6ef793ff2ec44d677fb2e228d7 src/lib/db/client.ts
aaa6786c6c532b5f501c0922a6dfba38b80f97663bb287a89a18b069d41154a8 src/lib/db/schema.sql
89020b964fa008b3e8f863b42522bedc091b6edd72cd87ef32d40c384bc647cf src/lib/db/types.ts
1f4ff2c5b0dff0dd801a481cf78a58826bdbc49e8c8c3d6cd9714370158a49ad src/lib/images/classify.ts
e7c184b4589aa764d96ff43dc6dfb32429ece0f6af299750d4b8684bc4fb64eb src/lib/images/kinds.ts
322e3195547db6ea631e375a2e2004f2966af0d78c559a0f08f10ebe1221cfa4 src/lib/images/order.ts
8664f867e8d2007993dd02bcf39461248fd3b843371086db3b7c02e34516455b src/lib/images/hash.ts
af269f74d99d13907c9672c1b201d676dfe739ce09eef9eb25095ccc8433adfd src/lib/images/orientation.ts
5d586bbe6a2a756b6e80c3b9cd7021b60c26a1c052939c6293e343ded66cfb0a src/lib/patient-file-upload.ts
f6336804b3b52cb6ef42d9c21f8a54be9f90ad593e78b424d581ed130febd2dd src/app/patients/[id]/orthodontics/page.tsx
967be3196b2e1db5e1643e435b8e9592f796c5f260c6f14db3f79b4df1843af2 src/app/patient-files/[...path]/route.ts
BATCH128_BASELINE_HASHES

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

# --------------------------------------------------------------------------
# Batch 124: التعرف التلقائي على صور المريض + تمبلت صور التقويم + صورة الملف.
# --------------------------------------------------------------------------
require_file "$STAGE_DIR/src/lib/images/classify.ts"
require_file "$STAGE_DIR/src/lib/images/kinds.ts"
require_file "$STAGE_DIR/src/lib/images/template.ts"
require_file "$STAGE_DIR/src/components/ortho/ImageTemplateBoard.tsx"
require_file "$STAGE_DIR/src/components/OrthoImageTemplateForm.tsx"
require_file "$STAGE_DIR/src/app/patients/[id]/images/template-actions.ts"
require_file "$STAGE_DIR/docs/BATCH124.md"
awk '/INSERT INTO invoices/{print}' "$STAGE_DIR/scripts/seed.js" | grep -q "patient_id" \
  || fail "Batch 124: scripts/seed.js still inserts an invoice without patient_id (local seeding would fail)."
grep -q '"sharp"' "$STAGE_DIR/package.json" \
  || fail "Batch 124: sharp is not an explicit dependency (image classification needs it)."
grep -q "node_modules/sharp" "$STAGE_DIR/package-lock.json" \
  || fail "Batch 124: sharp is missing from package-lock.json."
grep -q "image_kind TEXT" "$STAGE_DIR/src/lib/db/client.ts" "$STAGE_DIR/src/lib/db/schema.sql" \
  || fail "Batch 124: patient_images.image_kind column is missing."
grep -q "avatar_path" "$STAGE_DIR/src/lib/db/client.ts" "$STAGE_DIR/src/lib/db/schema.sql" \
  || fail "Batch 124: patients.avatar_path column is missing."
grep -q "124_patient_image_kinds" "$STAGE_DIR/src/lib/db/client.ts" \
  || fail "Batch 124: database migration is missing."
grep -q "ortho_image_template" "$STAGE_DIR/src/lib/settings.ts" \
  || fail "Batch 124: the ortho_image_template setting is not registered."
awk '/^export async function POST/{f=1} f{print}' "$STAGE_DIR/src/app/api/patient-files/upload/route.ts" \
  | grep -q "analyzeImage" || fail "Batch 124: uploads are not classified in the upload route."
grep -q "manage_ortho_chart_options" "$STAGE_DIR/src/app/settings/actions.ts" \
  || fail "Batch 124: the template settings action lost its permission guard."
awk '/^export async function saveOrthoImageTemplateAction/{f=1} f{print} f&&/^}/{exit}' "$STAGE_DIR/src/app/settings/actions.ts" \
  | grep -q "parseImageTemplate" || fail "Batch 124: the template settings action does not validate the incoming template."
grep -q "OrthoImageTemplateForm" "$STAGE_DIR/src/app/settings/page.tsx" \
  || fail "Batch 124: the template editor is not wired into the settings ortho chart section."
grep -q "ImageTemplateBoard" "$STAGE_DIR/src/components/ortho/OrthoAddImageGroupForm.tsx" "$STAGE_DIR/src/components/ortho/OrthoImageGallery.tsx" \
  || fail "Batch 124: the review board is not wired into the ortho upload/gallery."
grep -q "avatar_path" "$STAGE_DIR/src/app/patients/[id]/page.tsx" \
  || fail "Batch 124: the patient thumbnail is not shown on the patient file header."


# --------------------------------------------------------------------------
# Batch 126: مجموعة واحدة مرتّبة (Extra-Oral ← Intra-Oral ← X-ray ← Templates)،
# تمبلت ٣ صور في الصف بنسبة ثابتة، صورة ملف مستقلة، وإعادة التعرف على الصور.
# --------------------------------------------------------------------------
require_file "$STAGE_DIR/src/lib/images/order.ts"
require_file "$STAGE_DIR/src/components/PatientAvatar.tsx"
require_file "$STAGE_DIR/docs/BATCH126.md"
require_file "$STAGE_DIR/scripts/test-batch126.mjs"
grep -q "template_sheet" "$STAGE_DIR/src/lib/images/kinds.ts" \
  || fail "Batch 126: the ready-made template kind is missing from kinds.ts."
grep -q "face_oblique" "$STAGE_DIR/src/lib/images/kinds.ts" \
  || fail "Batch 126: the 45-degree face kind is missing from kinds.ts."
grep -q "IMAGE_KIND_LABELS_EN" "$STAGE_DIR/src/lib/images/kinds.ts" "$STAGE_DIR/src/components/ortho/ImageTemplateBoard.tsx" \
  || fail "Batch 126: the ortho template board is not using the English labels."
grep -q "gridBands" "$STAGE_DIR/src/lib/images/classify.ts" \
  || fail "Batch 126: ready-made template detection (grid separators) is missing."
grep -q "sortImagesByKind" "$STAGE_DIR/src/app/patients/[id]/page.tsx" "$STAGE_DIR/src/app/patients/[id]/orthodontics/page.tsx" \
  || fail "Batch 126: patient photos are not ordered by kind on the patient pages."
grep -q "serverExternalPackages" "$STAGE_DIR/next.config.ts" \
  || fail "Batch 126: sharp/better-sqlite3 are not declared as server external packages."
grep -q "reclassifyGroupAction" "$STAGE_DIR/src/app/patients/[id]/images/template-actions.ts" "$STAGE_DIR/src/components/ortho/OrthoImageGallery.tsx" \
  || fail "Batch 126: the re-detect action is not wired into the ortho gallery."
grep -q "clearPatientAvatarAction" "$STAGE_DIR/src/app/patients/[id]/images/template-actions.ts" \
  || fail "Batch 126: removing the patient file photo is missing."
grep -q "PatientAvatar" "$STAGE_DIR/src/app/patients/[id]/page.tsx" "$STAGE_DIR/src/components/ortho/OrthoChartV2.tsx" \
  || fail "Batch 126: the clickable patient file photo is not wired into the headers."
grep -q "image-template-sheet" "$STAGE_DIR/src/app/globals.css" \
  || fail "Batch 126: the 3-per-row template sheet styles are missing."
grep -q "aspect-ratio:4 / 3" "$STAGE_DIR/src/app/globals.css" \
  || fail "Batch 126: the fixed-ratio (never stretched) template cells are missing."
# حذف صورة مربوطة بصورة الملف كان بيعمل كراش (foreign key) - لازم يتصفر الربط الأول.
awk '/^export async function deleteImageAction/{f=1} f{print} f&&/^}/{exit}' "$STAGE_DIR/src/app/patients/[id]/actions.ts" \
  | grep -q "avatar_image_id" || fail "Batch 126: deleting an image still does not clear patients.avatar_image_id (crash)."
grep -q "URL.createObjectURL" "$STAGE_DIR/src/components/ortho/OrthoAddImageGroupForm.tsx" "$STAGE_DIR/src/components/AddImageGroupForm.tsx" \
  || fail "Batch 126: the upload dialogs do not show real thumbnails for staged files."

# --------------------------------------------------------------------------
# Batch 127: ترتيب الشريط (لغز النشر اتغطى بفحص ما بعد الـswap تحت)، صورة
# الملف المالي، Profile/45° smiling، منع تكرار الصور، تعديل نوع الصورة من
# التمبلت (log-only، بدون أي تعلّم تلقائي).
# --------------------------------------------------------------------------
require_file "$STAGE_DIR/docs/BATCH127.md"
grep -q "function looksSmiling" "$STAGE_DIR/src/lib/images/classify.ts" \
  || fail "Batch 127: looksSmiling() is missing from classify.ts."
grep -q '"face_profile_smile"' "$STAGE_DIR/src/lib/images/kinds.ts" \
  || fail "Batch 127: face_profile_smile kind is missing from kinds.ts."
grep -q '"face_oblique_smile"' "$STAGE_DIR/src/lib/images/kinds.ts" \
  || fail "Batch 127: face_oblique_smile kind is missing from kinds.ts."
grep -q "face_profile_smile" "$STAGE_DIR/src/lib/images/order.ts" \
  || fail "Batch 127: the new smiling kinds are not in the display order (order.ts)."
grep -q "export function fileSha256" "$STAGE_DIR/src/lib/images/hash.ts" \
  || fail "Batch 127: content-hash helper (fileSha256) is missing from hash.ts."
grep -q "fileSha256" "$STAGE_DIR/src/app/api/patient-files/upload/route.ts" \
  || fail "Batch 127: content-hash duplicate detection is missing from the upload route."
grep -q "function dedupeNameKey" "$STAGE_DIR/src/app/api/patient-files/upload/route.ts" \
  || fail "Batch 127: filename-based duplicate detection is missing from the upload route."
grep -q "duplicate: true" "$STAGE_DIR/src/app/api/patient-files/upload/route.ts" \
  || fail "Batch 127: the upload route does not report duplicates back to the client."
grep -q "duplicates: string\[\]" "$STAGE_DIR/src/lib/patient-file-upload.ts" \
  || fail "Batch 127: UploadResult.duplicates is missing from patient-file-upload.ts."
grep -q "result.duplicates" "$STAGE_DIR/src/components/AddImageGroupForm.tsx" \
  || fail "Batch 127: the medical-file upload form does not surface duplicate results."
grep -q "result.duplicates" "$STAGE_DIR/src/components/ortho/OrthoAddImageGroupForm.tsx" \
  || fail "Batch 127: the ortho-chart upload form does not surface duplicate results."
grep -q "result.duplicates" "$STAGE_DIR/src/components/PatientAvatar.tsx" \
  || fail "Batch 127: the avatar uploader does not check for duplicates."
grep -q "127_patient_image_dedupe_and_corrections" "$STAGE_DIR/src/lib/db/client.ts" \
  || fail "Batch 127: the dedupe/corrections database migration is missing from client.ts."
grep -q "CREATE TABLE IF NOT EXISTS patient_image_corrections" "$STAGE_DIR/src/lib/db/client.ts" "$STAGE_DIR/src/lib/db/schema.sql" \
  || fail "Batch 127: the patient_image_corrections table is missing."
grep -q "content_hash" "$STAGE_DIR/src/lib/db/schema.sql" \
  || fail "Batch 127: patient_images.content_hash column is missing from schema.sql."
grep -q "export async function setImageKindAction" "$STAGE_DIR/src/app/patients/[id]/images/template-actions.ts" \
  || fail "Batch 127: setImageKindAction (manual template correction + logging) is missing from template-actions.ts."
grep -q "setImageKindAction" "$STAGE_DIR/src/components/ortho/ImageTemplateBoard.tsx" \
  || fail "Batch 127: the template board is not wired to setImageKindAction."
grep -q "openId" "$STAGE_DIR/src/components/ortho/ImageTemplateBoard.tsx" \
  || fail "Batch 127: the click-to-enlarge lightbox is missing from ImageTemplateBoard.tsx."
# Safety rail explicitly requested by the clinic owner: manual corrections are
# logged for human review only. Nothing in template-actions.ts may auto-tune
# classify.ts's thresholds/behavior from patient_image_corrections data.
if grep -q "patient_image_corrections" "$STAGE_DIR/src/lib/images/classify.ts"; then
  fail "Batch 127: classify.ts references patient_image_corrections — corrections must stay log-only, never feed back into the live classifier automatically."
fi
# The financial-file patient photo bug (this batch's fix #2).
grep -q "PatientAvatar" "$STAGE_DIR/src/app/patients/[id]/billing/page.tsx" \
  || fail "Batch 127: PatientAvatar is not wired into the billing/financial page."

# --------------------------------------------------------------------------
# Batch 127 (الجولة التانية): تخمين الاتجاه التلقائي وقت الرفع للصور من غير
# EXIF، التدوير اليدوي بقى بيخبز البايتات فعليًا ويعيد التصنيف بدل ما يفضل
# مجرد CSS transform، ولوحة التمبلت بقى فيها lightbox غني (تنقل/تدوير/حذف)
# زي شريط الصور بالظبط + قفل بالدوس برة المودال.
# --------------------------------------------------------------------------
require_file "$STAGE_DIR/src/lib/images/hash.ts"
require_file "$STAGE_DIR/src/lib/images/orientation.ts"
grep -q "export async function guessAndBakeOrientation" "$STAGE_DIR/src/lib/images/orientation.ts" \
  || fail "Batch 127: guessAndBakeOrientation is missing from orientation.ts."
grep -q "export async function bakeRotation" "$STAGE_DIR/src/lib/images/orientation.ts" \
  || fail "Batch 127: bakeRotation is missing from orientation.ts."
grep -q "guessAndBakeOrientation" "$STAGE_DIR/src/app/api/patient-files/upload/route.ts" \
  || fail "Batch 127: the upload route does not call guessAndBakeOrientation for EXIF-less photos."
grep -q "bakeRotation" "$STAGE_DIR/src/app/patients/[id]/actions.ts" \
  || fail "Batch 127: rotateImageAction does not bake the rotation into the actual file bytes."
grep -q "analyzeImage" "$STAGE_DIR/src/app/patients/[id]/actions.ts" \
  || fail "Batch 127: rotateImageAction does not re-run analyzeImage after a manual rotation."
grep -q "rotation:" "$STAGE_DIR/src/app/patients/[id]/images/template-actions.ts" \
  || fail "Batch 127: TemplateImage is missing the rotation field needed for the template lightbox."
grep -q "\"rotation\"" "$STAGE_DIR/src/app/patients/[id]/images/template-actions.ts" \
  || fail "Batch 127: suggestGroupTemplateAction/listAvatarCandidatesAction do not select the rotation column."
grep -q "rotateImageAction" "$STAGE_DIR/src/components/ortho/ImageTemplateBoard.tsx" \
  || fail "Batch 127: the template lightbox is not wired to rotateImageAction (manual rotate must match the gallery strip)."
grep -q "deleteImageAction" "$STAGE_DIR/src/components/ortho/ImageTemplateBoard.tsx" \
  || fail "Batch 127: the template lightbox is not wired to deleteImageAction (delete/X must match the gallery strip)."
grep -q 'onClick={onClose}' "$STAGE_DIR/src/components/ortho/ImageTemplateBoard.tsx" \
  || fail "Batch 127: clicking outside the photo-template modal does not close it back to the chart."

# --------------------------------------------------------------------------
# Batch 129: fixes two real bugs found after publishing batch127/128 live:
#
# (1) The auto-orientation-guess at upload was scoring "highest symmetry/
#     balance" as universally "correct" — wrong for a genuine Profile shot
#     (naturally asymmetric), so it actively mis-rotated real Profile photos
#     (seen live on patient 504's photos). Fixed: the guess now only applies
#     when the winning rotation clearly passes isFrontalFace() AND the
#     as-uploaded (0 deg) orientation does not — so it can never touch a
#     genuine Profile/oblique shot.
# (2) Manual rotate looked like it "did nothing": (a) rotateImageAction was
#     re-running the full analyzeImage() classification on every single
#     click, making it slower and coupling two separate concerns the owner
#     explicitly asked to decouple ("خليه ينفذ الروتيشن طالما مانوال وبعد
#     كدة نعمل redetect"); (b) far more importantly, patient-files/[...path]
#     serves images with "Cache-Control: private, max-age=3600" and NO
#     ETag/Last-Modified — so once a browser had cached a photo, it would
#     keep showing the OLD cached bytes for up to an hour (surviving a plain
#     refresh, and even closing/reopening the app, since that's the
#     browser's disk HTTP cache, not a tab's memory) even though the server
#     had already rotated the file correctly. Fixed: the route now sends
#     ETag/Last-Modified based on the file's real mtime and requires
#     revalidation on every request (still cheap via 304 when unchanged),
#     and the gallery/template now append the image's content_hash as a
#     cache-busting query param so React actually swaps the <img> src the
#     moment the hash changes.
# --------------------------------------------------------------------------
require_file "$STAGE_DIR/docs/BATCH129.md"
grep -q "isFrontalFace" "$STAGE_DIR/src/lib/images/orientation.ts" \
  || fail "Batch 129: guessAndBakeOrientation no longer gates on isFrontalFace - this is the fix for the mis-rotated Profile photos seen live."
awk '/^export async function rotateImageAction/{f=1} f{print} f&&/^}/{exit}' "$STAGE_DIR/src/app/patients/[id]/actions.ts" | grep -q "analyzeImage(" \
  && fail "Batch 129: rotateImageAction still calls analyzeImage() on every click - this must be decoupled per the owner's explicit request (manual rotate, then a separate re-detect)."
grep -q "reclassifyGroupAction" "$STAGE_DIR/src/components/ortho/ImageTemplateBoard.tsx" \
  || fail "Batch 129: the template board has no re-detect action, so there is no way to reclassify photos after a manual rotation batch."
grep -q "ETag" "$STAGE_DIR/src/app/patient-files/[...path]/route.ts" \
  || fail "Batch 129: the file-serving route does not send an ETag - rotated/re-uploaded photos can be served stale from the browser cache indefinitely."
grep -q "Last-Modified" "$STAGE_DIR/src/app/patient-files/[...path]/route.ts" \
  || fail "Batch 129: the file-serving route does not send Last-Modified."
if grep -q '"private, max-age=3600"' "$STAGE_DIR/src/app/patient-files/[...path]/route.ts"; then
  fail "Batch 129: the file-serving route still uses a blind 1-hour Cache-Control with no revalidation - this is EXACTLY the bug that hid the manual-rotate fix behind the browser cache."
fi
grep -q "withCacheBust" "$STAGE_DIR/src/components/ortho/OrthoImageGallery.tsx" \
  || fail "Batch 129: the gallery strip does not cache-bust rotated photo URLs."
grep -q "withCacheBust" "$STAGE_DIR/src/components/ortho/ImageTemplateBoard.tsx" \
  || fail "Batch 129: the template lightbox does not cache-bust rotated photo URLs."

# --------------------------------------------------------------------------
# Regression guard for the crash the FIRST batch129 deploy attempt hit live:
# schema.sql ran "CREATE INDEX ... ON patient_images(content_hash)"
# unconditionally, right after a "CREATE TABLE IF NOT EXISTS patient_images"
# that is a no-op on an existing server (the column is only added later, by
# the migration's ALTER TABLE) - so schema.sql itself crashed with
# "SqliteError: no such column: content_hash" on every single restart
# (crash-loop), which is exactly why the health check saw "no response" and
# deploy127.sh/deploy128.sh correctly rolled back. Fixed by moving that CREATE INDEX into
# the migration itself (after the ALTER TABLE), where it already belongs for
# every other column added post-launch. This check makes sure schema.sql
# never regresses to doing that again for this column.
# --------------------------------------------------------------------------
if grep -q "CREATE INDEX IF NOT EXISTS idx_patient_images_content_hash" "$STAGE_DIR/src/lib/db/schema.sql"; then
  fail "Batch 127: schema.sql still creates idx_patient_images_content_hash directly - this is EXACTLY the bug that crash-looped the live server on the first deploy attempt (the index runs before the column exists on an upgrade). It belongs only inside the 127_patient_image_dedupe_and_corrections migration in client.ts, after the ALTER TABLE."
fi
grep -q "CREATE INDEX IF NOT EXISTS idx_patient_images_content_hash" "$STAGE_DIR/src/lib/db/client.ts" \
  || fail "Batch 127: the content_hash index is missing from the migration in client.ts."

# --------------------------------------------------------------------------
# NEW IN 127: snapshot the exact bytes we just extracted and verified, BEFORE
# the staging build (or anything else) can touch them. This is what the
# post-swap check further down re-verifies against, directly on the LIVE
# path after the mv — the check that would have caught the batch126
# stale-file mystery instead of it surfacing days later from a screenshot.
# --------------------------------------------------------------------------
POST_SWAP_VERIFY_FILES=(
  "src/app/patients/[id]/orthodontics/page.tsx"
  "src/lib/images/order.ts"
  "src/lib/images/classify.ts"
  "src/lib/images/kinds.ts"
  "src/lib/images/hash.ts"
  "src/lib/images/orientation.ts"
  "src/app/api/patient-files/upload/route.ts"
  "src/app/patient-files/[...path]/route.ts"
  "src/lib/patient-file-upload.ts"
  "src/components/ortho/ImageTemplateBoard.tsx"
  "src/components/ortho/OrthoImageGallery.tsx"
  "src/components/ortho/OrthoChartV2.tsx"
  "src/components/ortho/OrthoAddImageGroupForm.tsx"
  "src/components/AddImageGroupForm.tsx"
  "src/components/PatientAvatar.tsx"
  "src/app/patients/[id]/billing/page.tsx"
  "src/app/patients/[id]/images/template-actions.ts"
  "src/app/patients/[id]/actions.ts"
  "src/lib/db/client.ts"
  "src/lib/db/schema.sql"
)
POST_SWAP_HASHES_FILE="$STAGE_DIR/.deploy129-expected-hashes"
: > "$POST_SWAP_HASHES_FILE"
for rel in "${POST_SWAP_VERIFY_FILES[@]}"; do
  f="$STAGE_DIR/$rel"
  [[ -f "$f" ]] || fail "Internal error: expected file missing right after extraction: $rel"
  sha256sum "$f" | awk -v rel="$rel" '{print $1, rel}' >> "$POST_SWAP_HASHES_FILE"
done

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

# --------------------------------------------------------------------------
# NEW IN 127: post-swap verification. Re-hash the live files right after the
# mv and compare to the snapshot taken right after extraction (above). Any
# mismatch means what's being served is NOT what we built/tested, and fail()
# here triggers the existing rollback trap (cleanup()) automatically, before
# systemctl start ever runs — the app is never started on files we haven't
# just confirmed are correct.
# --------------------------------------------------------------------------
echo "== verifying live files match the deployed archive (post-swap) =="
LIVE_HASHES_FILE="$APP_DIR/.deploy129-expected-hashes"
[[ -f "$LIVE_HASHES_FILE" ]] || fail "Post-swap verification snapshot did not survive the swap (.deploy129-expected-hashes missing) — aborting rather than guessing."
POST_SWAP_MISMATCH=0
while IFS= read -r line; do
  expected_hash="${line%% *}"
  rel="${line#* }"
  live_file="$APP_DIR/$rel"
  if [[ ! -f "$live_file" ]]; then
    echo "[deploy129] MISMATCH: expected file missing after swap: $rel" >&2
    POST_SWAP_MISMATCH=1
    continue
  fi
  live_hash="$(sha256sum "$live_file" | cut -d' ' -f1)"
  if [[ "$live_hash" != "$expected_hash" ]]; then
    echo "[deploy129] MISMATCH: live file does not match what was just built/tested: $rel" >&2
    POST_SWAP_MISMATCH=1
  fi
done < "$LIVE_HASHES_FILE"
rm -f "$LIVE_HASHES_FILE"
if (( POST_SWAP_MISMATCH != 0 )); then
  fail "Post-swap verification failed — the live app does not match the batch129 archive. Rolling back automatically instead of serving unverified files."
fi
grep -q "sortImagesByKind" "$APP_DIR/src/app/patients/[id]/orthodontics/page.tsx" \
  || fail "Post-swap verification failed — sortImagesByKind is missing from the LIVE orthodontics/page.tsx (this is the exact batch126 symptom). Rolling back."
echo "Post-swap verification OK — live files match the deployed archive."

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

echo "== verifying Batch 112 through 127 database changes =="
SUCCESS=0
CLINIC_DB_PATH="$APP_DIR/data/clinic.db" node - <<'NODE' \
  || fail "Batch 112-127 database verification failed."
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
const migration124 = db.prepare("SELECT 1 AS ok FROM schema_migrations WHERE name = ?").get("124_patient_image_kinds");
const imageColumns = db.prepare("PRAGMA table_info(patient_images)").all().map((column) => column.name);
if (!migration124 || !imageColumns.includes("image_kind") || !imageColumns.includes("template_slot") || !patientColumns.includes("avatar_path")) process.exit(1);
if (!migration || !["0", "1"].includes(setting?.value) || Number(tubeCells?.total) !== 8 || !orthoColumns.includes("diagnosis_summary") || !patientColumns.includes("archived_at") || !patientColumns.includes("archive_activity_at") || foreignKeys.length !== 0) process.exit(1);
// Batch 127: dedupe columns on patient_images + the corrections log table.
const migration127 = db.prepare("SELECT 1 AS ok FROM schema_migrations WHERE name = ?").get("127_patient_image_dedupe_and_corrections");
const tables = db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all().map((t) => t.name);
if (!migration127 || !imageColumns.includes("content_hash") || !imageColumns.includes("original_name") || !imageColumns.includes("file_size") || !tables.includes("patient_image_corrections")) process.exit(1);
NODE
SUCCESS=1

# Preserve backups; cleanup is a separate operator decision.
echo "Deploy completed successfully."
echo "Data backup: $BACKUP_DIR"
echo "Previous release: $PREVIOUS_DIR"
echo
echo "== Batch 129 =="
echo "Batch 129: upgrades published Batch 127; automatic/manual rotation and template lightbox updates."
echo "duplicate-photo upload detection, and manual photo-type correction + logging (log-only, no auto-learning)."
