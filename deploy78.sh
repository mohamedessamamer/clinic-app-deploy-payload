#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/clinic-app"
SERVICE_NAME="clinic-app"
ARCHIVE="clinic-app-batch78.tar.gz"
ARCHIVE_SHA256="D7A35D317D3B404B520C80D8515F4896697BFFF27AF192DDD1E589FF37AB65DD"
REPO_RAW="https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-http://127.0.0.1:3000/login}"
STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_DIR="/opt/clinic-app-data.backup-batch78-$STAMP"
PREVIOUS_DIR="/opt/clinic-app.previous-batch78-$STAMP"
FAILED_DIR="/opt/clinic-app.failed-batch78-$STAMP"
TEMP_DIR="$(mktemp -d /tmp/clinic-app-batch78-deploy.XXXXXX)"
STAGE_DIR="$(mktemp -d /opt/clinic-app.release.XXXXXX)"
APP_STOPPED=0
OLD_MOVED=0
NEW_MOVED=0
DATA_MOVED=0
SUCCESS=0

cleanup() {
  local status=$?
  trap - EXIT

  if (( status != 0 && SUCCESS == 0 )); then
    echo "Deploy failed; restoring the previous release." >&2
    if (( APP_STOPPED == 1 || NEW_MOVED == 1 )); then
      systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    if (( NEW_MOVED == 1 )) && [[ -d "$APP_DIR" ]]; then
      mv "$APP_DIR" "$FAILED_DIR" || true
    fi
    if (( DATA_MOVED == 1 )) && [[ -d "$FAILED_DIR/data" ]] && [[ -d "$PREVIOUS_DIR" ]]; then
      mv "$FAILED_DIR/data" "$PREVIOUS_DIR/data" || true
    fi
    if (( OLD_MOVED == 1 )) && [[ -d "$PREVIOUS_DIR" ]] && [[ ! -e "$APP_DIR" ]]; then
      mv "$PREVIOUS_DIR" "$APP_DIR" || true
    fi
    if (( APP_STOPPED == 1 || OLD_MOVED == 1 )); then
      systemctl start "$SERVICE_NAME" || true
    fi
  fi

  if [[ -d "$TEMP_DIR" && "$TEMP_DIR" == /tmp/clinic-app-batch78-deploy.* ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
  if [[ -d "$STAGE_DIR" && "$STAGE_DIR" == /opt/clinic-app.release.* ]]; then
    rm -rf -- "$STAGE_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

for command in curl sha256sum tar npm systemctl; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

[[ -d "$APP_DIR/data" ]] || {
  echo "Missing persistent data directory: $APP_DIR/data" >&2
  exit 1
}

if [[ -f "$APP_DIR/.env.production.local" ]]; then
  ENV_FILE="$APP_DIR/.env.production.local"
  ENV_NAME=".env.production.local"
elif [[ -f "$APP_DIR/.env.production" ]]; then
  ENV_FILE="$APP_DIR/.env.production"
  ENV_NAME=".env.production"
else
  echo "Missing .env.production.local or .env.production in $APP_DIR" >&2
  exit 1
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
  grep -Eq "^${key}=.+$" "$ENV_FILE" || {
    echo "Missing or empty environment variable: $key in $ENV_FILE" >&2
    exit 1
  }
done

if ! command -v make >/dev/null 2>&1; then
  apt-get update
  apt-get install -y build-essential
fi

echo "== downloading and verifying release =="
curl --fail --location --output "$TEMP_DIR/$ARCHIVE" "$REPO_RAW/$ARCHIVE?cachebust=$(date +%s)"
printf '%s  %s\n' "$ARCHIVE_SHA256" "$TEMP_DIR/$ARCHIVE" | sha256sum --check --status

if tar -tzf "$TEMP_DIR/$ARCHIVE" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  echo "Archive contains an unsafe path." >&2
  exit 1
fi

tar -xzf "$TEMP_DIR/$ARCHIVE" -C "$STAGE_DIR"
test -f "$STAGE_DIR/package-lock.json"
test -f "$STAGE_DIR/src/app/attendance-queue/actions.ts"
test -f "$STAGE_DIR/src/components/AttendanceQueue.tsx"
test -f "$STAGE_DIR/src/components/ChatSoundPicker.tsx"
test -f "$STAGE_DIR/src/components/WhatsAppTomorrowSender.tsx"
test -f "$STAGE_DIR/src/app/appointment/manage/[token]/page.tsx"
test -f "$STAGE_DIR/src/app/appointment-reminders/report-actions.ts"
test -f "$STAGE_DIR/src/app/api/whatsapp/webhook/route.ts"
test -f "$STAGE_DIR/src/instrumentation.ts"
test ! -e "$STAGE_DIR/.env.production"
test ! -e "$STAGE_DIR/.env.production.local"
test ! -e "$STAGE_DIR/data"
cp -a "$ENV_FILE" "$STAGE_DIR/$ENV_NAME"

echo "== installing and building in staging =="
cd "$STAGE_DIR"
npm ci
mkdir -p "$STAGE_DIR/.build"
CLINIC_DB_PATH="$STAGE_DIR/.build/clinic.db" npm run build
rm -rf -- "$STAGE_DIR/.build"

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

for _ in {1..15}; do
  if systemctl is-active --quiet "$SERVICE_NAME" && curl --fail --silent --show-error --output /dev/null "$HEALTHCHECK_URL"; then
    SUCCESS=1
    break
  fi
  sleep 2
done

(( SUCCESS == 1 )) || {
  echo "Health check failed: $HEALTHCHECK_URL" >&2
  exit 1
}

echo "Deploy completed successfully."
echo "Data backup: $BACKUP_DIR"
echo "Previous release: $PREVIOUS_DIR"
