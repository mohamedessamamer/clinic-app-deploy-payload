#!/bin/bash
# Deploy script for clinic-app — batch 28 (يشمل كل حاجة من دفعة 27 كمان، لأنه
# بيشحن شجرة src/ الكاملة الحالية — آمن يتنفذ بغض النظر عن آخر نسخة شغالة
# فعليًا على السيرفر، وبيغطي أي دفعة سابقة لسه ما اتنشرتش).
#
# دفعة 28 — 7 مشاكل من استخدام حقيقي على السيرفر الحي بعد نشر دفعة 27:
#
#   1. الكاليندر فوق الجدول: انتقال smooth بين الأيام (Form بدل form عادي،
#      بدون full page reload).
#   2+4. باج جذري: السيرفر بيحسب "النهاردة" بتوقيت UTC مش توقيت القاهرة —
#      عمود جديد src/lib/clinic-date.ts (getClinicToday عن طريق Intl مع
#      timeZone Africa/Cairo) بدل كل استخدامات new Date().toISOString() في
#      16 ملف. ده كان السبب في: المرضى مش بيظهروا في الجدول بعد نص الليل
#      لحد ما تدوس "هوم"، ومزامنة المعالجة من شارت التقويم للملف الطبي +
#      رسالة "محتاج إدخال معالجة" مكناش بيشتغلوا صح بسبب اختلاف التواريخ.
#   3. شيل الرصيد المالي من بانر "متابعة" في الملف الطبي وشارت التقويم —
#      فصل كامل، السياق دلوقتي اسم الخدمة بس من غير أي مبلغ.
#   5. الحجز بعد اختصار "إضافة خدمة للتحصيل" بقى بيظهر في الجدول فورًا —
#      await + router.refresh() بعد كل server action، واختصار "افتح خدمة
#      للتحصيل دلوقتي" بقى بيخبي بوكس الحجز مؤقتًا بدل ما يقفله ويمسح
#      اختياراته.
#   7. لون البراكيت "Bonded" رجع للأزرق الأصلي (كان اتغيّر لفضي في دفعة 27).
#
#   بند 6 (الدكتور يشوف "محتاج تحصيل") مؤجل بطلب المستخدم — مفيش كود ليه في
#   الدفعة دي.
#
#   كل بند اتفحص فعليًا بمتصفح آلي (Playwright) + فحص مباشر لقاعدة البيانات
#   بعد كل خطوة (مش تحليل كود بس)، وبيانات الاختبار اتنضفت بالكامل بعدها.
#   تفاصيل كاملة في batch28-bugfixes.md. مفيش أي تغيير في هيكل قاعدة
#   البيانات (schema) في الدفعة دي — مفيش migration جديدة.
#
# Run as: bash deploy28.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch28.tar.gz
curl -L -o clinic-app-batch28.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch28.tar.gz?cachebust=$(date +%s)"

echo "== extracting update (full src/ tree — overwrites in place) =="
tar -xzf clinic-app-batch28.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "purpose_linked_invoice_id" /opt/clinic-app/src/lib/db/types.ts 2>/dev/null \
  && grep -q "getPatientOpenServicesForPurposeAction" /opt/clinic-app/src/app/appointments/billing-actions.ts 2>/dev/null \
  && grep -q "renderPurposePicker" /opt/clinic-app/src/components/CentralSchedule.tsx 2>/dev/null \
  && grep -q "getTodayPurposeContext" /opt/clinic-app/src/lib/purpose-context.ts 2>/dev/null \
  && grep -q "getClinicToday" /opt/clinic-app/src/lib/clinic-date.ts 2>/dev/null \
  && grep -q "hideForQuickAdd" /opt/clinic-app/src/components/CentralSchedule.tsx 2>/dev/null \
  && grep -q "bg-blue-500 border-blue-700" /opt/clinic-app/src/components/ortho/InteractiveToothChart.tsx 2>/dev/null; then
  echo "OK: batch 27 + batch 28 code landed."
else
  echo "PROBLEM: the new code did not land correctly, or an OLD/stale version was served."
  echo "GitHub may still be serving an old clinic-app-batch28.tar.gz - go re-upload it"
  echo "(overwrite, exact same filename), wait a minute, then run this again."
  systemctl start clinic-app
  exit 1
fi

echo "== installing dependencies =="
cd /opt/clinic-app
npm install

echo "== clearing old build cache =="
rm -rf .next

echo "== rebuilding app (next start serves a pre-built .next - without this step the new"
echo "   source files sit on disk but next start keeps serving the OLD compiled build) =="
npm run build

echo "== starting app =="
systemctl start clinic-app

sleep 2
echo "== status =="
systemctl status clinic-app --no-pager
