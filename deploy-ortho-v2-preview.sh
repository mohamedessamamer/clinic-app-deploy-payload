#!/bin/bash
# Deploy script — "شارت التقويم v2" (بروتوتايب معاينة فقط).
#
# ده مش دفعة عادية: بيضيف بس راوت جديد معزول تمامًا `/prototype/ortho-chart-v2`
# (صفحة + 3 كومبوننتس + ملف بيانات أسنان + 14 صورة سن) — من غير أي ربط بالـnav
# ومن غير ما يلمس أو يبدّل أي كود أو داتا موجودة بالفعل، وبالتالي من غير ما يمس
# شارت التقويم الحالي المنشور خالص. مفيش تغيير في قاعدة البيانات، مفيش حذف لأي
# ملف موجود — إضافة بس. الهدف إن المستخدم يعاين شكل التصميم الجديد (Canva) شغال
# فعليًا قبل ما نقرر ندمجه ونستبدل بيه الشارت الحالي.
#
# Run as: bash deploy-ortho-v2-preview.sh

set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data (احتياطي بس - الدفعة دي مش بتلمس الداتا خالص) =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading preview payload (cache-busted) =="
cd /tmp
rm -f clinic-app-ortho-v2-preview.tar.gz
curl -L -o clinic-app-ortho-v2-preview.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-ortho-v2-preview.tar.gz?cachebust=$(date +%s)"

echo "== extracting (إضافة ملفات جديدة بس - مفيش استبدال لأي حاجة موجودة) =="
tar -xzf clinic-app-ortho-v2-preview.tar.gz -C /opt/clinic-app

echo "== verifying the new files actually landed on disk (checking for the LATEST round of changes, not just any old version) =="
if [ -f /opt/clinic-app/src/components/prototype/FollowUpsTable.tsx ] && grep -q "bulkBond" /opt/clinic-app/src/components/prototype/InteractiveToothChart.tsx 2>/dev/null && grep -q "Orthodontic chart" /opt/clinic-app/src/components/prototype/OrthoChartV2.tsx 2>/dev/null; then
  echo "OK: latest preview files (incl. Follow ups table + English/LTR + auto-bonding) landed."
else
  echo "PROBLEM: an OLD/stale version of the payload landed (GitHub's raw.githubusercontent.com CDN can lag several minutes after a re-upload, even with cache-busting)."
  echo "Fix: wait a few minutes and run this script again — no need to re-upload anything on GitHub's side."
  systemctl start clinic-app
  exit 1
fi

echo "== rebuilding app (next start بيقرأ من .next مبني مسبقًا - من غير الخطوة دي الراوت الجديد مش هيبان) =="
cd /opt/clinic-app
npm run build

echo "== starting app =="
systemctl start clinic-app

sleep 2
echo "== status =="
systemctl status clinic-app --no-pager

echo ""
echo "== الخطوة الجاية =="
echo "افتح http://91.99.225.91/prototype/ortho-chart-v2 (بعد تسجيل الدخول بحسابك العادي) للمعاينة."
