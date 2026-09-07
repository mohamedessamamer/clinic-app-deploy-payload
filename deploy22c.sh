#!/bin/bash
# Deploy script for clinic-app — batch 22, phase 2b (follow-up to phase 2).
# Ships the FULL current src/ tree, so it's safe regardless of exactly which
# deploys already ran on this server (re-ships phase 1 + phase 2 too, harmless
# if already applied).
#
# Phase 2b — بند واحد إضافي (متابعة لملاحظة المستخدم بعد نشر المرحلة 2):
#   حقل "الطبيب المساعد" في سجل الزيارات بقى ليه تعديل مستقل بعد ما الزيارة
#   بتتسجل (مش بس وقت الإضافة) — الصلاحية الجديدة دي منفصلة تمامًا عن صلاحية
#   الدخول لسجل الزيارات الطبي نفسه:
#     - الاستقبال بقى يقدر يعدّل حقل "الطبيب المساعد" بس (صلاحية جديدة
#       edit_visit_assistant_doctor) من غير ما يتفتح لهم أي حاجة تانية في
#       الملف الطبي (لسه ممنوعين تمامًا من إضافة/تعديل باقي سجل الزيارات).
#     - الطبيب الأساسي صاحب الزيارة يقدر يعدّل الحقل ده لزياراته هو دايمًا.
#     - الأدمن ومدير العيادة عندهم الصلاحية دي افتراضيًا كمان.
#
#   + بند تاني إضافي: رأس صفحة "الملف المالي" اتظبط ليطابق شكل رأس الملف الطبي —
#     رقم الملف بخط صغير مع "الملف المالي" جنبه، اسم المريض BOLD وكبير في سطر
#     مستقل، وتحته السن والتليفون والعنوان (لو موجودين) بنفس شكل الملف الطبي.
#
#   Verified locally: tsc --noEmit clean, next build clean, 9/9 Playwright
#   checks (reception can edit the field + stays blocked from the rest of the
#   medical record, doctor can edit his own visits, a non-owner doctor without
#   the permission cannot) + visual screenshot check of the new billing header.
#
# Run as: bash deploy22c.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch22c.tar.gz
curl -L -o clinic-app-batch22c.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch22c.tar.gz?cachebust=$(date +%s)"

echo "== extracting update (full src/ tree — overwrites in place) =="
tar -xzf clinic-app-batch22c.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "updateVisitAssistantDoctorAction" /opt/clinic-app/src/app/patients/\[id\]/actions.ts 2>/dev/null && grep -q "edit_visit_assistant_doctor" /opt/clinic-app/src/lib/permission-defs.ts 2>/dev/null && grep -q "displayAge" /opt/clinic-app/src/app/patients/\[id\]/billing/page.tsx 2>/dev/null; then
  echo "OK: batch 22 phase 2b code (assistant-doctor edit field + billing header redesign) landed."
else
  echo "PROBLEM: the new code did not land correctly."
  echo "GitHub may still be serving an old clinic-app-batch22c.tar.gz - go re-upload it"
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
