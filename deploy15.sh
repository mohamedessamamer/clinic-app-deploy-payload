#!/bin/bash
# Deploy script for clinic-app — batch 15 (ships on top of batches 11+12+13+14,
# which are already live on the server). Ships the FULL current src/ tree as
# one package (not an incremental diff), so it's safe regardless of exactly
# which files changed since the last deploy.
#
# Batch 15:
#   Fixed a confusing/misleading number on /invoices (الفواتير — الجدول اليومي):
#   the top "المتبقي" card was computed as (كل فواتير اليوم) - (كل المحصّل
#   النهاردة)، لكن "المحصّل" كان بيشمل كمان دفعات المتابعة (installments) على
#   فواتير قديمة مش ظاهرة في جدول اليوم أصلاً — فطرحها من استحقاق اليوم كان بيدي
#   رقم (زي 5000) مالوش أي علاقة بأي رقم ظاهر فعليًا تحت في الجدول، وده كان
#   بيلخبط. كمان صفوف "↳ دفعة متابعة" كانت بتعرض شرطات في كل خاناتها (السعر
#   الأصلي/المتبقي) من غير أي إشارة لأنهي خدمة الدفعة دي بتقفل رصيدها.
#   Fix:
#     1. "المتبقي" فوق بقت بتتحسب بس من فواتير اليوم الجديدة (استثناء صفوف دفعة
#        المتابعة من الحساب ده) — يبقى دلوقتي بيطابق أي رقم متبقي ظاهر فعليًا في
#        الجدول تحت. "المحصّل" لسه بيشمل كل الكاش المتحصّل النهاردة (بما فيه
#        دفعات المتابعة على فواتير قديمة) مع توضيح ده تحت الرقم مباشرة.
#     2. صفوف "↳ دفعة متابعة" بقت بتجيب وتعرض بيانات الفاتورة الأصلية: اسم
#        الخدمة، السعر الأصلي، والرصيد المتبقي الفعلي الحالي على الفاتورة
#        الأصلية دي (بعد خصم كل دفعات المتابعة عليها لحد دلوقتي، مش بس اللي
#        حصلت النهاردة) — بدل الشرطات الفاضية.
#     3. نفس التحسين (عرض اسم الخدمة الأصلية) اتضاف لصفوف دفعة المتابعة في
#        الملف المالي لكل مريض (/patients/[id]/billing) للاتساق — الحسابات هناك
#        كانت أصلاً صح (بتاخد في الاعتبار كل دفعات المتابعة على مر الأيام).
#   Files changed: src/app/invoices/page.tsx, src/app/patients/[id]/billing/page.tsx
#   Verified locally end to end (seeded a فاتورة أصلية 30000 مدفوع منها 10000 +
#   دفعة متابعة 5000 عليها في نفس اليوم → "إجمالي فواتير اليوم" 30000,
#   "المحصّل" 15000, "المتبقي على فواتير اليوم" 20000 مطابق للصف الظاهر تحت،
#   وصف دفعة المتابعة عرض "↳ دفعة متابعة (كشف)" والمتبقي الفعلي 15000 على
#   الفاتورة الأصلية).
#
# Run as: bash deploy15.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch15.tar.gz
curl -L -o clinic-app-batch15.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch15.tar.gz?cachebust=$(date +%s)"

echo "== extracting update (full src/ tree — overwrites in place) =="
tar -xzf clinic-app-batch15.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "newRemaining" /opt/clinic-app/src/app/invoices/page.tsx; then
  echo "OK: invoices/page.tsx has the new totals/parent-invoice code."
else
  echo "PROBLEM: the new code did not land correctly."
  echo "GitHub may still be serving an old clinic-app-batch15.tar.gz - go re-upload it"
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
