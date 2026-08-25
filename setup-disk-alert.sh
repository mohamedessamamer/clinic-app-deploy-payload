#!/bin/bash
# سكريبت صيانة — تنبيه تلقائي على الإيميل لو مساحة القرص قربت تخلص.
#
# الإصدار ده بيبعت الإيميل مباشرة من حساب Gmail بتاعك (smtp.gmail.com) —
# مش عن طريق خدمة طرف تالت زي المحاولة الأولى (ntfy.sh رفضت الإرسال لأنها
# بتمنع الإيميلات من حسابات مجهولة من غير اشتراك مدفوع عندهم). الطريقة دي
# أوثق وأبسط: إيميلك بيبعت لنفسه، مفيش وسيط.
#
# قبل ما تشغّل السكريبت ده، خطوتين على حساب Google بتاعك (مرة واحدة بس):
#   1) فعّل "التحقق بخطوتين" لو مش مفعّل أصلاً:
#      https://myaccount.google.com/security
#   2) اعمل "App Password" (كلمة سر تطبيق مخصصة، مش كلمة سر Gmail العادية):
#      https://myaccount.google.com/apppasswords
#      اختار اسم زي "clinic-server"، واحفظ الكود المكوّن من 16 حرف اللي هيطلعلك.
#      (ده آمن — كلمة سر مخصصة للاستخدام ده بس، تقدر تسحبها في أي وقت من غير
#      ما تأثر على حسابك الأساسي أو أي حاجة تانية).
#
# لما يبقى معاك الكود ده، شغّل السكريبت — هيطلب منك تلصقه في نفس الترمينال.
# الكود ده بيتكتب على السيرفر نفسه بس (مش بيتبعت لأي حد تاني).
#
# Run as: bash setup-disk-alert.sh [email]
set -e

EMAIL="${1:-mohamedessamamer@gmail.com}"
APP_DIR="/opt/clinic-app"
SCRIPT_PATH="$APP_DIR/scripts/disk-alert.sh"

mkdir -p "$APP_DIR/scripts"

echo "== تثبيت msmtp (عميل إرسال إيميل خفيف) =="
apt-get update -qq
apt-get install -y msmtp ca-certificates >/dev/null

echo ""
echo "ملحوظة: ترمينال Hetzner Console معروف إنه أحيانًا بيبهدل النصوص الملصوقة الطويلة"
echo "(بيحذف حروف منها من غير ما تلاحظ). عشان كده هنعرضلك الكود اللي اتلصق فعليًا"
echo "بعد ما تلصقه، تتأكد إنه سليم قبل ما نكمل — مش هيتبعت لأي حد، بيتكتب على"
echo "السيرفر نفسه بس."
echo ""
while true; do
  echo "الصق الـ App Password اللي عملته من https://myaccount.google.com/apppasswords واضغط Enter:"
  echo "(ينفع تلصقه بالمسافات اللي جوجل بيوريهولك بيها — هننضفها تلقائي)"
  read -r APP_PASSWORD_RAW
  APP_PASSWORD="${APP_PASSWORD_RAW// /}"

  if [ -z "$APP_PASSWORD" ]; then
    echo "== مفيش حاجة اتلصقت — جرب تاني، أو دوس Ctrl+C للإلغاء =="
    echo ""
    continue
  fi

  echo "اللي اتلصق فعليًا (${#APP_PASSWORD} حرف بعد شيل المسافات): $APP_PASSWORD"
  if [ "${#APP_PASSWORD}" -ne 16 ]; then
    echo "== تحذير: الطول المفروض يكون 16 حرف بالظبط. ده ${#APP_PASSWORD} — يبقى فيه حروف ناقصة أو زيادة."
    echo "   راجع الكود في صفحة جوجل وجرب تلصقه تاني =="
    echo ""
    continue
  fi

  echo "شكله سليم (16 حرف). اضغط Enter للتأكيد والمتابعة، أو Ctrl+C لو عايز تلصقه تاني."
  read -r _confirm
  break
done

cat > /etc/msmtprc <<EOF
defaults
auth on
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt

account clinic-alert
host smtp.gmail.com
port 587
from $EMAIL
user $EMAIL
password $APP_PASSWORD

account default : clinic-alert
EOF
chmod 600 /etc/msmtprc

cat > "$SCRIPT_PATH" <<EOF
#!/bin/bash
EMAIL="$EMAIL"
USAGE=\$(df / --output=pcent | tail -1 | tr -dc '0-9')
send_mail() {
  printf "Subject: %s\nTo: %s\n\n%s\n" "\$1" "\$EMAIL" "\$2" | msmtp "\$EMAIL"
}
if [ "\$USAGE" -ge 90 ]; then
  send_mail "خطر - مساحة سيرفر عيادتي شارفت تخلص (\${USAGE}%)" "استخدام القرص وصل \${USAGE}% — النظام ممكن يوقف عن العمل. نظّف باك أب قديم (cleanup-old-backups.sh) أو زوّد المساحة دلوقتي."
elif [ "\$USAGE" -ge 80 ]; then
  send_mail "تنبيه - مساحة سيرفر عيادتي قربت (\${USAGE}%)" "استخدام القرص وصل \${USAGE}% — راجع المساحة قريب قبل ما توصل لمشكلة."
fi
EOF
chmod +x "$SCRIPT_PATH"

CRON_FILE="/etc/cron.d/clinic-app-disk-alert"
CRON_LINE="0 9 * * * root bash $SCRIPT_PATH >> /var/log/clinic-app-disk-alert.log 2>&1"
if [ ! -f "$CRON_FILE" ] || ! grep -qF "$SCRIPT_PATH" "$CRON_FILE" 2>/dev/null; then
  echo "$CRON_LINE" > "$CRON_FILE"
  chmod 644 "$CRON_FILE"
fi

echo "== تم التثبيت — بنبعتلك إيميل تجريبي دلوقتي =="
if printf "Subject: تجربة - إشعارات مساحة القرص شغالة\nTo: %s\n\nلو وصلك الإيميل ده، يبقى نظام تنبيه مساحة القرص اترّكب صح. مش هيتبعتلك تاني إلا لو المساحة قربت تخلص فعلاً (80%% أو أكتر).\n" "$EMAIL" | msmtp "$EMAIL"; then
  echo "== تم إرسال الإيميل التجريبي بنجاح — راجع بريدك (وصندوق السبام لو مش لاقيه) =="
else
  echo "== فيه مشكلة في الإرسال — تأكد إن الـ App Password اتنسخ صح (16 حرف من غير مسافات) وشغّل السكريبت تاني =="
fi

echo ""
echo "الحالة الحالية لمساحة القرص:"
df -h /
