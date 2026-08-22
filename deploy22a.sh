#!/bin/bash
# Deploy script for clinic-app — batch 22, phase 1 (of 3 planned phases).
# Ships the FULL current src/ tree as one package, so it's safe regardless of
# exactly which files changed since the last deploy.
#
# Phase 1 — أربعة بنود:
#   1. تعديل بيانات المريض الأساسية (الاسم/تاريخ الميلاد/التليفون/العنوان) من
#      ملفه — زرار "تعديل البيانات" جنب اسمه، صلاحية جديدة edit_patient_info
#      (الأدمن والاستقبال افتراضيًا).
#   2. تاريخ الميلاد بصيغة dd/mm/yyyy في العرض والإدخال (حقول تاريخ الميلاد
#      بقت lang="en-GB" عشان الترتيب يبقى يوم/شهر/سنة بدل شهر/يوم/سنة).
#   3. أسماء الخدمات في الملف الطبي بس بقت بالإنجليزي (name_en، مع fallback
#      للعربي لو خدمة معينة لسه من غير ترجمة)، والبحث هناك بقى بالاسم
#      الإنجليزي أو الكود. باقي الأماكن (الفواتير، الجدول، الملف المالي)
#      لسه عربي زي ما هي.
#   4. صفحة الإعدادات بقت بقائمة جانبية (الملف الشخصي، العيادات، الخدمات،
#      المستخدمين، الصلاحيات) بدل الأقسام كلها تحت بعض في صفحة طويلة.
#
#   Verified locally: tsc --noEmit clean, next build clean, 17/17 Playwright
#   checks (settings sidebar tabs, patient edit permission gating admin/
#   reception/doctor, dd/mm/yyyy date input, English service search/display
#   in medical file, Arabic names still elsewhere).
#
# Run as: bash deploy22a.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch22a.tar.gz
curl -L -o clinic-app-batch22a.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch22a.tar.gz?cachebust=$(date +%s)"

echo "== extracting update (full src/ tree — overwrites in place) =="
tar -xzf clinic-app-batch22a.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "EditPatientForm" /opt/clinic-app/src/app/patients/\[id\]/page.tsx 2>/dev/null && grep -q "SettingsSidebarLayout" /opt/clinic-app/src/app/settings/page.tsx 2>/dev/null; then
  echo "OK: batch 22 phase 1 code (patient edit form + settings sidebar) landed."
else
  echo "PROBLEM: the new code did not land correctly."
  echo "GitHub may still be serving an old clinic-app-batch22a.tar.gz - go re-upload it"
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
