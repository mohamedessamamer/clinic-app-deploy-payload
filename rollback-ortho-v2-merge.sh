#!/bin/bash
# رجوع سريع للكود القديم (قبل دمج شارت التقويم v2) — بيستخدم النسخة
# الاحتياطية اللي سكريبت النشر عملها لوحده قبل ما يستبدل src.
#
# Run as: bash rollback-ortho-v2-merge.sh

set -e

BACKUP_DIR=$(ls -dt /opt/clinic-app-src-backup-* 2>/dev/null | head -n1)

if [ -z "$BACKUP_DIR" ]; then
  echo "PROBLEM: مفيش نسخة احتياطية باسم /opt/clinic-app-src-backup-* على السيرفر."
  exit 1
fi

echo "== هرجع للنسخة الاحتياطية: $BACKUP_DIR =="

echo "== stopping app =="
systemctl stop clinic-app

echo "== restoring old src =="
rm -rf /opt/clinic-app/src
cp -r "$BACKUP_DIR/src" /opt/clinic-app/src

echo "== rebuilding old code =="
cd /opt/clinic-app
npm run build

echo "== starting app =="
systemctl start clinic-app

sleep 2
echo "== status =="
systemctl status clinic-app --no-pager

echo ""
echo "== تم الرجوع للشارت القديم =="
