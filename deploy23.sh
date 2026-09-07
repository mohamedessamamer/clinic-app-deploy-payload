#!/bin/bash
# Deploy script for clinic-app — batch 23.
# Ships the FULL current src/ tree, so it's safe regardless of exactly which
# deploys already ran on this server (re-ships all prior batches too, harmless
# if already applied).
#
# Batch 23 — أولوية حل مشكلة ازدواجية دخول الخدمات (ربط الملف المالي بالملف
# الطبي) + حذف الطبيب بالكامل + تاريخ الميلاد dd/mm/yyyy:
#
#   1) السبب الجذري لتكرار الخدمة (نفس الشكوى المتكررة): كان في 3 أماكن مختلفة
#      في الكود ("أضف زيارة" في الملف الطبي، "تم" في الجدول، "إضافة خدمة" في
#      الملف المالي) كل واحد فيهم يقدر يعمل زيارة+فاتورة جديدة لنفس الحدث
#      الحقيقي من غير ما يتواصلوا مع بعض. اتعمل مكان واحد مشترك
#      (findMatchingVisit) بيتأكد إذا كانت فيه زيارة موجودة بالفعل لنفس
#      المريض/الدكتور/التاريخ/الخدمة قبل ما يتعمل واحدة جديدة، وبقى مستخدم في
#      الثلاث أماكن دول:
#        - لو الطبيب دخل من الملف الطبي على زيارة موجودة: بيتحدث فيها بس
#          "المعالجة" والطبيب المساعد (لو مُدخل) — من غير ما يلمس أي بيانات
#          مالية خالص.
#        - لو الاستقبال/الجدول دخلوا على زيارة موجودة: بيتحدث فيها بس بيانات
#          الفاتورة (السعر/المدفوع/الخصم/طريقة الدفع) والطبيب المساعد (لو
#          مُدخل) — من غير ما يلمسوا "المعالجة" اللي كتبها الطبيب خالص.
#      ده بيحقق بالظبط سيناريوهات 1، 2 و4 اللي المستخدم طلبها: أي بيانات
#      تتدخل من مكان تسمع في التاني تلقائي بدون ما تتكرر الخدمة، وكل جانب
#      شايف بس اللي يخصه (الاستقبال ميشوفش المعالجة وقت إدخال الخدمة، الطبيب
#      ميشوفش بيانات الفلوس).
#
#   2) حقل "الطبيب المساعد" بقى ظاهر وقابل للتعديل في كل أماكن إدخال
#      الخدمة من جانب الاستقبال (الملف المالي، كارت التحصيل المعلق، مودال
#      التحصيل في الجدول) — نفس صلاحية edit_visit_assistant_doctor المضافة
#      في الدفعة اللي فاتت — ده بيحقق سيناريو 3 (مدير العيادة/الاستقبال
#      يقدر يعدّل مين نفذ الخدمة فعليًا من غير ما يحتاج يختار الطبيب الأساسي
#      تاني).
#
#   3) تنبيه بصري مبدئي (مش نظام إشعارات كامل — ده لسه معلق، اتكلمنا عنه في
#      الرسالة المرفقة): أي زيارة ليها خدمة محددة بس من غير "معالجة" مكتوبة
#      بيظهر لها خلفية صفراء فاتحة وعلامة "⚠ محتاج تفاصيل معالجة" في سجل
#      الزيارات بالملف الطبي.
#
#   4) حذف الطبيب بالكامل: زرار "حذف الطبيب" (بدل "حذف" العادي) لحسابات
#      الأطباء في المستخدمين — بيقفل الحساب وبيشيل الطبيب من كل قوائم
#      اختيار الأطباء النشطين (doctors.active=0) في نفس الوقت، من غير ما
#      يمسح أي زيارات/فواتير/تقارير قديمة بتاعته.
#
#   5) تاريخ الميلاد: اتبين إن شكل input التاريخ الأصلي بيتحدد حسب نظام
#      تشغيل/متصفح الجهاز مش بخاصية lang في الكود (ده اللي كان بيسبب ظهوره
#      mm/dd/yyyy على السيرفر رغم محاولة الإصلاح اللي فاتت) — اتبدل بحقل
#      نصي مضبوط يدويًا يفرض dd/mm/yyyy دايمًا في كل الأجهزة.
#
#   Verified locally: tsc --noEmit clean, next build clean.
#   test-batch23.js — 24/24 Playwright+DB checks (سيناريو أ: استقبال يدخل
#   الخدمة الأول والطبيب يكمل المعالجة بعدين على نفس الزيارة/الفاتورة بدون
#   تكرار؛ سيناريو ب: الطبيب يدخل الأول والاستقبال يحاسب بعدين بدون ما
#   يمسح المعالجة أو يكرر الفاتورة؛ سيناريو ج: علامة "محتاج تفاصيل معالجة"
#   بتظهر صح؛ حذف الطبيب بالكامل؛ تاريخ الميلاد dd/mm/yyyy).
#   test-batch22-phase2.js — 12/12 (اتأكدنا إن توسيع findMatchingVisit
#   (شيل قيد appointment_id) مأثرش على تدفق "تم" في الجدول).
#
# Run as: bash deploy23.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch23.tar.gz
curl -L -o clinic-app-batch23.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch23.tar.gz?cachebust=$(date +%s)"

echo "== extracting update (full src/ tree — overwrites in place) =="
tar -xzf clinic-app-batch23.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "findMatchingVisit" /opt/clinic-app/src/lib/visit-match.ts 2>/dev/null && grep -q "BirthDateInput" /opt/clinic-app/src/app/patients/new/page.tsx 2>/dev/null && grep -q "doctors.*active.*0" /opt/clinic-app/src/app/settings/actions.ts 2>/dev/null && grep -q "محتاج تفاصيل معالجة" /opt/clinic-app/src/components/VisitsTable.tsx 2>/dev/null; then
  echo "OK: batch 23 code (duplicate-service fix + delete-doctor + birth-date + assistant-doctor fields) landed."
else
  echo "PROBLEM: the new code did not land correctly."
  echo "GitHub may still be serving an old clinic-app-batch23.tar.gz - go re-upload it"
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
