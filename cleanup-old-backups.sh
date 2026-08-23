#!/bin/bash
# سكريبت صيانة — تنظيف نسخ الباك أب القديمة (data.backup-*) اللي بيعملها كل
# سكريبت نشر (deploy*.sh) قبل ما يبدأ. من غير تنضيف، كل نشرة بتسيب نسخة كاملة
# من data/ (قاعدة البيانات + كل صور المرضى) للأبد على نفس القرص — وده بيقدر
# يستهلك مساحة القرص (40GB) بسرعة مع الوقت.
#
# الافتراضي: يحتفظ بآخر 5 نسخ باك أب بس، ويمسح الباقي. غيّر KEEP تحت لو عايز
# عدد مختلف.
#
# أول مرة تشغّله: بينظف كل النسخ المتراكمة لحد دلوقتي، وبيثبّت نفسه كمهمة
# مجدولة (cron) تتكرر أوتوماتيك كل يوم أحد الساعة 4 الفجر — من غير ما تحتاج
# تشغّله يدويًا تاني بعد كده.
#
# آمان: بيلمس بس مجلدات اسمها بالظبط "data.backup-<أرقام>" جوه /opt/clinic-app
# — مايقربش من مجلد data/ الحي (قاعدة البيانات الشغالة فعليًا) خالص.
#
# Run as: bash cleanup-old-backups.sh
set -e

KEEP=5
APP_DIR="/opt/clinic-app"
SCRIPT_PATH="$APP_DIR/scripts/cleanup-old-backups.sh"

echo "== نسخ الباك أب الموجودة حاليًا =="
mapfile -t backups < <(find "$APP_DIR" -maxdepth 1 -type d -name "data.backup-*" 2>/dev/null | sort)
total=${#backups[@]}
echo "العدد الكلي: $total (هنحتفظ بآخر $KEEP)"

if [ "$total" -le "$KEEP" ]; then
  echo "مفيش حاجة نمسحها — العدد أصلاً أقل من أو يساوي $KEEP."
else
  to_delete=("${backups[@]:0:$((total - KEEP))}")
  freed=0
  for dir in "${to_delete[@]}"; do
    # تأكيد أمان إضافي: الاسم لازم يبدأ بـ data.backup- بالظبط قبل أي مسح.
    base=$(basename "$dir")
    case "$base" in
      data.backup-*) ;;
      *) echo "-- تخطي (اسم غير متوقع): $dir"; continue ;;
    esac
    size=$(du -sm "$dir" 2>/dev/null | cut -f1)
    echo "-- مسح: $dir (${size:-?} MB)"
    rm -rf -- "$dir"
    freed=$((freed + ${size:-0}))
  done
  echo "== تم تحرير حوالي ${freed} MB =="
fi

echo ""
echo "== باقي مساحة القرص =="
df -h /

# تثبيت السكريبت نفسه كمهمة أسبوعية (idempotent — آمن لو اتكرر تشغيله)
mkdir -p "$APP_DIR/scripts"
cp -f "$0" "$SCRIPT_PATH"
chmod +x "$SCRIPT_PATH"
CRON_FILE="/etc/cron.d/clinic-app-backup-cleanup"
CRON_LINE="0 4 * * 0 root bash $SCRIPT_PATH >> /var/log/clinic-app-backup-cleanup.log 2>&1"
if [ ! -f "$CRON_FILE" ] || ! grep -qF "$SCRIPT_PATH" "$CRON_FILE" 2>/dev/null; then
  echo "$CRON_LINE" > "$CRON_FILE"
  chmod 644 "$CRON_FILE"
  echo ""
  echo "== تم جدولة التنظيف ده يتكرر تلقائيًا كل يوم أحد الساعة 4 الفجر =="
else
  echo ""
  echo "== المهمة المجدولة موجودة بالفعل — مفيش حاجة تتضاف =="
fi
