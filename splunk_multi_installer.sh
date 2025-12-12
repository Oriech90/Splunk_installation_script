#!/bin/bash
echo
echo '##############################################'
echo '#                                            #'
echo '# Welcome to the Splunk Installation Script#'
echo '#                                            #'
echo '##############################################'
echo
echo

# Configuration Menu
echo "Choose Splunk Instance:"
echo "1) HF / SH "
echo "2) Deployment Client"
echo "3) Deployment Server"
echo "4) Cluster Manager"
echo "5) Peer Node (Indexer)"
echo
read -r -p "Enter your choice [1-5]: " config_choice

case $config_choice in
    1)
        SPLUNK_INSTANCE="HF_SH"
        echo "✓ HF / SH mode selected"
        ;;
    2)
        SPLUNK_INSTANCE="DEPLOYMENT_CLIENT"
        echo "✓ Deployment Client mode selected"
        ;;
    3)
        SPLUNK_INSTANCE="DEPLOYMENT_SERVER"
        echo "✓ Deployment Server mode selected"
        ;;
    4)
        SPLUNK_INSTANCE="CM"
        echo "✓ Cluster Manager mode selected"
        ;;
    5)
        SPLUNK_INSTANCE="PEER_NODE"
        echo "✓ Peer Node (Indexer) mode selected"
        ;;
    *)
        echo "Invalid choice. Exiting..."
        exit 1
        ;;
esac

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
systemctl daemon-reload ||  echo "FATAL: Failed to reload daemon"; 
systemctl start disable-thp ||  echo "FATAL: Failed to start disable-thp"; 
systemctl enable disable-thp ||  echo "FATAL: Failed to enable disable-thp"; 
echo
echo "✓ Transparent Huge Pages (THP) Disabled."
echo

# Step 2: Increase system limits (ulimit)
ulimit -n 64000 ||  echo "WARNING: Failed to set file descriptor limit"; 
ulimit -u 20480 ||  echo "WARNING: Failed to set process limit"; 
echo "DefaultLimitFSIZE=-1" >> /etc/systemd/system.conf ||  echo "FATAL: Failed to set system limits";  
echo "DefaultLimitNOFILE=64000" >> /etc/systemd/system.conf ||  echo "FATAL: Failed to set file limits";  
echo "DefaultLimitNPROC=20480" >> /etc/systemd/system.conf ||  echo "FATAL: Failed to set process limits";  
echo
echo "✓ ulimit Increased."
echo

# Step 3: Extract and prepare Splunk installation
cd /tmp ||  echo "FATAL: Failed to change to /tmp"; 
tar -xzvf /tmp/splunk-10.0.2-e2d18b4767e9-linux-amd64.tgz -C /opt ||  echo "FATAL: Failed to extract Splunk";  
echo "✓ Splunk extracted successfully"
mkdir -p /opt/splunk ||  echo "FATAL: Failed to create directory";  
echo "✓ Splunk directory created"
chown -R splunk: /opt/splunk ||  echo "FATAL: Failed to set ownership";  
echo "✓ Ownership set to splunk user"
echo

# Step 5: Configure Splunk Web (HTTPS)
echo "[settings]" > /opt/splunk/etc/system/local/web.conf ||  echo "FATAL: Failed to create web.conf";  
echo "enableSplunkWebSSL = true" >> /opt/splunk/etc/system/local/web.conf ||  echo "FATAL: Failed to set SSL";  
echo "httpport = 8000" >> /opt/splunk/etc/system/local/web.conf || echo "FATAL: Failed to set HTTP port"; 
echo "✓ HTTPS enabled for Splunk Web using self-signed certificate."
echo

# Step 6: Configure network inputs (TCP 9997 and UDP 10514)
chown -R splunk:splunk /opt/splunk ||  echo "FATAL: Failed to set ownership";  
echo "[splunktcp]" > /opt/splunk/etc/system/local/inputs.conf ||  echo "FATAL: Failed to create inputs.conf";  
echo "[splunktcp://9997]" >> /opt/splunk/etc/system/local/inputs.conf ||  echo "FATAL: Failed to add TCP input";  
echo "index = main" >> /opt/splunk/etc/system/local/inputs.conf
echo "disabled = 0" >> /opt/splunk/etc/system/local/inputs.conf
echo "" >> /opt/splunk/etc/system/local/inputs.conf
echo "[udp://10514]" >> /opt/splunk/etc/system/local/inputs.conf ||  echo "FATAL: Failed to add UDP input"; 
echo "index = main" >> /opt/splunk/etc/system/local/inputs.conf
echo "disabled = 0" >> /opt/splunk/etc/system/local/inputs.conf
chown splunk:splunk /opt/splunk/etc/system/local/inputs.conf ||  echo "FATAL: Failed to set inputs.conf ownership";  
echo
echo "✓ Enabled Splunk TCP input over 9997 and UDP traffic input over 10514."
echo

# Step 7: Test Splunk start and stop
runuser -l splunk -c '/opt/splunk/bin/splunk start --accept-license' ||  echo "FATAL: Failed to start Splunk"; 
runuser -l splunk -c '/opt/splunk/bin/splunk stop' ||  echo "FATAL: Failed to stop Splunk"; 
chown root:splunk /opt/splunk/etc/splunk-launch.conf ||  echo "FATAL: Failed to set splunk-launch.conf ownership"; 
chmod 644 /opt/splunk/etc/splunk-launch.conf ||  echo "FATAL: Failed to set splunk-launch.conf permissions";  
echo
echo "✓ Splunk test start and stop complete. Adjusted splunk-launch.conf to mitigate privilege escalation attack."
echo

