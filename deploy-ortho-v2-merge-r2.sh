#!/bin/bash
# Deploy script — دمج "شارت التقويم v2" الحقيقي (يستبدل الشارت القديم). جولة 2،
# بعد حادثة توقف كامل حصلت مع الجولة الأولى (راجع claude/orthodontic-chart-v2-preview-status.md
# تحديث 12 لتفاصيل السبب والإصلاح الكامل).
#
# التغييرات عن جولة النشر اللي فاتت:
#   - src/lib/db/client.ts: الاتصال بقاعدة البيانات ومحاولة الـmigrations بقوا
#     يحصلوا مرة واحدة بس لكل تشغيلة سيرفر (كان بيتكرر مع كل مرة الملف يتحمّل،
#     وده اللي سبب تعليق السيستم كله بعد آخر Restart).
#   - شارت التقويم بقى إنجليزي/LTR دايمًا (page.tsx + OrthoChartV2)، ومربع
#     الصور والأشعة بقى بتصميم إنجليزي مطابق للبروتوتايب (OrthoImageGallery/
#     OrthoAddImageGroupForm) بدل مكونات ملف المريض العربية — لسه بيحفظ في
#     نفس قاعدة البيانات الحقيقية.
#   - إصلاح صغير في ortho-v2-actions.ts (استخدام trx بدل db جوه transaction).
#
# احتياط إضافي جديد عن المرة اللي فاتت: بعد ما السيرفر يشتغل، السكريبت بيضرب
# كذا طلب *في نفس اللحظة* لصفحات مختلفة (بالظبط زي السيناريو اللي سبب التوقف)
# قبل ما يعتبر النشر نجح — لو أي طلب علّق أو رجع فاضي، بيرجع تلقائيًا للكود
# القديم. ده مهم لأن "systemctl status" وحده مكنش هيكتشف المشكلة اللي فاتت
# (العملية كانت شغالة لكن مش بترد — status كان هيقول "active" برضه).
#
# Run as: bash deploy-ortho-v2-merge-r2.sh

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
  echo "Rolled back successfully — the app is back on the OLD orthodontic chart, nothing was merged."
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
rm -f clinic-app-ortho-v2-merge-r2.tar.gz
curl -L -o clinic-app-ortho-v2-merge-r2.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-ortho-v2-merge-r2.tar.gz?cachebust=$(date +%s)"

echo "== verifying checksum =="
ACTUAL_SHA=$(sha256sum clinic-app-ortho-v2-merge-r2.tar.gz | awk '{print $1}')
EXPECTED_SHA="2dcb55fe6b2561d86fb0e3cd9ae75c5d484970c18659311aeb279350e67633c7"
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  echo "PROBLEM: checksum mismatch (stale CDN cache?). Not touching anything. Wait a few minutes and re-run."
  echo "expected: $EXPECTED_SHA"
  echo "actual:   $ACTUAL_SHA"
  systemctl start clinic-app
  exit 1
fi

echo "== extracting =="
tar -xzf clinic-app-ortho-v2-merge-r2.tar.gz -C /opt/clinic-app

echo "== verifying the new files actually landed (including the fix itself) =="
if [ -f /opt/clinic-app/src/components/ortho/OrthoImageGallery.tsx ] \
  && grep -q "__clinicMigrated" /opt/clinic-app/src/lib/db/client.ts 2>/dev/null \
  && grep -q "ortho_visits" /opt/clinic-app/src/lib/db/schema.sql 2>/dev/null; then
  echo "OK: merge files (including the connection/migration fix) landed."
else
  rollback_and_exit "PROBLEM: expected files missing after extraction (or an old cached payload landed). Restoring old source and restarting the OLD chart."
fi

echo "== rebuilding app (بيشغل كل الـmigrations الإضافية الجديدة على نفس قاعدة البيانات الحالية) =="
cd /opt/clinic-app
if ! npm run build; then
  rollback_and_exit "PROBLEM: build failed on the new merged code. Rolling back source to the pre-deploy version and rebuilding it..."
fi

echo "== starting app =="
systemctl start clinic-app
sleep 2

echo "== smoke test: firing concurrent requests to several different pages at once — the exact scenario that caused last time's outage =="
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
  rollback_and_exit "PROBLEM: smoke test failed — at least one page did not respond in time (same failure pattern as last time). Rolling back."
fi

echo "OK: smoke test passed — all pages responded quickly, even when hit at the same moment."

echo "== status =="
systemctl status clinic-app --no-pager

echo ""
echo "== تم =="
echo "الشارت الجديد دلوقتي هو الشارت الحقيقي على صفحة أي مريض -> شارت التقويم، وبقى إنجليزي/LTR دايمًا."
echo "نسخة الكود القديم محفوظة احتياطيًا في: $BACKUP_DIR"
