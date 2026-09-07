#!/bin/bash
# Deploy script for clinic-app — batch 17 (ships on top of batches 11-16,
# which are already live on the server). Ships the FULL current src/ tree as
# one package (not an incremental diff), so it's safe regardless of exactly
# which files changed since the last deploy.
#
# Batch 17 — اختيار اسم مستخدم يدوي عند إنشاء دكتور/موظف جديد:
#   قبل كده اسم المستخدم كان بيتولد تلقائيًا بس (زي dr.mohamed722) بدون أي
#   اختيار. دلوقتي في فورمي "إضافة دكتور" و"إضافة موظف" بالإعدادات فيه حقل جديد
#   "اسم المستخدم (اختياري)":
#     - لو اتملى، بيتسجل بيه بالظبط — بشرط يكون حروف إنجليزي/أرقام/. _ - بس
#       (من غير مسافات أو عربي)، من 3 لـ 30 حرف، ومش مستخدم لحساب تاني بالفعل.
#       أي مخالفة بترجع رسالة خطأ واضحة تحت الفورم (مش "حصل خطأ" عامة).
#     - لو سيبته فاضي، السلوك القديم فاضل زي ما هو تمامًا (توليد تلقائي من اسم
#       الشخص + رقم عشوائي).
#   التحقق من الاسم بيحصل قبل إنشاء أي صف في قاعدة البيانات (حتى صف الدكتور
#   نفسه)، عشان لو الاسم مرفوض ميفضلش صف دكتور "يتيم" من غير حساب مستخدم مرتبط
#   بيه.
#   Files changed: src/app/settings/actions.ts, src/components/AddDoctorForm.tsx,
#   src/components/AddEmployeeForm.tsx.
#
#   Verified locally end to end (Playwright): اسم مستخدم مخصص اتسجل بالظبط
#   زي ما اتكتب (للدكتور وللموظف الاتنين)؛ نفس الاسم تاني اتمنع برسالة "مستخدم
#   بالفعل"؛ اسم فيه عربي/مسافات اتمنع برسالة "حروف إنجليزي..."؛ وترك الحقل
#   فاضي لسه بيولّد يوزرنيم تلقائي زي الأول بالظبط.
#
# Run as: bash deploy17.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch17.tar.gz
curl -L -o clinic-app-batch17.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch17.tar.gz?cachebust=$(date +%s)"

echo "== extracting update (full src/ tree — overwrites in place) =="
tar -xzf clinic-app-batch17.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "resolveUsername" /opt/clinic-app/src/app/settings/actions.ts; then
  echo "OK: settings/actions.ts has the new custom-username code."
else
  echo "PROBLEM: the new code did not land correctly."
  echo "GitHub may still be serving an old clinic-app-batch17.tar.gz - go re-upload it"
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
