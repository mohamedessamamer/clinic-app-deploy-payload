#!/bin/bash
# Batch 9 deploy script for clinic-app
# 1) Patient photo/x-ray gallery ("الصور والأشعة"): thumbnails now always fully
#    fill their box (a lone photo, or the odd-one-out in a group of 3, now spans
#    the full card width instead of leaving a blank half-box next to it). Deleting
#    the last photo in a group now also removes that group's card entirely (no
#    more leftover empty "لا صور" box) - and the empty group row is cleaned up
#    from the database too.
# 2) The photo upload box now supports drag-and-drop (in addition to the existing
#    "choose files" multi-select) - drag one or several images/PDFs onto the
#    dashed box to add them all at once.
# 3) The patient's "سجل الكشوفات والزيارات" (visits) table now keeps fixed column
#    widths on any screen size - a long unbroken piece of text in "المعالجة"
#    wraps and grows the row downward instead of stretching the table sideways
#    and forcing horizontal scrolling.
# Run as: bash deploy9.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch9.tar.gz
curl -L -o clinic-app-batch9.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch9.tar.gz?cachebust=$(date +%s)"

echo "== extracting update =="
tar -xzf clinic-app-batch9.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "nonEmptyGroups" /opt/clinic-app/src/components/PatientImageGallery.tsx; then
  echo "OK: PatientImageGallery.tsx has the new code."
else
  echo "PROBLEM: PatientImageGallery.tsx does NOT have the new code."
  echo "GitHub is still serving an old clinic-app-batch9.tar.gz - go re-upload it"
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
