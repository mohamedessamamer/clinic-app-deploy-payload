#!/bin/bash
# Deploy script for clinic-app — batch 21. Ships the FULL current src/ tree
# as one package (not an incremental diff), so it's safe regardless of
# exactly which files changed since the last deploy — this also covers
# batch 20 (add-service-form-in-billing-page, new header) in case that
# deploy hadn't actually been run yet on this server.
#
# Batch 21 — ستة بنود:
#   1. تنقل السيستم كله بقى في تاب واحد — الروابط اللي كانت بتفتح تاب جديد
#      (اسم المريض في أي مكان: الجدول المركزي، صفحة المرضى، الملف الطبي) بقت
#      بتفتح في نفس التاب. اتشال زرار "فتح الملف (تبويب جديد)" الزائد من صفحة
#      المرضى.
#   2. إصلاح باج: رابطين كانوا بيفتحوا الملف الطبي لكل الأدوار بدل الملف
#      المالي (قايمة المرضى، وزرار "فتح الملف" في نتيجة البحث بالجدول
#      المركزي) — دلوقتي بيتبعوا نفس قاعدة "الدكتور بيفتح الملف الطبي، أي حد
#      تاني بيفتح الملف المالي" المطبقة في باقي السيستم من دفعة 8.
#   3. أضيفت 4 فهارس (indexes) على قاعدة البيانات كانت ناقصة على أعمدة
#      بتتفلتر/تتربط عليها كتير (invoices.visit_id، invoices.parent_invoice_id،
#      appointments(patient_id, status)، visits.appointment_id) — بتتطبق
#      تلقائيًا عند تشغيل السيرفر (idempotent)، مفيش خطوة إضافية مطلوبة.
#   4. عدادات الخدمات فوق جدول الفواتير في الملف المالي لكل مريض: "الخدمات"/
#      "الخدمات المنتهية"/"الخدمات الجارية".
#   5. إعادة تصميم "الموعد المعلّق محتاج تحصيل" بالكامل: كارت مستقل جديد
#      (تحصيل معلّق) بيعرض تاريخ الموعد + اسم الدكتور + الخدمة والسعر المتوقع
#      لو الدكتور حددهم، وبيتيح تحصيل كامل أو جزئي. مستقل تمامًا عن بوكس
#      "إضافة خدمة جديدة" تحته — إصلاح باج حقيقي: قبل كده أي خدمة جديدة (حتى
#      لو مالهاش علاقة بالموعد المعلّق) كانت بتقفل الموعد المعلّق القديم
#      تلقائيًا وتضيع تفاصيله من غير تحصيل فعلي.
#   6. خاصية حذف فاتورة/خدمة اتسجلت غلط — من صفحة "الفواتير" ومن الملف المالي
#      لكل مريض، محصورة بصلاحية delete_visits (الأدمن بس افتراضيًا).
#
#   Verified locally: tsc --noEmit clean, next build clean, smoke-tested all
#   key pages (front-desk, patients, invoices, patient billing, settings)
#   across admin/reception/doctor roles with no runtime errors — full
#   Playwright regression suite intentionally deferred per user request.
#
# Run as: bash deploy21.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch21.tar.gz
curl -L -o clinic-app-batch21.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch21.tar.gz?cachebust=$(date +%s)"

echo "== extracting update (full src/ tree — overwrites in place) =="
tar -xzf clinic-app-batch21.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "PendingCollectionCard" /opt/clinic-app/src/app/patients/\[id\]/billing/page.tsx 2>/dev/null && grep -q "DeleteInvoiceButton" /opt/clinic-app/src/components/InvoiceRow.tsx 2>/dev/null; then
  echo "OK: batch 21 code (pending-collection card + delete-invoice button) landed."
else
  echo "PROBLEM: the new code did not land correctly."
  echo "GitHub may still be serving an old clinic-app-batch21.tar.gz - go re-upload it"
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
