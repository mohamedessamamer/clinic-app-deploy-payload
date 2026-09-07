#!/bin/bash
# Redeploy script for clinic-app - batch 8 (retry).
#
# Why this exists: after the first deploy8 run, live-testing on the actual site
# showed the patient-name link in the schedule always opening the medical file,
# even for reception/admin accounts (it should open the billing file for anyone
# who is not a doctor). The exact clinic-app-batch8.tar.gz file already sent to
# you was checked directly (unpacked and grepped) and DOES have the correct code
# for this - so the most likely explanation is that the site deployed from an
# older upload of clinic-app-batch8.tar.gz on GitHub (same filename, old content),
# or that raw.githubusercontent.com served a cached older copy of that file for a
# few minutes after the new upload. This script downloads with a cache-busting
# query string, verifies the new code actually landed on disk before rebuilding,
# and clears the old .next build cache just to be safe.
#
# BEFORE running this: make sure you (re-)uploaded the newest
# clinic-app-batch8.tar.gz (the one most recently sent to you) to the
# clinic-app-deploy-payload GitHub repo, overwriting the old file there.
#
# Run as: bash deploy8b.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update (cache-busted) =="
cd /tmp
rm -f clinic-app-batch8.tar.gz
curl -L -o clinic-app-batch8.tar.gz "https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch8.tar.gz?cachebust=$(date +%s)"

echo "== extracting update =="
tar -xzf clinic-app-batch8.tar.gz -C /opt/clinic-app

echo "== verifying the new code actually landed on disk =="
if grep -q "isDoctorView" /opt/clinic-app/src/app/front-desk/page.tsx; then
  echo "OK: front-desk/page.tsx has the new patient-link code."
else
  echo "PROBLEM: front-desk/page.tsx does NOT have the new code."
  echo "This means GitHub is still serving an old clinic-app-batch8.tar.gz."
  echo "Go re-upload the latest file to the GitHub repo (overwrite), wait a"
  echo "minute or two, then run this script again. Not rebuilding/restarting."
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
