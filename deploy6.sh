#!/bin/bash
# Batch 6 deploy script for clinic-app
# (الجدول المركزي بقى ظاهر على أكونت الدكتور برضه، مع نفس التزامن التلقائي مع
# الاستقبال. صلاحيتين جداد قابلين للتحكم من صفحة الإعدادات لكل مستخدم لوحده:
# "عرض الجدول المركزي لكل الغرف" و"التعديل في الجدول المركزي (حجز/تغيير حالة)".
# افتراضيًا الدكتور بيشوف شيفته بس وبشكل عرض فقط، والأدمن يقدر يوسّعله الصلاحيات
# من الإعدادات لو حابب).
# Run as: bash deploy6.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update =="
cd /tmp
curl -L -o clinic-app-batch6.tar.gz https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch6.tar.gz

echo "== extracting update =="
tar -xzf clinic-app-batch6.tar.gz -C /opt/clinic-app

echo "== starting app =="
systemctl start clinic-app

sleep 2
echo "== status =="
systemctl status clinic-app --no-pager