# Step 8: Enable boot-start
/opt/splunk/bin/splunk enable boot-start -systemd-managed 1  -user splunk ||  echo "FATAL: Failed to enable boot-start"; 
echo "✓ Boot-start enabled"
echo

# Step 9: Reload systemd and start Splunkd service
systemctl daemon-reload ||  echo "FATAL: Failed to reload daemon";
systemctl start Splunkd.service ||  echo "FATAL: Failed to start Splunkd service";
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
else
    echo "FATAL: Splunk Enterprise has FAILED install!"
    exit 1
fi

# Role-specific configuration
case $SPLUNK_INSTANCE in
    HF_SH)
        echo
        echo "✓ HF / SH configuration complete"
        ;;
    DEPLOYMENT_CLIENT)
        echo
        read -r -p "Enter deployment server IP/hostname: " ds_ip
        if [[ -n "$ds_ip" ]]; then
            runuser -l splunk -c "/opt/splunk/bin/splunk set deploy-poll ${ds_ip}:8089" || echo "WARNING: Failed to set deployment server"
            echo "✓ Deployment client configured: ${ds_ip}:8089"
        else
            echo "WARNING: No deployment server IP provided."
        fi
        ;;
    DEPLOYMENT_SERVER)
        echo
        read -r -p "Creating an app in deployment-apps. Please give it a name: " app_name
        if [[ -n "$app_name" ]]; then
            runuser -l splunk -c "mkdir /opt/splunk/etc/deployment-apps/$app_name" || echo "WARNING: Failed to set deployment server"
            echo "✓ Deployment server app created: /opt/splunk/etc/deployment-apps/$app_name"
        else
            echo "WARNING: No deployment server IP provided."
        fi
        ;;
    CM)
        echo
        echo "Step 1: Add licenses"
        read -r -p "Enter path to license file: " license_path
        #if [[ -n "$license_path" ]]; then
        #    runuser -l splunk -c "/opt/splunk/bin/splunk add licenses ${license_path}" || echo "WARNING: Failed to add license"
        #    echo "✓ License added"
        #fi
        read -r -p "Is this a multi-site cluster? [y/n]: " is_multi_site
        echo
        
        if [[ "$is_multi_site" =~ ^[Yy]$ ]]; then
            read -r -p "Enter available sites (comma-separated, e.g., site1,site2): " available_sites
            read -r -p "Enter current site (e.g., site1): " current_site
            read -r -p "Enter site replication factor (e.g., origin:2,total:3): " site_replication_factor
            read -r -p "Enter site search factor (e.g., origin:1,total:2): " site_search_factor
            read -r -p "Enter secret key: " secret_key
            read -r -p "Enter cluster label (e.g., cluster1): " cluster_label
            
            if [[ -n "$available_sites" && -n "$current_site" && -n "$site_replication_factor" && -n "$site_search_factor" && -n "$secret_key" && -n "$cluster_label" ]]; then
                runuser -l splunk -c "/opt/splunk/bin/splunk edit cluster-config -mode manager -multisite true -available_sites ${available_sites} -site ${current_site} -site_replication_factor ${site_replication_factor} -site_search_factor ${site_search_factor} -secret ${secret_key} -cluster_label ${cluster_label}" || echo "ERROR: Failed to configure multi-site cluster. Exiting..."; exit 1
                echo "✓ Multi-site Cluster Manager configured"
            else
                echo "ERROR: Missing required multi-site configuration parameters. Exiting..."; exit 1
            fi
        else
            read -r -p "Enter replication factor (e.g., 4): " replication_factor
            read -r -p "Enter search factor (e.g., 3): " search_factor
            read -r -p "Enter secret key: " secret_key
            read -r -p "Enter cluster label (e.g., cluster1): " cluster_label
            
            if [[ -n "$replication_factor" && -n "$search_factor" && -n "$secret_key" && -n "$cluster_label" ]]; then
                runuser -l splunk -c "/opt/splunk/bin/splunk edit cluster-config -mode manager -replication_factor ${replication_factor} -search_factor ${search_factor} -secret ${secret_key} -cluster_label ${cluster_label}" || echo "ERROR: Failed to configure cluster. Exiting..."; exit 1
                echo "✓ Cluster Manager configured"
            else
                echo "ERROR: Missing required cluster configuration parameters. Exiting..."; exit 1
            fi
        fi
        
        echo
        read -r -p "Restart Splunk now? [y/N]: " restart_now
        if [[ "$restart_now" =~ ^[Yy]$ ]]; then
            runuser -l splunk -c "/opt/splunk/bin/splunk restart" || echo "ERROR: Failed to restart Splunk. Exiting..."; exit 1
            echo "✓ Splunk restarted"
        fi
        ;;
    PEER_NODE)
        echo
        read -r -p "Enter Cluster Manager IP/hostname: " cm_ip
        read -r -p "Enter secret key: " secret_key
        
        if [[ -n "$cm_ip" && -n "$secret_key" ]]; then
            runuser -l splunk -c "/opt/splunk/bin/splunk edit cluster-config -mode peer -manager_uri https://${cm_ip}:8089 -replication_port 9887 -secret ${secret_key}" || echo "WARNING: Failed to configure peer node"
            echo "✓ Peer node configured. Splunk must be restarted to apply changes."
            echo
            read -r -p "Restart Splunk now? [y/N]: " restart_now
            if [[ "$restart_now" =~ ^[Yy]$ ]]; then
                runuser -l splunk -c "/opt/splunk/bin/splunk restart" || echo "WARNING: Failed to restart Splunk"
                echo "✓ Splunk restarted"
            fi
        else
            echo "WARNING: Missing required peer configuration parameters"
        fi
        ;;
esac

echo
echo "HAPPY SPLUNKING!!! Splunk PS Bynet Team"
echo
echo

#End of File