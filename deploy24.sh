#!/bin/bash
# Deploy script for clinic-app — batch 24.
# Ships the FULL current src/ tree, so it's safe regardless of exactly which
# deploys already ran on this server (re-ships all prior batches too, harmless
# if already applied).
#
# Batch 24 — حل جذري لازدواجية "متابعة" (من غير فصل الملف الطبي عن الملف
# المالي)، تفاصيل المعالجة والطبيب المساعد في المتابعة، وموعد استثنائي
# للدكتور من غير شيفت:
#
#   1) الحل الجذري لازدواجية "متابعة": بدل فصل الملف الطبي عن المالي (اللي
#      المستخدم صراحة رفضه)، اتقفلت كل الطرق اللي ممكن تعمل بيها زيارة
#      "متابعة" جديدة غير مربوطة بفاتورة أصلية:
#        - "أضف زيارة" في الملف الطبي بقى مايقدرش يعمل زيارة "متابعة" جديدة
#          من الصفر خالص (كان ده الباب الرئيسي اللي بيسمح لأي حد عنده صلاحية
#          تعديل الملف الطبي — زي دكتورة زينب في الشكوى — يختار "متابعة"
#          كخدمة عادية من غير أي ربط بفاتورة). لو فيه زيارة "متابعة" مربوطة
#          بالفعل (حصلت من الاستقبال/الجدول)، الطبيب لسه يقدر يكتب عليها
#          "المعالجة" عادي (الاستخدام الشرعي)، بس مايقدرش ينشئ واحدة جديدة
#          مستقلة.
#        - تعديل زيارة موجودة وتغيير نوعها لـ"متابعة" بقى ممنوع برضه لنفس
#          السبب.
#        - مسح خدمة أصلية ليها دفعة "متابعة" مربوطة بيها بقى ممنوع تمامًا
#          (قبل كده كان بيمسح الربط بصمت ويسيب الدفعة معلقة كأنها خدمة
#          مستقلة جديدة — ده أرجح تفسير للازدواج اللي المستخدم شافه). دلوقتي
#          لازم تتمسح دفعة المتابعة هي الأول، أو تفضل الخدمة الأصلية زي ما هي.
#      بالإضافة كمان لتصحيح 2 حاجة كانت بتحصل بالغلط عند تسجيل دفعة متابعة من
#      الاستقبال/الجدول: (أ) كان بيتسجل نص ثابت "دفعة متابعة" في خانة
#      "المعالجة" رغم إنها المفروض تفضل فاضية للطبيب يكتب فيها، و(ب) كان
#      بيتجاهل أي طبيب مساعد مُختار ويحط الطبيب الأساسي بس.
#
#   2) المعالجة في زيارة المتابعة بقت تفضل فاضية فعلاً (مش نص ثابت)، وعلامة
#      "⚠ محتاج تفاصيل معالجة" بتشتغل عليها عادي زي أي زيارة تانية.
#
#   3) حقل "الطبيب المساعد" بقى ظاهر وقابل للتعديل عند تسجيل دفعة متابعة من
#      كارت التحصيل المعلق (PendingCollectionCard) ومودال الجدول المركزي
#      (CentralSchedule) — مش بس في الملف المالي زي قبل كده — بنفس صلاحية
#      edit_visit_assistant_doctor.
#
#   4) ميزة جديدة: دكتور من غير شيفت أسبوعي مسجل النهاردة (سلوك متعمّد ومطلوب
#      إنه يفضل كده) دلوقتي عنده استثناء — لو الاستقبال حجزت له مريض في يوم
#      مش يوم شيفته، بيشوف اسم المريض ده بس (مش أي حجوزات تانية في نفس
#      الغرفة من دكاترة تانيين) مع الساعة المحجوزة، ويقدر يعمله "تم" ويفتح
#      ملفه — كارت مخصص وبسيط (AdHocAppointmentCard) بدل الجدول المركزي
#      الكامل عشان محدش يشوف حجوزات مش بتاعته.
#
#   Verified locally: tsc --noEmit clean, next build clean.
#   test-batch24.js — 15/15 Playwright+DB checks (سيناريو أ: دفعة متابعة
#   بمعالجة فاضية وطبيب مساعد صحيح؛ سيناريو ب: منع إنشاء متابعة مستقلة مع
#   السماح بتحديث زيارة متابعة موجودة بالفعل؛ سيناريو ج: منع تحويل زيارة
#   موجودة لمتابعة؛ سيناريو د: منع مسح خدمة ليها دفعة متابعة مربوطة؛
#   سيناريو هـ: الموعد الاستثنائي للدكتور من غير شيفت، شامل زرار "تم").
#   test-batch23.js — 24/24 (اتأكدنا إن التغييرات دي مأثرتش على إصلاحات
#   الدفعة اللي فاتت).
#   test-batch22-phase2.js — 12/12 (اتأكدنا إن تدفق "تم" في الجدول لسه
#   شغال زي ما هو).
#
# Run as: bash deploy24.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch24.tar.gz
curl -L -o clinic-app-batch24.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch24.tar.gz?cachebust=$(date +%s)"

echo "== extracting update (full src/ tree — overwrites in place) =="
tar -xzf clinic-app-batch24.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "FOLLOWUP_SERVICE_CODE" /opt/clinic-app/src/lib/followup.ts 2>/dev/null && grep -q "AdHocAppointmentCard" /opt/clinic-app/src/app/page.tsx 2>/dev/null && grep -q "followupChildren" /opt/clinic-app/src/app/patients/\[id\]/actions.ts 2>/dev/null; then
  echo "OK: batch 24 code (guaranteed follow-up dedup fix + ad-hoc appointment feature) landed."
else
  echo "PROBLEM: the new code did not land correctly."
  echo "GitHub may still be serving an old clinic-app-batch24.tar.gz - go re-upload it"
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
