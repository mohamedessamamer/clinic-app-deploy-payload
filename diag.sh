#!/bin/bash
echo "=== systemctl status ==="
systemctl status clinic-app --no-pager -l | head -20
echo "=== journalctl last 150 lines ==="
journalctl -u clinic-app -n 150 --no-pager
echo "=== env file check (keys only, no values) ==="
if [ -f /opt/clinic-app/.env.production ]; then
  grep -o '^[A-Z_]*=' /opt/clinic-app/.env.production
else
  echo "NO .env.production FOUND"
fi
echo "=== systemd service EnvironmentFile / Environment lines ==="
cat /etc/systemd/system/clinic-app.service 2>/dev/null | grep -i -E "environment|execstart|workingdirectory"
echo "=== process start time ==="
systemctl show clinic-app --property=ActiveEnterTimestamp
echo "=== DIAG_COMPLETE ==="
