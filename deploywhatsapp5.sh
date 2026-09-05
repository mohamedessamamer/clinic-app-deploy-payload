#!/bin/bash
# Clinic app — WhatsApp fix #5: outbound chat bubbles used an undefined
# Tailwind color (bg-brand-600) so the sent-message bubble background never
# rendered, leaving white text invisible on a white page. Switched to
# bg-emerald-600 (a real Tailwind color) so sent vs received messages are
# visibly distinct — needed for the App Review "send message" video.
set -euo pipefail

APP_DIR="/opt/clinic-app"
ARCHIVE="clinic-app-whatsapp5.tar.gz"
REPO_RAW="https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main"
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
  exit 1
fi

echo "== stopping app =="
systemctl stop clinic-app

echo "== downloading whatsapp fix#5 payload =="
cd /tmp
rm -f "$ARCHIVE"
curl --fail --location --output "$ARCHIVE" "$REPO_RAW/$ARCHIVE?cachebust=$(date +%s)"
tar -tzf "$ARCHIVE" >/dev/null

echo "== extracting source (1 file only) =="
tar -xzf "$ARCHIVE" -C "$APP_DIR"
echo "== checking file =="
grep -q "bg-emerald-600" "$APP_DIR/src/components/WhatsAppChat.tsx"

echo "== building =="
cd "$APP_DIR"
npm ci
rm -rf .next
npm run build

echo "== starting app =="
systemctl start clinic-app
sleep 2
systemctl is-active --quiet clinic-app
systemctl status clinic-app --no-pager
echo "== deploy whatsapp fix#5 completed =="
echo "جرّب تبعت رسالة من صفحة واتساب — المفروض تظهر الآن بلون أخضر واضح على اليمين."
