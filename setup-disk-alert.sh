#!/bin/bash
# سكريبت صيانة — تنبيه تلقائي لو مساحة القرص قربت تخلص. بيستخدم خدمة ntfy.sh
# المجانية (من غير أي تسجيل حساب أو إعداد إيميل/SMTP) — بتبعتلك إشعار على
# موبايلك عن طريق تطبيق ntfy المجاني (أو حتى متصفح عادي) لما نسبة استخدام
# القرص تعدي حد معيّن.
#
# إزاي تستقبل التنبيهات (خطوة واحدة، تعملها مرة واحدة بس):
#   1) نزّل تطبيق "ntfy" من متجر تطبيقات موبايلك (مجاني، أندرويد و iOS).
#   2) افتحه، دوس "+" (اشتراك في موضوع جديد)، واكتب اسم الموضوع (topic) اللي
#      هيطبعه السكريبت ده تحت بعد التشغيل.
#   3) أو بدون تطبيق خالص: افتح الرابط اللي هيطبعه السكريبت في أي متصفح
#      وسيبه مفتوح (هيوصلك إشعار فيه لايف).
#
# الافتراضي: بيفحص المساحة يوميًا الساعة 9 الصبح. تنبيه "تحذير" لو الاستخدام
# عدى 80%، وتنبيه "خطر" (أولوية عاجلة) لو عدى 90%. لو المساحة عادية مفيش أي
# إشعار بيتبعت خالص (مفيش إزعاج يومي).
#
# Run as: bash setup-disk-alert.sh
set -e

APP_DIR="/opt/clinic-app"
SCRIPT_PATH="$APP_DIR/scripts/disk-alert.sh"
TOPIC_FILE="$APP_DIR/scripts/.ntfy-topic"

mkdir -p "$APP_DIR/scripts"

# توليد اسم موضوع (topic) عشوائي طويل غير متوقع — مرة واحدة بس، وبيتحفظ
# عشان يفضل ثابت في أي تشغيل تاني للسكريبت ده. ntfy.sh مفتوح من غير حساب،
# يعني أي حد يعرف اسم الموضوع بالظبط يقدر يشوف نفس التنبيهات — عشان كده
# بنخليه عشوائي طويل صعب التخمين، مش اسم بسيط زي "clinic-disk".
if [ -f "$TOPIC_FILE" ]; then
  TOPIC=$(cat "$TOPIC_FILE")
else
  RAND=$(head -c 16 /dev/urandom | md5sum | cut -c1-12)
  TOPIC="clinic-app-disk-$RAND"
  echo "$TOPIC" > "$TOPIC_FILE"
fi

cat > "$SCRIPT_PATH" <<EOF
#!/bin/bash
TOPIC="$TOPIC"
USAGE=\$(df / --output=pcent | tail -1 | tr -dc '0-9')
if [ "\$USAGE" -ge 90 ]; then
  curl -s -H "Title: خطر - مساحة السيرفر شارفت تخلص" -H "Priority: urgent" \\
    -d "استخدام القرص وصل \${USAGE}% — النظام ممكن يوقف عن العمل. نظّف باك أب قديم (cleanup-old-backups.sh) أو زوّد المساحة دلوقتي." \\
    "https://ntfy.sh/\$TOPIC" > /dev/null
elif [ "\$USAGE" -ge 80 ]; then
  curl -s -H "Title: تنبيه - مساحة السيرفر قربت" -H "Priority: high" \\
    -d "استخدام القرص وصل \${USAGE}% — راجع المساحة قريب قبل ما توصل لمشكلة." \\
    "https://ntfy.sh/\$TOPIC" > /dev/null
fi
EOF
chmod +x "$SCRIPT_PATH"

CRON_FILE="/etc/cron.d/clinic-app-disk-alert"
CRON_LINE="0 9 * * * root bash $SCRIPT_PATH >> /var/log/clinic-app-disk-alert.log 2>&1"
if [ ! -f "$CRON_FILE" ] || ! grep -qF "$SCRIPT_PATH" "$CRON_FILE" 2>/dev/null; then
  echo "$CRON_LINE" > "$CRON_FILE"
  chmod 644 "$CRON_FILE"
fi

echo "== تم التثبيت =="
echo "موضوع التنبيهات (topic) بتاعك: $TOPIC"
echo "اشترك فيه دلوقتي من تطبيق ntfy، أو من الرابط: https://ntfy.sh/$TOPIC"
echo ""
echo "== بنبعتلك إشعار تجريبي دلوقتي عشان تتأكد إنه شغال =="
curl -s -H "Title: تجربة - إشعارات مساحة القرص شغالة" -H "Priority: default" \
  -d "لو وصلك الإشعار ده، يبقى نظام تنبيه مساحة القرص اترّكب صح. مش هيتبعتلك تاني إشعار إلا لو المساحة قربت تخلص فعلاً (80% أو أكتر)." \
  "https://ntfy.sh/$TOPIC" > /dev/null
echo "== تم إرسال إشعار تجريبي — افتح تطبيق ntfy أو الرابط فوق وشوف لو وصلك =="
echo ""
echo "الحالة الحالية لمساحة القرص:"
df -h /
