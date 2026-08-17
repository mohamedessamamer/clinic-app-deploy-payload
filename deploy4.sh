#!/bin/bash
# Batch 4 deploy script for clinic-app
# (X delete-mark + confirm on patient images, full-quality image download with
# date, and a fix for large photo/x-ray uploads failing due to two separate
# Next.js body-size limits).
# Run as: bash deploy4.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update =="
cd /tmp
curl -L -o clinic-app-batch4.tar.gz https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch4.tar.gz

echo "== extracting update =="
tar -xzf clinic-app-batch4.tar.gz -C /opt/clinic-app

echo "== starting app =="
systemctl start clinic-app

sleep 2
echo "== status =="
systemctl status clinic-app --no-pager
