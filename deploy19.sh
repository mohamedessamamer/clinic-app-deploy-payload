#!/bin/bash
# Deploy script for clinic-app — batch 19, bundled together with batch 18
# (batch 18 was never deployed on its own — both ship together here on top of
# batches 11-17, which are already live on the server). Ships the FULL current
# src/ tree as one package (not an incremental diff), so it's safe regardless
# of exactly which files changed since the last deploy.
#
# Batch 18 — ثمانية بنود:
#   1. كلمة سر افتراضية ثابتة "123" لأي مستخدم جديد (دكتور/موظف).
#   2. تصدير تقرير الإيرادات (/reports) لملف Excel (زرار "تصدير Excel"، مكتبة exceljs).
#   3. الملف المالي للمريض بقى محجوب عن الدكتور افتراضيًا (صلاحية جديدة
#      view_patient_billing) + إغلاق ثغرة أمان: /patients/[id]/billing و
#      /inventory ماكانش فيهم أي تحقق صلاحيات خالص قبل كده.
#   4. البحث باسم المريض بقى substring (includes) في كل مكان، مش بس أول الاسم.
#   5. سن المريض بيتحسب من تاريخ الميلاد (birth_date) بالسنة الكاملة، مع
#      fallback لعمود age القديم للمرضى اللي مالهمش تاريخ ميلاد مسجل.
#   6. رابط "جدول الاستقبال" اتشال من القايمة العلوية لأكونت الاستقبال بس
#      (الصفحة الرئيسية بتوجّهه لـ /front-desk أوتوماتيك أصلاً).
#   7. "المخزون" بقت "المخزن" في كل مكان، وبقت صلاحية حقيقية قابلة للمنح
#      (manage_inventory) + إغلاق ثغرة أمان: /inventory وأكشناته ماكانش فيهم
#      أي تحقق صلاحيات أو حتى تسجيل دخول خالص قبل كده.
#   8. صفحة /reports: تقرير الدكتور الشخصي (reports_own بدون reports_full)
#      بقى محدود بحد أقصى شهرين فترة (بيتقصّر أوتوماتيك مع ملحوظة واضحة).
#
# Batch 19 — تحسينات موبايل/تابلت + تصميم 3D:
#   1. بحث substring فوري عن المريض في بوكس "إضافة خدمة" تحت الجدول (نفس شكل
#      بوكس الحجز بالجدول المركزي) — مكوّن مشترك جديد PatientSearchSelect.tsx.
#   2. دوسة طويلة (550ms) على خانة موعد بالجدول المركزي = نفس قائمة الزر
#      اليمين (تغيير حالة الموعد) — دعم لمس حقيقي للموبايل/التابلت.
#   3. ترتيب ثابت للقايمة العلوية لكل الأدوار (قرار قياسي دائم): الرئيسية،
#      الاستقبال، المرضى، الفواتير، المخزن، التقارير (+ الإعدادات للأدمن) —
#      بغض النظر عن أي تركيبة صلاحيات.
#   4. تسمية "جدول الاستقبال" -> "الاستقبال" في عنوان الصفحة والروابط السريعة.
#   5. نظام تصميم 3D (تدرج لامع) على كل البطاقات والأزرار وشارات الأيقونات في
#      كل صفحات التطبيق (.card-3d / .btn-3d-primary / .icon-badge-3d)، ومجموعة
#      أيقونات SVG جديدة للقايمة العلوية (src/components/icons.tsx).
#
#   Verified locally end to end (tsc + next build + Playwright + مراجعة بصرية
#   بلقطات شاشة على مقاسي كمبيوتر وموبايل).
#
# Run as: bash deploy19.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch19.tar.gz
curl -L -o clinic-app-batch19.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch19.tar.gz?cachebust=$(date +%s)"

echo "== extracting update (full src/ tree — overwrites in place) =="
tar -xzf clinic-app-batch19.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "getReportsData" /opt/clinic-app/src/lib/reports-data.ts 2>/dev/null && grep -q "icon-badge-3d" /opt/clinic-app/src/app/globals.css; then
  echo "OK: batch 18 (reports-data.ts) and batch 19 (3D design system) code both landed."
else
  echo "PROBLEM: the new code did not land correctly."
  echo "GitHub may still be serving an old clinic-app-batch19.tar.gz - go re-upload it"
  echo "(overwrite, exact same filename), wait a minute, then run this again."
  systemctl start clinic-app
  exit 1
fi

echo "== clearing old build cache =="
cd /opt/clinic-app
rm -rf .next

echo "== rebuilding app (next start serves a pre-built .next - without this step the new"
echo "   source files sit on disk but next start keeps serving the OLD compiled build) =="
npm run build

echo "== starting app =="
systemctl start clinic-app

sleep 2
echo "== status =="
systemctl status clinic-app --no-pager
