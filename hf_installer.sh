#!/bin/bash
echo
echo '##############################################'
echo '#                                            #'
echo '# Welcome to the Splunk HF-auto-installer #'
echo '# Note: You will change the Splunk   	#'
echo '# Web admin password upon first login.       #'
echo '#                                            #'
echo '##############################################'
echo
echo

# Step 1: Disable Transparent Huge Pages (THP)
echo "never" > /sys/kernel/mm/transparent_hugepage/enabled
echo "never" > /sys/kernel/mm/transparent_hugepage/defrag
echo "[Unit]" > /etc/systemd/system/disable-thp.service
echo "Description=Disable Transparent Huge Pages" >> /etc/systemd/system/disable-thp.service
echo "" >> /etc/systemd/system/disable-thp.service
echo "[Service]" >> /etc/systemd/system/disable-thp.service
echo "Type=simple" >> /etc/systemd/system/disable-thp.service
echo 'ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag"' >> /etc/systemd/system/disable-thp.service
echo "Type=simple" >> /etc/systemd/system/disable-thp.service
echo "" >> /etc/systemd/system/disable-thp.service
echo "[Install]" >> /etc/systemd/system/disable-thp.service
echo "WantedBy=multi-user.target" >> /etc/systemd/system/disable-thp.service
systemctl daemon-reload ||  echo "FATAL: Failed to reload daemon"
systemctl start disable-thp ||  echo "FATAL: Failed to start disable-thp"
systemctl enable disable-thp ||  echo "FATAL: Failed to enable disable-thp"
echo
echo "✓ Transparent Huge Pages (THP) Disabled."
echo

# Step 2: Increase system limits (ulimit)
ulimit -n 64000 ||  echo "WARNING: Failed to set file descriptor limit"
ulimit -u 20480 ||  echo "WARNING: Failed to set process limit"
echo "DefaultLimitFSIZE=-1" >> /etc/systemd/system.conf ||  echo "FATAL: Failed to set system limits"
echo "DefaultLimitNOFILE=64000" >> /etc/systemd/system.conf ||  echo "FATAL: Failed to set file limits"  
echo "DefaultLimitNPROC=20480" >> /etc/systemd/system.conf ||  echo "FATAL: Failed to set process limits"  
echo
echo "✓ ulimit Increased."
echo

# Step 3: Extract and prepare Splunk installation
cd /tmp ||  echo "FATAL: Failed to change to /tmp"
tar -xzvf /tmp/splunk-10.0.2-e2d18b4767e9-linux-amd64.tgz -C /opt ||  echo "FATAL: Failed to extract Splunk"
echo "✓ Splunk extracted successfully"
mkdir -p /opt/splunk ||  echo "FATAL: Failed to create directory"
echo "✓ Splunk directory created"
chown -R splunk: /opt/splunk ||  echo "FATAL: Failed to set ownership"
echo "✓ Ownership set to splunk user"
echo

# Step 5: Configure Splunk Web (HTTPS)#
echo "[settings]" > /opt/splunk/etc/system/local/web.conf ||  echo "FATAL: Failed to create web.conf"
echo "enableSplunkWebSSL = true" >> /opt/splunk/etc/system/local/web.conf ||  echo "FATAL: Failed to set SSL"
echo "httpport = 8000" >> /opt/splunk/etc/system/local/web.conf || echo "FATAL: Failed to set HTTP port"
echo "✓ HTTPS enabled for Splunk Web using self-signed certificate."
echo

# Step 6: Configure network inputs (TCP 9997 and UDP 10514)
chown -R splunk:splunk /opt/splunk ||  echo "FATAL: Failed to set ownership"
echo "[splunktcp]" > /opt/splunk/etc/system/local/inputs.conf ||  echo "FATAL: Failed to create inputs.conf"
echo "[splunktcp://9997]" >> /opt/splunk/etc/system/local/inputs.conf ||  echo "FATAL: Failed to add TCP input"
echo "index = main" >> /opt/splunk/etc/system/local/inputs.conf
echo "disabled = 0" >> /opt/splunk/etc/system/local/inputs.conf
echo "" >> /opt/splunk/etc/system/local/inputs.conf
echo "[udp://10514]" >> /opt/splunk/etc/system/local/inputs.conf ||  echo "FATAL: Failed to add UDP input"
echo "index = main" >> /opt/splunk/etc/system/local/inputs.conf
echo "disabled = 0" >> /opt/splunk/etc/system/local/inputs.conf
chown splunk:splunk /opt/splunk/etc/system/local/inputs.conf ||  echo "FATAL: Failed to set inputs.conf ownership"
echo
echo "✓ Enabled Splunk TCP input over 9997 and UDP traffic input over 10514."
echo

# Step 7: Test Splunk start and stop
runuser -l splunk -c '/opt/splunk/bin/splunk start --accept-license' ||  echo "FATAL: Failed to start Splunk"
runuser -l splunk -c '/opt/splunk/bin/splunk stop' ||  echo "FATAL: Failed to stop Splunk"
chown root:splunk /opt/splunk/etc/splunk-launch.conf ||  echo "FATAL: Failed to set splunk-launch.conf ownership"
chmod 644 /opt/splunk/etc/splunk-launch.conf ||  echo "FATAL: Failed to set splunk-launch.conf permissions"
echo
echo "✓ Splunk test start and stop complete. Adjusted splunk-launch.conf to mitigate privilege escalation attack."
echo

# Step 8: Enable boot-start
/opt/splunk/bin/splunk enable boot-start -systemd-managed 1  -user splunk ||  echo "FATAL: Failed to enable boot-start"
echo "✓ Boot-start enabled"
echo

# Step 9: Reload systemd and start Splunkd service
systemctl daemon-reload ||  echo "FATAL: Failed to reload daemon"
systemctl start Splunkd.service ||  echo "FATAL: Failed to start Splunkd service"
echo "✓ Splunkd service started"
echo

if [[ -f /opt/splunk/bin/splunk ]]; then
    echo "=========================================="
    echo "Splunk Enterprise"
    cat /opt/splunk/etc/splunk.version | head -1
    echo "has been installed, configured, and started!"
    echo "=========================================="
    echo
    echo "Visit the Splunk server using https://hostNameORip:8000 as mentioned above."
    echo
    echo "HAPPY SPLUNKING!!! Splunk PS Bynet Team"
    echo
    echo
else
    echo "FATAL: Splunk Enterprise has FAILED install!"
    exit 1
fi

# Deployment server configuration
echo
read -r -p "Should we set deployment server? [y/N]: " set_ds
if [[ "$set_ds" =~ ^[Yy]$ ]]; then
    read -r -p "Enter deployment server IP/hostname: " ds_ip
    if [[ -n "$ds_ip" ]]; then
        runuser -l splunk -c "/opt/splunk/bin/splunk set deploy-poll ${ds_ip}:8089" || echo "WARNING: Failed to set deployment server"
    else
        echo "Skipping deployment server configuration."
    fi
fi

#End of File
