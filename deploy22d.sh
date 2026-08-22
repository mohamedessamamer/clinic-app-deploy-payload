#!/bin/bash
# Deploy script for clinic-app — batch 22, phase 2c (small follow-up to phase 2b).
# Ships the FULL current src/ tree, so it's safe regardless of exactly which
# deploys already ran on this server.
#
# Phase 2c — بند واحد بس:
#   الاسم الإنجليزي لخدمة "متابعة" (كود "0") اتثبت على "FOLLOW UP" بالحروف
#   الكبيرة (كانت "Follow-up" قبل كده). زي باقي الخدمات، الاسم ده هو اللي بيظهر
#   ويتكتب بيه في سجل الزيارات بالملف الطبي (حساب الطبيب) — الكود "0" نفسه
#   ثابت من غير تغيير. تعديل بيانات بس (UPDATE على قاعدة البيانات الموجودة عند
#   تشغيل السيرفر)، مفيهوش مايجريشن هيكلي جديد.
#
#   Verified locally: tsc --noEmit clean, next build clean، وتحقق يدوي (سكرين
#   شوت) إن الدكتور لما يكتب "FOLLOW" في سجل الزيارات بتظهرله "FOLLOW UP #0"
#   في أول نتيجة.
#
# Run as: bash deploy22d.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch22d.tar.gz
curl -L -o clinic-app-batch22d.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch22d.tar.gz?cachebust=$(date +%s)"

echo "== extracting update (full src/ tree — overwrites in place) =="
tar -xzf clinic-app-batch22d.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "FOLLOW UP" /opt/clinic-app/src/lib/db/client.ts 2>/dev/null; then
  echo "OK: batch 22 phase 2c code (FOLLOW UP service name migration) landed."
else
  echo "PROBLEM: the new code did not land correctly."
  echo "GitHub may still be serving an old clinic-app-batch22d.tar.gz - go re-upload it"
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

echo "== starting app (the DB name_en UPDATE for the follow-up service runs automatically"
echo "   on this startup, inside runStartupMigrations) =="
systemctl start clinic-app

sleep 2
echo "== status =="
systemctl status clinic-app --no-pager
