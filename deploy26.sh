#!/bin/bash
# Deploy script for clinic-app — batch 26.
# Ships the FULL current src/ tree, so it's safe regardless of exactly which
# deploys already ran on this server (re-ships all prior batches too, harmless
# if already applied).
#
# Batch 26 — "المريض جاي يعمل إيه" (لابل تحت اسم المريض في الجدول المركزي):
#
#   عمودين جداد في appointments: purpose_type ('bonding_upper' / 'bonding_lower'
#   / 'service' / NULL) و purpose_service_id (لما purpose_type = 'service').
#   بيتحددوا في مكانين (طلب المستخدم صراحة "بالاثنين"):
#     - وقت الحجز نفسه، من بوكس الحجز في الجدول المركزي (زراير: بدون تحديد /
#       تركيب أول تقويم / تركيب تاني تقويم / خدمة تانية + بحث بالاسم/الكود).
#     - بعد الحجز في أي وقت، من نفس خانة الموعد بالجدول (كليك يمين/دوسة طويلة →
#       "تحديد/تغيير الخدمة" → نفس البوكس).
#
#   اللابل بيظهر تحت اسم المريض في خانة الموعد (front-desk وصفحة الدكتور
#   الرئيسية على السوا). كليك على اللابل: على حسب مين اللي داس (طلب المستخدم
#   صراحة) —
#     - سكرتارية/استقبال: بيروح للملف المالي دايمًا (زي كليك اسم المريض بالظبط).
#     - دكتور: لو "تركيب أول/تاني تقويم" بيروح لشارت التقويم مباشرة، لو أي خدمة
#       تانية (زي حشو/عصب/متابعة تقويم...) بيروح للملف الطبي العادي.
#   "متابعة تقويم" مفيهاش قيمة enum خاصة بيها — دي أصلًا موجودة كخدمتين حقيقيتين
#   في قايمة الخدمات (كود 100 و112)، فبتتغطى تلقائيًا كـ purpose_type = 'service'.
#
#   نطاق متعمد: الميزة دي في الجدول المركزي بس (CentralSchedule) — كروت المواعيد
#   الاستثنائية لدكتور من غير شيفت (AdHocAppointmentCard) لسه من غيرها، ممكن
#   تتضاف بعدين لو المستخدم طلب.
#
#   ملحوظة اكتشفناها بالمرة (مش جزء من الدفعة دي، لسه معلقة): addAppointmentAction
#   و updateAppointmentStatusAction في appointments/actions.ts مفيهمش أي تحقق
#   صلاحيات في السيرفر خالص (بس UI-level canEdit) — على عكس setAppointmentPurposeAction
#   الجديدة اللي معاها تحقق حقيقي (schedule_edit). محتاج قرار من المستخدم لو عايز
#   يتقفل ده كمان.
#
#   test-batch26.js — 18/18 Playwright+DB checks (حجز بـ"تركيب أول تقويم" وقت
#   الحجز، اللابل بيبان صح، كليك الاستقبال يروح للملف المالي، كليك الدكتور يروح
#   لشارت التقويم، تغيير الخدمة من كليك يمين لخدمة عادية "حشو"، كليك الدكتور
#   بعدها يروح للملف الطبي العادي، كليك الاستقبال يفضل يروح للملف المالي برضه،
#   مسح التحديد بيشيل اللابل تاني).
#
# Run as: bash deploy26.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch26.tar.gz
curl -L -o clinic-app-batch26.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch26.tar.gz?cachebust=$(date +%s)"

echo "== extracting update (full src/ tree — overwrites in place) =="
tar -xzf clinic-app-batch26.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "purpose_type" /opt/clinic-app/src/lib/db/types.ts 2>/dev/null && grep -q "setAppointmentPurposeAction" /opt/clinic-app/src/app/appointments/actions.ts 2>/dev/null && grep -q "purposeLabelOf" /opt/clinic-app/src/components/CentralSchedule.tsx 2>/dev/null; then
  echo "OK: batch 26 code (لابل \"المريض جاي يعمل إيه\") landed."
else
  echo "PROBLEM: the new code did not land correctly."
  echo "GitHub may still be serving an old clinic-app-batch26.tar.gz - go re-upload it"
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
