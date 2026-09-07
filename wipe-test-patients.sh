#!/bin/bash
# سكريبت صيانة لمرة واحدة — بيمسح كل بيانات المرضى (الملفات الطبية والمالية:
# المرضى + الزيارات + الفواتير + المواعيد + مجموعات الصور والصور نفسها من على
# القرص) من قاعدة البيانات الحية، من غير ما يلمس أي كود أو إعدادات أو وظيفة في
# التطبيق. الأطباء، المستخدمين والصلاحيات، الخدمات، العيادات/الغرف، الشيفتات،
# والإعدادات كلها بتفضل زي ما هي بالظبط.
#
# آمان:
#   1) بياخد باك أب كامل لمجلد data/ قبل أي حذف.
#   2) بيوقف التطبيق الأول (عشان مفيش كتابة على القاعدة أثناء الحذف).
#   3) السكريبت الداخلي (wipe-test-patients.cjs) بيعرض قايمة المرضى والأعداد
#      اللي هتتمسح، وبيطلب منك تكتب "امسح" بالظبط في الكونسول عشان يكمّل —
#      أي حاجة تانية (أو Enter فاضي) بتلغي العملية من غير ما يتمسح حاجة.
#
# الاستخدام: bash wipe-test-patients.sh
set -e

cd /opt/clinic-app

echo "== باك أب كامل لمجلد data/ قبل أي حذف =="
cp -r data "data.backup-before-wipe-$(date +%Y%m%d%H%M%S)"

echo "== تنزيل سكريبت الحذف (cache-busted) =="
curl -sL "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/wipe-test-patients.cjs?cachebust=$(date +%s)" -o wipe-test-patients.cjs

echo "== إيقاف التطبيق =="
systemctl stop clinic-app

echo "== تشغيل سكريبت الحذف (هيسألك تأكيد قبل ما يمسح أي حاجة فعليًا) =="
node wipe-test-patients.cjs --confirm

echo "== تشغيل التطبيق تاني =="
systemctl start clinic-app

sleep 2
echo "== الحالة =="
systemctl status clinic-app --no-pager
