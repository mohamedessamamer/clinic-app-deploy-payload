#!/bin/bash
# Deploy script for clinic-app — batch 27 (round 4).
# Ships the FULL current src/ tree, so it's safe regardless of exactly which
# prior batches already ran on this server (re-ships all prior batches too,
# harmless if already applied). No new npm dependencies in this round, so
# only src/ is shipped (same as batch 20-26).
#
# دفعة 27 — أول نشر لكل حاجة اتعملت من آخر نشر (round 3 / دفعة 26) لحد دلوقتي:
#
#   Phase 1 (إصلاحات سريعة): إصلاح باج المخزون الحقيقي (teeth array)، تنبيه
#   6 شهور جوه شارت التقويم، صلاحية "رفع صور فقط" للاستقبال، تخطيط صف
#   المتابعة على الموبايل، لون البراكيت سيلفر، bulk download/delete للصور،
#   حذف زيارة متابعة كاملة مع تراجع خصم المخزون.
#
#   Phase 2: تقييد قائمة الدكتور المساعد بالموعد (استشاري/غير استشاري)،
#   الشفت الاستثنائي (doctor_date_shifts + ExceptionalShiftButton)، شيل
#   الطبيب المساعد من عرض الملف المالي، مزامنة تفاصيل المعالجة من شارت
#   التقويم للملف الطبي + تنبيه "رجاء إدخال معالجة" (صلاحية جديدة
#   view_needs_treatment_reminder).
#
#   P3.1: بوكس "إضافة خدمة للتحصيل" السريع (right-click على اسم المريض في
#   الجدول المركزي) — مستقل عن أي موعد، بصلاحيتين جداد (canQuickAddService/
#   canBackdateInvoice مبنيين على صلاحيات موجودة بالفعل).
#
#   P3.2: قائمة "المريض جاي يعمل إيه" (Purpose) الجديدة بالكامل — عمود جديد
#   appointments.purpose_linked_invoice_id بيربط الموعد بفاتورة مفتوحة فعلية
#   (تقويم/عام)، أزرار سريعة مفلترة بالفئة + بحث حر، اختصار مباشر لبوكس P3.1
#   لو مفيش خدمة مفتوحة أصلاً، auto-fill لبوكس التحصيل ("تم") من الربط ده،
#   وبانرات سياق للدكتور (الملف الطبي وشارت التقويم) بالرصيد المتبقي.
#
#   كل بند اتفحص محليًا بالكامل (Playwright + فحص قاعدة بيانات مباشر +
#   npx tsc --noEmit + npm run build) وبيانات الاختبار اتنضفت بعد كل فحص —
#   تفاصيل كل بند وأي باجات اتكتشفت واتصلحت أثناء الفحص موثقة في
#   batch27-followup-backlog-triage.md.
#
# Run as: bash deploy27.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch27.tar.gz
curl -L -o clinic-app-batch27.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch27.tar.gz?cachebust=$(date +%s)"

echo "== extracting update (full src/ tree — overwrites in place) =="
tar -xzf clinic-app-batch27.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "purpose_linked_invoice_id" /opt/clinic-app/src/lib/db/types.ts 2>/dev/null && grep -q "getPatientOpenServicesForPurposeAction" /opt/clinic-app/src/app/appointments/billing-actions.ts 2>/dev/null && grep -q "renderPurposePicker" /opt/clinic-app/src/components/CentralSchedule.tsx 2>/dev/null && grep -q "getTodayPurposeContext" /opt/clinic-app/src/lib/purpose-context.ts 2>/dev/null && grep -q "doctor_date_shifts" /opt/clinic-app/src/lib/db/client.ts 2>/dev/null; then
  echo "OK: batch 27 code (Phase 1 + Phase 2 + P3.1 + P3.2) landed."
else
  echo "PROBLEM: the new code did not land correctly, or an OLD/stale version was served."
  echo "GitHub may still be serving an old clinic-app-batch27.tar.gz - go re-upload it"
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
