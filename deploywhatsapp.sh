#!/bin/bash
# Clinic app — WhatsApp Cloud API integration (webhook + Embedded Signup +
# conversations page + message templates).
set -euo pipefail

APP_DIR="/opt/clinic-app"
ARCHIVE="clinic-app-whatsapp.tar.gz"
REPO_RAW="https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main"
BACKUP_DIR="/opt/clinic-app/data.backup-whatsapp-$(date +%Y%m%d%H%M%S)"
ENV_FILE="$APP_DIR/.env.production"

echo "== checking required WhatsApp env vars in $ENV_FILE =="
MISSING=0
for VAR in WHATSAPP_APP_ID WHATSAPP_APP_SECRET WHATSAPP_CONFIG_ID WHATSAPP_WEBHOOK_VERIFY_TOKEN WHATSAPP_TOKEN_ENC_KEY NEXT_PUBLIC_WHATSAPP_APP_ID NEXT_PUBLIC_WHATSAPP_CONFIG_ID; do
  if ! grep -q "^${VAR}=.\+" "$ENV_FILE" 2>/dev/null; then
    echo "  MISSING: $VAR"
    MISSING=1
  fi
done
if [ "$MISSING" -eq 1 ]; then
  echo ""
  echo "متغيرات بيئة واتساب ناقصة في $ENV_FILE — الديبلوي اتوقف قبل ما يلمس أي حاجة."
  echo "ضيفهم من .env.whatsapp.example (جوه الأرشيف بعد فك الضغط، أو من docs/WHATSAPP_INTEGRATION.md)"
  echo "ثم شغّل السكريبت ده تاني."
  exit 1
fi

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

echo "== downloading whatsapp payload =="
cd /tmp
rm -f "$ARCHIVE"
curl --fail --location --output "$ARCHIVE" "$REPO_RAW/$ARCHIVE?cachebust=$(date +%s)"
tar -tzf "$ARCHIVE" >/dev/null

echo "== extracting source =="
tar -xzf "$ARCHIVE" -C "$APP_DIR"
echo "== checking whatsapp files =="
test -f "$APP_DIR/src/app/api/whatsapp/webhook/route.ts"
test -f "$APP_DIR/src/app/whatsapp/page.tsx"
test -f "$APP_DIR/src/lib/whatsapp/crypto.ts"
grep -q "manage_whatsapp" "$APP_DIR/src/lib/permission-defs.ts"
grep -q "whatsapp_accounts" "$APP_DIR/src/lib/db/schema.sql"
grep -q "api/whatsapp/webhook" "$APP_DIR/src/proxy.ts"

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
echo "== deploy whatsapp completed =="
echo "Database backup: $BACKUP_DIR"
echo "افتح https://clinicsys.revereeg.com/whatsapp بحساب أدمن وابدأ الربط."
