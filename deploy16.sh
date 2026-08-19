#!/bin/bash
# Deploy script for clinic-app — batch 16 (ships on top of batches 11-15,
# which are already live on the server). Ships the FULL current src/ tree as
# one package (not an incremental diff), so it's safe regardless of exactly
# which files changed since the last deploy.
#
# Batch 16 — تقرير الإيرادات (أول جزء من "نظام التقارير"):
#   صفحة جديدة تمامًا `/reports` بصلاحيتين مستقلتين (كانتا موجودتين من زمان في
#   نظام الصلاحيات بس مش مستخدمتين خالص: reports_full = عرض كل الأطباء وكل
#   الفترات (افتراضيًا أدمن/مدير عيادة/محاسب)، reports_own = تقريره الشخصي بس
#   (افتراضيًا دكتور) — الاتنين قابلين للمنح/السحب لأي مستخدم لوحده من الإعدادات
#   زي أي صلاحية تانية).
#
#   المحتوى: فلاتر فترة (من/إلى + اختيار شهر كامل بضغطة واحدة + زرار "الشهر ده"/
#   "الشهر اللي فات")، فلتر دكتور (لمين عنده reports_full بس)، فلتر خدمة. إجماليات:
#   الفواتير الجديدة في الفترة، المحصّل في الفترة (شامل أي دفعات متابعة اتحصّلت في
#   الفترة على فواتير أقدم)، عدد الزيارات، وتوزيع المحصّل حسب وسيلة الدفع. تفصيل:
#   جدول حسب الدكتور (لو reports_full ومفيش دكتور واحد متفلتر)، جدول حسب الخدمة،
#   وجدول تفصيل يومي.
#
#   نقطة مهمة (نفس مبدأ إصلاح "المتبقي" في دفعة 15، اتطبق هنا من الأول): دفعات
#   المتابعة (installments) اللي بتتحصّل في الفترة على فواتير قديمة بتترد لدكتور/
#   خدمة الفاتورة الأصلية (parent_invoice_id) مش لخدمة "متابعة" العامة — يعني
#   تحصيل النهاردة على "تقويم معدني" قديم بيتحسب فعليًا مع "تقويم معدني" في
#   التقرير ومع الدكتور صاحبها، مش بيضيع أو يتحسب غلط.
#
#   ربط الشاشات ببعض (بناءً على طلب صريح من المستخدم):
#     - لينك "التقارير" جديد في القايمة العلوية — بيظهر بس لمين عنده الصلاحية
#       فعليًا (reports_full أو reports_own)، مش دور ثابت زي باقي اللينكات.
#     - صفحة الفواتير اليومية (/invoices) فيها دلوقتي لينك "عرض في التقارير" —
#       بيوديك لتقرير مقفول على نفس اليوم المعروض.
#     - كل يوم في جدول "تفصيل يومي" بالتقرير فيه لينك "تفاصيل الفواتير ←" —
#       بيوديك لصفحة /invoices لنفس اليوم ده بكل تفاصيل كل فاتورة سطر بسطر.
#     - أسماء الدكاترة/الخدمات في جداول التقرير قابلة للدوس — بتعمل drill-down
#       لتقرير مفلتر على الدكتور/الخدمة دي بس (نفس الفترة).
#     - الصفحة الرئيسية للدكتور فيها لينك "تقريري" (لمين عنده reports_own).
#
#   Files changed: src/app/reports/page.tsx (جديد), src/components/ReportsFilterForm.tsx
#   (جديد), src/app/layout.tsx, src/components/NavBar.tsx, src/app/invoices/page.tsx,
#   src/app/page.tsx.
#
#   Verified locally end to end (Playwright): بيانات اختبار (فاتورة قديمة +
#   دفعة متابعة عليها في يوم تاني + فاتورة جديدة لدكتور تاني) واتفحص: حساب أدمن
#   شاف كل الأرقام صح (الفواتير الجديدة/المحصّل/عدد الزيارات/توزيع وسيلة الدفع/
#   حسب الدكتور/حسب الخدمة/تفصيل يومي) بما فيها إسناد دفعة المتابعة للدكتور/
#   الخدمة الصح مش ليوم/خدمة تانية؛ حساب دكتور شاف بس بياناته هو (مفيش قايمة
#   اختيار دكتور، مفيش جدول "حسب الدكتور")؛ حساب استقبال (من غير الصلاحيتين)
#   اتمنع من الصفحة برسالة واضحة، ولينك "التقارير" مش ظاهر ليه في القايمة
#   العلوية أصلاً؛ لينك "عرض في التقارير" في /invoices ظاهر وبيودي لرابط صحيح؛
#   drill-down لدكتور واحد بيخفي جدول "حسب الدكتور" صح.
#
# Run as: bash deploy16.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch16.tar.gz
curl -L -o clinic-app-batch16.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch16.tar.gz?cachebust=$(date +%s)"

echo "== extracting update (full src/ tree — overwrites in place) =="
tar -xzf clinic-app-batch16.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if [ -f /opt/clinic-app/src/app/reports/page.tsx ] && grep -q "reports_full" /opt/clinic-app/src/app/reports/page.tsx; then
  echo "OK: src/app/reports/page.tsx landed correctly."
else
  echo "PROBLEM: the new code did not land correctly."
  echo "GitHub may still be serving an old clinic-app-batch16.tar.gz - go re-upload it"
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
