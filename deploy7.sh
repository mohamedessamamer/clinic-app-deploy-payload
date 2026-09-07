#!/bin/bash
# Batch 7 deploy script for clinic-app
# (الملف المالي للمريض ووسيلة الدفع: لما يتم الضغط على "تم" في الجدول المركزي —
# وكان عند المستخدم صلاحية "تحصيل المدفوعات" — بيتفتح بوكس تحصيل: اختيار خدمة
# بالبحث بالاسم أو الكود، السعر بييجي من الإعدادات مع إمكانية تعديله، خصم بالنسبة،
# والمبلغ المطلوب دفعه. لو الخدمة "متابعة" (كود 0)، بيظهر اختيار لخدمة سابقة للمريض
# لسه عليها مبلغ مستحق، والمبلغ اللي هيتدفع دلوقتي بيتخصم من رصيد الفاتورة الأصلية
# دي تحديدًا — والباقي المستحق عليها بيظهر بالأحمر كمرجع بس. في الحالتين بيتسجل
# زيارة في الملف الطبي وبيتحدد الموعد "تم". لو المستخدم معهوش صلاحية تحصيل المدفوعات،
# السلوك زي قبل تمامًا — تحديد "تم" على طول من غير بوكس.)
# Run as: bash deploy7.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update =="
cd /tmp
curl -L -o clinic-app-batch7.tar.gz https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch7.tar.gz

echo "== extracting update =="
tar -xzf clinic-app-batch7.tar.gz -C /opt/clinic-app

echo "== starting app =="
systemctl start clinic-app

sleep 2
echo "== status =="
systemctl status clinic-app --no-pager
