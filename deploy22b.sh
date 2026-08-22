#!/bin/bash
# Deploy script for clinic-app — batch 22, phase 2 (of 3 planned phases).
# Ships the FULL current src/ tree as one package, so it's safe regardless of
# exactly which files changed since the last deploy — this also re-ships
# phase 1 (batch22a) in case that deploy hadn't run yet on this server.
#
# Phase 2 — ثلاثة بنود:
#   1. تعريف دكتور كـ"استشاري" وربطه بأكتر من دكتور مساعد من قائمة الأطباء
#      الموجودة على السيستم (جدول جديد consultant_assistants) — من الإعدادات،
#      تبويب المستخدمين. دخل الحالة اللي المساعد بيسجلها بيتحسب على الاستشاري.
#   2. إعادة تسمية حقل "مقدم الخدمة الفعلي" في سجل الزيارات بالملف الطبي لـ
#      "الطبيب المساعد" (نفس الصلاحية والمكان، تغيير اسم بس).
#   3. إصلاح باج حقيقي: لو الطبيب سجّل خدمة من سجل الزيارات في الملف الطبي
#      (من غير ما يعمل الاستقبال "تم" من الجدول)، وبعدين الاستقبال عمل "تم"
#      وسجّل نفس الخدمة، كان بيتعمل فاتورتين مستقلتين لنفس الخدمة (مرة توثيق
#      من الطبيب بسعر افتراضي مدفوع=صفر، ومرة تحصيل حقيقي من الاستقبال) —
#      يعني المستحق على المريض كان ممكن يظهر ضعف المبلغ الحقيقي. دلوقتي لو
#      نفس المريض/الدكتور/اليوم/الخدمة متطابقين، الاستقبال بيربط ويحدّث نفس
#      الزيارة والفاتورة اللي الطبيب سجلها، بدل ما يعمل زيارة وفاتورة جديدتين.
#
#   Verified locally: tsc --noEmit clean, next build clean, 12/12 Playwright
#   checks (consultant/assistant settings UI + DB, label rename, duplicate-
#   invoice fix end to end including exact-one-invoice + correct paid amount).
#
# Run as: bash deploy22b.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch22b.tar.gz
curl -L -o clinic-app-batch22b.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch22b.tar.gz?cachebust=$(date +%s)"

echo "== extracting update (full src/ tree — overwrites in place) =="
tar -xzf clinic-app-batch22b.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "DoctorConsultantManager" /opt/clinic-app/src/app/settings/page.tsx 2>/dev/null && grep -q "existingVisit" /opt/clinic-app/src/app/appointments/billing-actions.ts 2>/dev/null; then
  echo "OK: batch 22 phase 2 code (consultant/assistant manager + duplicate-invoice fix) landed."
else
  echo "PROBLEM: the new code did not land correctly."
  echo "GitHub may still be serving an old clinic-app-batch22b.tar.gz - go re-upload it"
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
