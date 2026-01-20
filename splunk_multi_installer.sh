#!/bin/bash

# If there was a conversion to .txt, or the file system does not recognize the file, run the following command:
# sed -i 's/\r$//' file_name.sh

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
SPLUNK_TARBALL="/tmp/splunk-10.0.2-e2d18b4767e9-linux-amd64.tgz"
# Check if tarball exists
if [[ ! -f "$SPLUNK_TARBALL" ]]; then
    echo "ERROR: Splunk tarball not found at: $SPLUNK_TARBALL"
    echo "Please ensure the file exists before running this script."
    exit 1
fi

# Create splunk username and password
while true; do
    read -p "Enter Non-Root Username: " USERNAME
    # Validate username
    if [[ "$USERNAME" =~ [^a-zA-Z0-9] ]] || [ -z "$USERNAME" ]; then
        echo "Invalid username. Please enter a valid username (alphanumeric characters only)."
        continue
    fi
    while true; do
        # Get password from the user
        read -s -p "Enter Password for $USERNAME: " PASSWORD
        echo -e "\n"

        # Ensure password is not empty
        if [[ -z "$PASSWORD" ]]; then
            echo -e "\033[31mError: Password cannot be empty!\033[0m"
        else
            break
        fi
    done
    # Create the user with home directory and set password
    if id "$USERNAME" >/dev/null 2>&1; then
        echo -e "\033[33mUser $USERNAME already exists!\033[0m"
        break
    else
        if sudo useradd -m -s /bin/bash "$USERNAME" --password "$(openssl passwd -1 "$PASSWORD")" > /dev/null 2>&1; then
            break
        else
            echo -e "\033[31mError: Failed to create user $USERNAME !\033[0m"
        fi
    fi
done

