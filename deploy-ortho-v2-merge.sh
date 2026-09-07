#!/bin/bash
# Deploy script — دمج "شارت التقويم v2" الحقيقي (يستبدل الشارت القديم).
#
# ده مش زي دفعات المعاينة السابقة: الدفعة دي بتلمس ملفات أساسية (schema.sql,
# client.ts, types.ts, permission-defs.ts) وبتستبدل صفحة شارت التقويم الحقيقية
# اللي المرضى بيستخدموها فعليًا. التغييرات في قاعدة البيانات كلها إضافية بس
# (CREATE TABLE IF NOT EXISTS + ALTER-style column additions) — مفيش حذف أو
# تعديل لأي جدول أو عمود موجود، ومفيش لمس لداتا المرضى.
#
# احتياط إضافي عن الدفعات اللي فاتت: السكريبت بياخد نسخة احتياطية من الكود
# الحالي (src) قبل ما يستبدله، وبيرجعها تلقائيًا لو الفحص بعد التحميل فشل أو
# لو الـbuild فشل — يعني لو أي حاجة غلط، السيستم بيرجع تلقائي للشارت القديم
# الشغال بدل ما يفضل واقف.
#
# Run as: bash deploy-ortho-v2-merge.sh

set -e

TS=$(date +%Y%m%d%H%M%S)
BACKUP_DIR="/opt/clinic-app-src-backup-$TS"

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data directory (احتياطي - الدفعة دي مفيش فيها أي حذف لداتا لكن للأمان) =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$TS"

echo "== backing up current source tree (للرجوع السريع لو أي حاجة غلط) =="
mkdir -p "$BACKUP_DIR"
cp -r /opt/clinic-app/src "$BACKUP_DIR/src"

echo "== downloading merge payload (cache-busted) =="
cd /tmp
rm -f clinic-app-ortho-v2-merge.tar.gz
curl -L -o clinic-app-ortho-v2-merge.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-ortho-v2-merge.tar.gz?cachebust=$(date +%s)"

echo "== verifying checksum =="
ACTUAL_SHA=$(sha256sum clinic-app-ortho-v2-merge.tar.gz | awk '{print $1}')
EXPECTED_SHA="9fa0a22de830dd25c9a079612d7d868d835e1590dedb9f82893af3b95fcafcf3"
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  echo "PROBLEM: checksum mismatch (stale CDN cache?). Not touching anything. Wait a few minutes and re-run."
  echo "expected: $EXPECTED_SHA"
  echo "actual:   $ACTUAL_SHA"
  systemctl start clinic-app
  exit 1
fi

echo "== extracting =="
tar -xzf clinic-app-ortho-v2-merge.tar.gz -C /opt/clinic-app

echo "== verifying the new merge files actually landed =="
if [ -f /opt/clinic-app/src/components/ortho/OrthoChartV2.tsx ] && grep -q "ortho_visits" /opt/clinic-app/src/lib/db/schema.sql 2>/dev/null && grep -q "saveOrthoVisitAction" "/opt/clinic-app/src/app/patients/[id]/orthodontics/ortho-v2-actions.ts" 2>/dev/null; then
  echo "OK: merge files landed."
else
  echo "PROBLEM: expected files missing after extraction. Restoring old source and restarting the OLD chart."
  rm -rf /opt/clinic-app/src
  cp -r "$BACKUP_DIR/src" /opt/clinic-app/src
  systemctl start clinic-app
  exit 1
fi

echo "== rebuilding app (بيشغل كل الـmigrations الإضافية الجديدة على نفس قاعدة البيانات الحالية) =="
cd /opt/clinic-app
if ! npm run build; then
  echo "PROBLEM: build failed on the new merged code. Rolling back source to the pre-deploy version and rebuilding it..."
  rm -rf /opt/clinic-app/src
  cp -r "$BACKUP_DIR/src" /opt/clinic-app/src
  npm run build
  systemctl start clinic-app
  echo "Rolled back successfully — the app is back on the OLD orthodontic chart, nothing was merged. Copy the build error above so it can be fixed before trying again."
  exit 1
fi

echo "== starting app =="
systemctl start clinic-app

sleep 2
echo "== status =="
systemctl status clinic-app --no-pager

echo ""
echo "== تم =="
echo "الشارت الجديد دلوقتي هو الشارت الحقيقي على صفحة أي مريض -> شارت التقويم."
echo "نسخة الكود القديم محفوظة احتياطيًا في: $BACKUP_DIR"
