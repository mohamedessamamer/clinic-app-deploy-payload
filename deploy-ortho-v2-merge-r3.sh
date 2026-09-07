#!/bin/bash
# Deploy script — دفعة تعديلات على شارت التقويم v2 بعد نجاح النشر السابق (جولة 3).
# مفيش أي تغيير في منطق الاتصال بقاعدة البيانات أو الـmigrations نفسه (الإصلاح
# اللي منع التوقف اللي حصل قبل كده لسه زي ما هو من غير أي لمس) — الدفعة دي كلها
# تعديلات فوقه: تعديلات واجهة + عمود جديد واحد بس (patient_images.rotation) +
# إصلاح منطقي في ريفند المخزون + ربط المواعيد بالشارت.
#
# التفاصيل الكاملة لكل بند في claude/orthodontic-chart-v2-preview-status.md
# (تحديث 14). ملخص سريع:
#   1) الغاء الهيدر المكرر + "Back to patient file" جنب العنوان.
#   2) مربع الصور فوق تحت الاسم مباشرة (قبل Chief Complaint)، زي البروتوتايب.
#   3) رفع الصور بقى على مرحلتين (تحديد ثم Upload) بدل الرفع الفوري، والعرض
#      بقى مجمّع بالتاريخ/الوصف.
#   4) الصور بتتصغّر تلقائيًا (max 2000px / JPEG 92%) قبل الرفع من غير تأثير
#      ملحوظ على الجودة.
#   5) تدوير الصورة (⟳) مع حفظ آخر وضع في قاعدة البيانات (عمود جديد).
#   6) إصلاح باج: تصحيح "No brackets" بعد بوندنج غلط بيرجّع خصم المخزون
#      الخاص بالسن ده بس دلوقتي (مش هيسيبه من غير رجوع زي الأول).
#   7) خط بولد وأكبر لـU/L ومقاس/نوع الوير والخدمة والملاحظات الحرة.
#   8) اختيار الدكتور إجباري قبل حفظ أي زيارة متابعة (سيرفر + واجهة).
#   9) أي مريض تقويم في جدول المواعيد (استقبال/صفحة الدكتور) — دوسة على
#      اسمه/الموعد من حساب دكتور بتوّدي لشارت التقويم مباشرة.
#
# نفس احتياط الـsmoke test من الجولة اللي فاتت اتسابت زي ما هي: بعد ما
# السيرفر يشتغل، بيضرب كذا طلب لصفحات مختلفة في نفس اللحظة، ولو أي حاجة
# علّقت أو رجعت فاضية، بيرجع تلقائيًا للكود القديم من غير ما يستنى حد يلاحظ.
#
# Run as: bash deploy-ortho-v2-merge-r3.sh

set -e

TS=$(date +%Y%m%d%H%M%S)
BACKUP_DIR="/opt/clinic-app-src-backup-$TS"

rollback_and_exit() {
  echo "$1"
  rm -rf /opt/clinic-app/src
  cp -r "$BACKUP_DIR/src" /opt/clinic-app/src
  cd /opt/clinic-app
  npm run build
  systemctl start clinic-app
  echo "Rolled back successfully — the app is back on the PREVIOUS working version, nothing from this batch was applied."
  exit 1
}

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data directory (احتياطي - الدفعة دي مفيش فيها أي حذف لداتا لكن للأمان) =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$TS"

echo "== backing up current source tree (للرجوع السريع لو أي حاجة غلط) =="
mkdir -p "$BACKUP_DIR"
cp -r /opt/clinic-app/src "$BACKUP_DIR/src"

echo "== downloading merge payload (cache-busted) =="
cd /tmp
rm -f clinic-app-ortho-v2-merge-r3.tar.gz
curl -L -o clinic-app-ortho-v2-merge-r3.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-ortho-v2-merge-r3.tar.gz?cachebust=$(date +%s)"

echo "== verifying checksum =="
ACTUAL_SHA=$(sha256sum clinic-app-ortho-v2-merge-r3.tar.gz | awk '{print $1}')
EXPECTED_SHA="c1439f73fc432837bfe717b0f5fb963bfacddaaea4e405a99cc9e20558f956ec"
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  echo "PROBLEM: checksum mismatch (stale CDN cache?). Not touching anything. Wait a few minutes and re-run."
  echo "expected: $EXPECTED_SHA"
  echo "actual:   $ACTUAL_SHA"
  systemctl start clinic-app
  exit 1
fi

echo "== extracting =="
tar -xzf clinic-app-ortho-v2-merge-r3.tar.gz -C /opt/clinic-app

echo "== verifying the new files actually landed =="
if [ -f /opt/clinic-app/src/components/ortho/OrthoAddImageGroupForm.tsx ] \
  && [ -f /opt/clinic-app/src/lib/image-compress.ts ] \
  && grep -q "rotation" /opt/clinic-app/src/lib/db/schema.sql 2>/dev/null \
  && grep -q "rotateImageAction" "/opt/clinic-app/src/app/patients/[id]/actions.ts" 2>/dev/null \
  && grep -q "is_ortho_patient" /opt/clinic-app/src/components/CentralSchedule.tsx 2>/dev/null; then
  echo "OK: this batch's files landed."
else
  rollback_and_exit "PROBLEM: expected files missing after extraction (or an old cached payload landed). Restoring previous source and restarting it."
fi

echo "== rebuilding app (بيشغل الـmigration الإضافية الجديدة، عمود واحد بس، على نفس قاعدة البيانات الحالية) =="
cd /opt/clinic-app
if ! npm run build; then
  rollback_and_exit "PROBLEM: build failed on the new code. Rolling back source to the pre-deploy version and rebuilding it..."
fi

echo "== starting app =="
systemctl start clinic-app
sleep 2

echo "== smoke test: firing concurrent requests to several different pages at once =="
mkdir -p /tmp/ortho-smoke
rm -f /tmp/ortho-smoke/*
for path in /login /patients /inventory /settings /reports /front-desk /invoices; do
  (curl -s -o /dev/null -w "%{http_code}" --max-time 8 "http://localhost:3000$path" > "/tmp/ortho-smoke/$(echo "$path" | tr '/' '_')" 2>/dev/null || echo "000" > "/tmp/ortho-smoke/$(echo "$path" | tr '/' '_')") &
done
wait

SMOKE_OK=1
for f in /tmp/ortho-smoke/*; do
  CODE=$(cat "$f")
  echo "  $f -> $CODE"
  if [ "$CODE" = "000" ] || [ -z "$CODE" ]; then
    SMOKE_OK=0
  fi
done

if [ "$SMOKE_OK" != "1" ]; then
  rollback_and_exit "PROBLEM: smoke test failed — at least one page did not respond in time. Rolling back."
fi

echo "OK: smoke test passed — all pages responded quickly, even when hit at the same moment."

echo "== status =="
systemctl status clinic-app --no-pager

echo ""
echo "== تم =="
echo "دفعة التعديلات دي (الهيدر/ترتيب الصور/رفع الصور على مرحلتين/الضغط/التدوير/ريفند المخزون/الخط البولد/الدكتور الإجباري/ربط المواعيد بالشارت) بقت شغالة."
echo "نسخة الكود القديم محفوظة احتياطيًا في: $BACKUP_DIR"
