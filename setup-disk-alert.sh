#!/bin/bash
# سكريبت صيانة — تنبيه تلقائي على الإيميل لو مساحة القرص قربت تخلص.
#
# بيستخدم خدمة ntfy.sh المجانية بس كـ"ساعي بريد" بس — من غير أي تسجيل حساب
# أو إعداد SMTP بتاعك — وبيطلب منها توصّل التنبيه لإيميلك مباشرة (خاصية
# مدمجة في ntfy.sh نفسها، مش سيرفر إيميل منفصل). يعني النتيجة النهائية:
# إيميل عادي بيوصلك في بريدك زي أي إيميل تاني، من غير ما تحتاج تنزّل أي
# تطبيق أو تفهم حاجة تقنية جديدة.
#
# الإيميل الافتراضي المستخدم هنا: mohamedessamamer@gmail.com (إيميل حسابك).
# لو عايز إيميل مختلف (مثلاً إيميل مخصص للعيادة)، شغّل السكريبت وبعده مسافة
# الإيميل المطلوب، مثال:
#   bash setup-disk-alert.sh clinic-admin@example.com
#
# الافتراضي: بيفحص المساحة يوميًا الساعة 9 الصبح. إيميل "تحذير" لو الاستخدام
# عدى 80%، وإيميل "خطر" لو عدى 90%. لو المساحة عادية مفيش أي إيميل بيتبعت
# خالص (مفيش إزعاج يومي).
#
# Run as: bash setup-disk-alert.sh [email]
set -e

EMAIL="${1:-mohamedessamamer@gmail.com}"
APP_DIR="/opt/clinic-app"
SCRIPT_PATH="$APP_DIR/scripts/disk-alert.sh"
TOPIC_FILE="$APP_DIR/scripts/.ntfy-topic"

mkdir -p "$APP_DIR/scripts"

# توليد اسم موضوع (topic) عشوائي طويل غير متوقع — مرة واحدة بس، وبيتحفظ عشان
# يفضل ثابت في أي تشغيل تاني للسكريبت ده. مش مهم تحفظه أو تستخدمه بنفسك —
# هو بس وسيط داخلي بين السيرفر وخدمة ntfy.sh، والتنبيه الفعلي بيوصلك إيميل.
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
EMAIL="$EMAIL"
USAGE=\$(df / --output=pcent | tail -1 | tr -dc '0-9')
if [ "\$USAGE" -ge 90 ]; then
  curl -s -H "Title: خطر - مساحة سيرفر عيادتي شارفت تخلص" -H "Priority: urgent" -H "Email: \$EMAIL" \\
    -d "استخدام القرص وصل \${USAGE}% — النظام ممكن يوقف عن العمل. نظّف باك أب قديم (cleanup-old-backups.sh) أو زوّد المساحة دلوقتي." \\
    "https://ntfy.sh/\$TOPIC" > /dev/null
elif [ "\$USAGE" -ge 80 ]; then
  curl -s -H "Title: تنبيه - مساحة سيرفر عيادتي قربت" -H "Priority: high" -H "Email: \$EMAIL" \\
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
echo "الإيميل اللي هيوصله التنبيه: $EMAIL"
echo ""
echo "== بنبعتلك إيميل تجريبي دلوقتي عشان تتأكد إنه شغال (راجع الإيميل، وممكن يوصل صندوق سبام أول مرة) =="
curl -s -H "Title: تجربة - إشعارات مساحة القرص شغالة" -H "Priority: default" -H "Email: $EMAIL" \
  -d "لو وصلك الإيميل ده، يبقى نظام تنبيه مساحة القرص اترّكب صح. مش هيتبعتلك تاني إلا لو المساحة قربت تخلص فعلاً (80% أو أكتر)." \
  "https://ntfy.sh/$TOPIC" > /dev/null
echo "== تم إرسال الإيميل التجريبي — راجع بريدك (وصندوق السبام لو مش لاقيه) =="
echo ""
echo "الحالة الحالية لمساحة القرص:"
df -h /
