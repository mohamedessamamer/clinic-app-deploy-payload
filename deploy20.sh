#!/bin/bash
# Deploy script for clinic-app — batch 20, bundled together with batches 18
# and 19 (neither was ever deployed on its own — all three ship together
# here on top of batches 11-17, which are already live on the server). Ships
# the FULL current src/ tree as one package (not an incremental diff), so
# it's safe regardless of exactly which files changed since the last deploy.
# This package ALSO includes package.json + package-lock.json (same as
# batch 19's corrected package) because exceljs (added in batch 18, used by
# /reports/export) is still a dependency and must be installed on the server.
#
# Batch 18 — ثمانية بنود: كلمة سر افتراضية "123"، تصدير Excel للتقارير،
#   حجب الملف المالي عن الدكتور افتراضيًا (+ إغلاق ثغرتي أمان في الملف المالي
#   والمخزون)، بحث substring بكل مكان، سن من تاريخ الميلاد، تسمية "المخزن"،
#   قفل تقرير الدكتور بشهرين.
#
# Batch 19 — تحسينات موبايل/تابلت + تصميم 3D: بحث substring في بوكس "إضافة
#   خدمة"، دوسة طويلة = زر يمين بالجدول المركزي، ترتيب ثابت للقايمة العلوية،
#   تسمية "الاستقبال"، نظام تصميم 3D شامل على كل الصفحات.
#
# Batch 20 — سبعة بنود:
#   1. بوكس "إضافة خدمة" اتشال من تحت الجدول (front-desk) بالكامل، ونُقل جوه
#      الملف المالي لكل مريض (/patients/[id]/billing) — إصلاح باج حقيقي: حقل
#      "المبلغ المدفوع دلوقتي" كان ناقص خالص، فكل خدمة كانت بتتسجل paid=0.
#      البوكس الجديد فيه بحث اسم+كود للخدمة، ربط تلقائي بموعد "تم" معلّق، ودعم
#      دفعات "متابعة" على فواتير سابقة.
#   2. الهيدر: شعار "عيادتي" بأيقونة قلب، زرار خروج بأيقونة، واسم الحساب بقى
#      قايمة منسدلة فيها "تغيير كلمة السر".
#   3. صلاحية تصفير كلمة سر أي مستخدم (أدمن بس) لكلمة السر الافتراضية "123".
#   4. منع الاستقبال من تسجيل خدمة/تحصيل بتاريخ غير النهاردة (نفس صلاحية
#      edit_invoice_payments الموجودة، بدون صلاحية جديدة).
#   5. تحسين نص شرح إدخال تاريخ الميلاد (الحقل والمنطق زي ما هم).
#   6. إعادة تصميم صفحة "الفواتير" بالكامل: ترتيب أعمدة جديد (المريض/الخدمة/
#      السعر بعد الخصم مع تلميح نسبة الخصم/المدفوع/المتبقي/طريقة الدفع/
#      الدكتور)، فلاتر دكتور وطريقة دفع، وتعديل بالدوسة على الرقم بدل عمود
#      تعديل منفصل.
#   7. تحديث نص صلاحية view_invoice_totals — بقت بس بتتحكم في إجماليات اليوم
#      وتقرير تعديلات اليوم، مش تفاصيل كل فاتورة على حدة (تفاصيل السعر/
#      المدفوع/المتبقي بقت ظاهرة للاستقبال في كل فاتورة).
#
#   Verified locally end to end (tsc + next build + 27 Playwright checks
#   across 3 scripts + visual screenshot review of the header).
#
# Run as: bash deploy20.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch20.tar.gz
curl -L -o clinic-app-batch20.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch20.tar.gz?cachebust=$(date +%s)"

echo "== extracting update (full src/ tree — overwrites in place) =="
tar -xzf clinic-app-batch20.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "AddPatientServiceForm" /opt/clinic-app/src/app/patients/\[id\]/billing/page.tsx 2>/dev/null && grep -q "AccountMenu" /opt/clinic-app/src/components/NavBar.tsx 2>/dev/null; then
  echo "OK: batch 20 code (patient-billing add-service form + new header) landed."
else
  echo "PROBLEM: the new code did not land correctly."
  echo "GitHub may still be serving an old clinic-app-batch20.tar.gz - go re-upload it"
  echo "(overwrite, exact same filename), wait a minute, then run this again."
  systemctl start clinic-app
  exit 1
fi

echo "== installing dependencies (exceljs, added in batch 18, still needed) =="
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