# Get web password from the user
while true; do
    read -s -p "Enter Web Password for Splunk admin user (Password must be at least 8 characters): " WEB_PASSWORD
    echo

    # Ensure password is not empty
        if [[ -z "$WEB_PASSWORD" || ${#WEB_PASSWORD} -lt 8 ]]; then
            echo -e "\033[31mError: Password cannot be empty or have less than 8 characters!\033[0m"
        else
            break
        fi
done

cd /tmp || { echo "FATAL: Failed to change to /tmp"; exit 1; }
tar -xzvf "$SPLUNK_TARBALL" -C /opt || { echo "FATAL: Failed to extract Splunk"; exit 1; }
echo "✓ Splunk extracted successfully"


chown -R splunk: /opt/splunk ||  { echo "FATAL: Failed to set ownership"; exit 1; } 
echo "✓ Ownership set to splunk user"
echo

# Step 5: Configure Splunk Web (HTTPS)
if [[ "$SPLUNK_INSTANCE" != "PEER_NODE" ]]; then
# Indexer doesn't need web access.    
    if tee /opt/splunk/etc/system/local/web.conf > /dev/null <<EOF
[settings]
enableSplunkWebSSL = true
httpport = 8000

EOF
    then
        echo "✓ HTTPS enabled for Splunk Web using self-signed certificate."
    else
        echo "⚠ WARN: Failed to set web.conf"
    fi

fi
echo

# Step 6: Configure network inputs (TCP 9997 and UDP 10514)
chown -R splunk:splunk /opt/splunk ||  echo "FATAL: Failed to set ownership";
if tee /opt/splunk/etc/system/local/inputs.conf > /dev/null <<EOF
[splunktcp]

[splunktcp://9997]
index = main
disabled = 0

EOF
    then
        echo "✓ Enabled Splunk TCP input over 9997"
        if ! chown splunk:splunk /opt/splunk/etc/system/local/inputs.conf; then
            echo "⚠ WARN : Failed to set inputs.conf ownership"
        fi
    else
    # else for the tee
    echo "⚠ WARN: Failed to set inputs.conf"
fi
echo

# Step 7: Test Splunk start and stop
if \
    if ! runuser -l splunk -c "/opt/splunk/bin/splunk start --accept-license --seed-passwd $WEB_PASSWORD"; then echo "The command: /opt/splunk/bin/splunk start --accept-license --seed-passwd WEB_PASSWORD" failed!; fi
    if ! runuser -l splunk -c '/opt/splunk/bin/splunk stop'; then echo "⚠ WARN: Failed to stop Splunk"; fi
    if ! chown root:splunk /opt/splunk/etc/splunk-launch.conf; then echo "⚠ WARN: Failed to set splunk-launch.conf ownership"; fi
    if ! chmod 644 /opt/splunk/etc/splunk-launch.conf; then echo "FATAL: Failed to set splunk-launch.conf permissions";  fi
then
    echo
    echo "✓ Splunk test start and stop complete. Adjusted splunk-launch.conf to mitigate privilege escalation attack."
    echo
fi

# Step 8: Enable boot-start
output=$(/opt/splunk/bin/splunk enable boot-start -systemd-managed 1 -user splunk 2>&1)
if [ $? -eq 0 ]; then
    echo "✓ Boot-start enabled"
else
    echo "FATAL: Failed to enable boot-start"
    echo "Error details: $output"
fi
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
            echo "WARNING: No Application name provided."
        fi
        ;;
    CM)
        echo
        # echo "Step 1: Add licenses"
        # read -r -p "Enter path to license file: " license_path
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
                runuser -l splunk -c "/opt/splunk/bin/splunk edit cluster-config -mode manager -replication_factor ${replication_factor} -search_factor ${search_factor} -secret ${secret_key} -cluster_label ${cluster_label}" || echo "ERROR: Failed to configure cluster. Exiting...";
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
        MAX_RETRIES=2
        RETRY_COUNT=0
        while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do        
            read -r -p "Enter Cluster Manager IP/hostname: " cm_ip
            read -r -p "Enter secret key: " secret_key
        
            if [[ -z "$cm_ip" || -z "$secret_key" ]]; then
                echo "ERROR: Both Cluster Manager IP and secret key are required."
                ((RETRY_COUNT++))
        
                if [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; then
                    echo "Please try again. (Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)"
                    echo
                fi
                continue
            fi

            # 4.1 changes - optionally modify host name
            echo
            #read -r -p "Should edit host name? [y/N]: " edit_hostname_bool - deprecated
            read -r -p "Enter hostname or press Enter to skip: " hostname
            #if [[ "$edit_hostname_bool" =~ ^[Yy]$ ]]; then - deprecated
            if [[ -n "$hostname" ]]; then
                echo "This will edit /system/local/server.conf [general] stanza + /syste/local/inputs.conf [default] stanza"
                read -r -p "Enter the hostname: " hostname
                
                # Update inputs.conf
                echo "" >> /opt/splunk/etc/system/local/inputs.conf
                echo "[default]" >> /opt/splunk/etc/system/local/inputs.conf
                # Update server.conf
                echo "host = ${hostname}" >> /opt/splunk/etc/system/local/inputs.conf
                echo "" >> /opt/splunk/etc/system/local/server.conf
                echo "[general]" >> /opt/splunk/etc/system/local/server.conf
                echo "serverName = ${hostname}" >> /opt/splunk/etc/system/local/server.conf
                
            fi
            
            # 4.1 changes - optionally add multi site cluster config for peer node
            read -r -p "Enter current site name (for multi-site clusters) or press Enter to skip: " site
            # original command without multi-site config
            cmd="/opt/splunk/bin/splunk edit cluster-config -mode peer -manager_uri https://${cm_ip}:8089 -replication_port 9887 -secret ${secret_key}"
            if [[ -n "$site" ]]; then
                # if site is provided, add site to the command
                cmd+= "-site ${site}"
                if runuser -l splunk -c "$cmd" ; then
                    echo "✓ Peer node configured. Cluster Manager address: ${cm_ip}:8089."
                    echo
                fi
                echo "Restarting Splunk to apply cluster configuration..."
                if runuser -l splunk -c "/opt/splunk/bin/splunk restart"; then
                    echo "✓ Splunk restarted successfully"
                    echo "✓ Peer node is now connected to Cluster Manager"
                else
                    echo "ERROR: Failed to restart Splunk. Manual restart required."
                    exit 1
                fi
                break
                
            else
                echo "ERROR: Failed to configure peer node with provided credentials."
                ((RETRY_COUNT++))
            
                if [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; then
                    echo "Please verify the Cluster Manager IP and secret key, then try again."
                    echo "(Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)"
                    echo
                else
                    echo "ERROR: Maximum retry attempts reached. Exiting after trying to configure \"edit cluster-config -mode peer\""
                    exit 1
                fi
            fi
            
        done
        ;;
esac

echo
echo "HAPPY SPLUNKING!!! Splunk PS Bynet Team"
echo
echo

#End of File