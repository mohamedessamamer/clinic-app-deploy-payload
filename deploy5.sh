#!/bin/bash
# Batch 5 deploy script for clinic-app
# (الجدول المركزي الموحّد للاستقبال: كل الغرف والمواعيد في جدول واحد، حجز بالدوس
# على خانة فاضية، تغيير الحالة بالزر اليمين (حضر/تم/إلغاء)، بحث فوري عن مريض،
# تزامن أوتوماتيك كل 4-5 ثواني، صفحة الاستقبال الرئيسية بقت الجدول ده مباشرة،
# وإزالة رسائل الترحيب الزايدة من الصفحة الرئيسية).
# Run as: bash deploy5.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update =="
cd /tmp
curl -L -o clinic-app-batch5.tar.gz https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch5.tar.gz

echo "== extracting update =="
tar -xzf clinic-app-batch5.tar.gz -C /opt/clinic-app

echo "== starting app =="
systemctl start clinic-app

sleep 2
echo "== status =="
systemctl status clinic-app --no-pager
