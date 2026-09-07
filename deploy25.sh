#!/bin/bash
# Deploy script for clinic-app — batch 25.
# Ships the FULL current src/ tree, so it's safe regardless of exactly which
# deploys already ran on this server (re-ships all prior batches too, harmless
# if already applied).
#
# Batch 25 — شارت تشخيص وخطة علاج التقويم (أول موضوع من قائمة المستخدم):
#
#   شارت جديد بالكامل مطابق لورقة التشخيص وخطة علاج التقويم اللي بعتها المستخدم
#   (بيانات المريض/الشكوى/التاريخ المرضي/الأسنان الناقصة، تشخيص Skeletal +
#   Dental + Cephalometric + Facial Analysis، وخطة العلاج Extraction/Anchorage/
#   Hints) — تفاعلي بالكامل (دوس على رقم/حرف السن بدل خانات نصية)، في صفحة
#   منفصلة (`/patients/[id]/orthodontics`) عن سجل الزيارات (الملف الطبي العام)
#   بقرار صريح من المستخدم، وصولها من زرار "شارت التقويم" في أعلى ملف المريض.
#
#   نفس قيود تعديل الملف الطبي العادي بالظبط (دكتور + أدمن + مدير عيادة يقدروا
#   يملوا/يعدّلوا، الباقي عرض بس) — بقرار صريح من المستخدم. سجل واحد بس لكل
#   مريض (بيتملى مرة واحدة وقت بداية العلاج، وقابل للتعديل بعدين لو احتاج تصحيح).
#
#   + تركيب التقويم (Bonding) والريبوندينج — تكملة اتضافت في نفس الدفعة:
#     - "تركيب الفك العلوي/السفلي" كل واحد بيتسجل مرة واحدة بس (السيرفر بيرفض
#       أي محاولة تسجيل تانية لنفس الفك)، بتختار نوع البراكت والتيوب من المخزون،
#       وبتحدد أي سن "مش هيترّكب" فيقل عدد البراكت/التيوب المقترح أوتوماتيك.
#       عند التسجيل، الكمية بتتخصم فعليًا من المخزون (جدول inventory_items).
#     - مربع "الوصفة" (Prescription): Roth / MBT / Andrews.
#     - الريبوندينج: تكراري لأي سن في الفكين — رقم صغير فوق السن بيزيد كل مرة
#       يتسجل ريبوندينج عليه (بيخصم براكت واحد من المخزون كل مرة)، وخيار منفصل
#       لتعليم سن "براكته مكسورة دلوقتي" (بيبان أحمر، بيتشال أوتوماتيك لما
#       يتسجل ريبوندينج عليه). السعر لسه بيتسجل يدوي (قرار المستخدم).
#
#   + إعادة تصميم الشارت ليبقى شارت أسنان تفاعلي واحد فقط (تعديل لاحق في نفس
#     الدفعة، بناءً على طلب صريح من المستخدم: "عايز شارت الأسنان يكون تفاعلي
#     ويتم عليه كل حاجة .. وبلاش نعمل شارتس كتير"):
#     - اتشالت كل الشارتات المنفصلة (شارت الأسنان الناقصة، خريطة الخلع الأربع
#       أرباع، شارت "مش هترّكب" بتاع البوندينج، شارت الريبوندينج) واتستبدلت
#       بشارت واحد (ToothChart) بيعرض الفكين كاملين. دوسة على أي سن بتفتح لوحة
#       تفاصيله تحت الشارت مباشرة: ناقص، مطلوب خلعه (لو خطة العلاج extraction)،
#       مش هيترّكب دلوقتي (قبل تسجيل التركيب)، براكته مكسورة + تسجيل ريبوندينج
#       (بعد التركيب)، وملاحظة نصية حرة — "زي ما لو كنت باصص في فم المريض".
#     - عمود جديد tooth_comments (JSON object نصي، سن -> ملاحظة) بيتحفظ مع باقي
#       الشارت (زرار الحفظ العادي، مش أكشن فوري).
#     - الأسنان اللبنية (a-e) فضلت في قسم صغير منفصل لعلامة "ناقص" بس (مش جزء
#       من الخلع/التركيب أصلاً).
#
#   جدول قاعدة بيانات جديد: orthodontic_charts (CREATE TABLE IF NOT EXISTS في
#   schema.sql + أعمدة إضافية للتركيب/الريبوندينج/الملاحظات بـtryAddColumn في
#   client.ts — بيتطبقوا تلقائي عند إعادة تشغيل السيرفر، مفيش أي لمس لأي جدول
#   قديم أو بيانات موجودة بالفعل).
#
#   + تبديل "الأسنان الدائمة / الأسنان اللبنية" فوق الشارت الموحّد مباشرة (طلب
#     لاحق تاني من المستخدم) — بيبدأ افتراضيًا على الدائمة، وزرار تبديل يحوّل
#     للبني عند الحاجة (مش الاتنين مع بعض على الشارت في نفس الوقت). خيار "مطلوب
#     خلعه" بقى مقصور على وضع الدائم بس. سؤال المستخدم عن شكل 3D للشارت اتشرح
#     له (SVG شبه-3D سريع مقابل Three.js حقيقي أتقل بكتير) وقرر يأجله لمرحلة تانية.
#
#   Verified locally: tsc --noEmit clean, next build clean.
#   test-batch25.js — 24/24 Playwright+DB checks (تعبئة شارت التقويم الأساسي
#   على الشارت الموحّد الجديد: ناقص/خلع/ملاحظة حرة على سن، صلاحيات الاستقبال).
#   test-batch25b.js — 25/25 Playwright+DB checks (تحديد أسنان "مش هترّكب" من
#   نفس الشارت الموحّد مع خصم مخزون صحيح، قفل إعادة التسجيل، ريبوندينج تكراري
#   بعداد صحيح وخصم مخزون، تعليم/إزالة "براكت مكسور" من نفس لوحة تفاصيل السن،
#   الاستقبال view-only بالكامل).
#   test-batch25c.js — 10/10 Playwright+DB checks (تبديل دائم/لبني: الافتراضي
#   دائم، التبديل بيخفي/يورّي النوع الصح، مفيش خلع للبني، تعليم سن لبني ناقص
#   مايأثرش على سن دائم، الاثنين بيتسجلوا مع بعض في missing_teeth بعد الحفظ).
#
# Run as: bash deploy25.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch25.tar.gz
curl -L -o clinic-app-batch25.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch25.tar.gz?cachebust=$(date +%s)"

echo "== extracting update (full src/ tree — overwrites in place) =="
tar -xzf clinic-app-batch25.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "orthodontic_charts" /opt/clinic-app/src/lib/db/schema.sql 2>/dev/null && grep -q "OrthodonticChartForm" /opt/clinic-app/src/app/patients/\[id\]/orthodontics/page.tsx 2>/dev/null && grep -q "confirmRebondingAction" /opt/clinic-app/src/app/patients/\[id\]/orthodontics/actions.ts 2>/dev/null && grep -q "ToothChart" /opt/clinic-app/src/components/OrthodonticChartForm.tsx 2>/dev/null && [ -f /opt/clinic-app/src/components/ToothChart.tsx ]; then
  echo "OK: batch 25 code (شارت التقويم الموحّد + تركيب/ريبوندينج) landed."
else
  echo "PROBLEM: the new code did not land correctly."
  echo "GitHub may still be serving an old clinic-app-batch25.tar.gz - go re-upload it"
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
