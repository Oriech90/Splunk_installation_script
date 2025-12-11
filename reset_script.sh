#!/bin/bash
set -e

echo "Removing Splunk installation..."
sudo systemctl stop Splunkd.service || true
sudo rm -rf /opt/splunk && echo "Splunk directory removed" || echo "Failed to remove /opt/splunk"
sudo userdel -r splunk && echo "Splunk user removed" || echo "Failed to remove splunk user"
sudo rm -f /etc/systemd/system/disable-thp.service && echo "THP service removed" || echo "Failed to remove THP service"
sudo systemctl daemon-reload
echo "Splunk installation removed."