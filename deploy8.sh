#!/bin/bash
# Batch 8 deploy script for clinic-app
# Three fixes on top of batch 7 (the billing box):
# 1) Service search in the billing box is now two separate boxes - one for the
#    service name (substring match, same as before) and one for the service code
#    (EXACT match only) - so typing "0" only matches the code "0" service and not
#    any code containing a zero (100, 120, 160, ...).
# 2) Invoices now store and display the original price before any discount, next
#    to the final amount, on the /invoices page and the patient billing page.
# 3) A "done" appointment can no longer be cancelled or reverted, whoever marked
#    it done. If a doctor (no collect-payments permission) marks it done, they now
#    get a "required payment" box to pick the service/price (no actual payment is
#    collected there) - reception sees this on the schedule right away as a note
#    next to the "needs billing" badge, and can open the real billing box for that
#    appointment afterwards (doctors cannot reopen it themselves).
# Run as: bash deploy8.sh
set -e

echo "== stopping app =="
systemctl stop clinic-app

echo "== backing up data =="
cp -r /opt/clinic-app/data "/opt/clinic-app/data.backup-$(date +%Y%m%d%H%M%S)"

echo "== downloading update =="
cd /tmp
curl -L -o clinic-app-batch8.tar.gz https://raw.githubusercontent.com/mohamedessamamer/clinic-app-deploy-payload/main/clinic-app-batch8.tar.gz

echo "== extracting update =="
tar -xzf clinic-app-batch8.tar.gz -C /opt/clinic-app

echo "== rebuilding app (next start serves a pre-built .next - without this step the new"
echo "   source files sit on disk but next start keeps serving the OLD compiled build) =="
cd /opt/clinic-app
npm run build

echo "== starting app =="
systemctl start clinic-app

sleep 2
echo "== status =="
systemctl status clinic-app --no-pager
