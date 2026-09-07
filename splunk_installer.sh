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

configure_cluster_member() {
    local MODE=$1  # "peer" or "searchhead"
    local cm_ip secret_key site hostname
    local MAX_RETRIES=2
    local RETRY_COUNT=0

    while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
        read -r -p "Enter Cluster Manager IP/hostname: " cm_ip
        read -r -p "Enter secret key: " secret_key

        if [[ -z "$cm_ip" || -z "$secret_key" ]]; then
            echo "ERROR: Both Cluster Manager IP and secret key are required."
            (( RETRY_COUNT++ ))
            [[ $RETRY_COUNT -lt $MAX_RETRIES ]] && echo "Try again. (Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)" && continue
            echo "ERROR: Max retries reached. Exiting."
            return 1
        fi

        # Optional hostname
        read -r -p "Enter current hostname or press Enter to skip (fill only if the host doesn't have meaningful name): " hostname
        if [[ -n "$hostname" ]]; then
            tee -a /opt/splunk/etc/system/local/inputs.conf > /dev/null <<EOF
[default]
host = ${hostname}

EOF
            chown -R splunk:splunk /opt/splunk
            runuser -l splunk -c "/opt/splunk/bin/splunk set servername ${hostname}" || \
                echo "WARNING: Failed to set servername"
        fi

        # Build base command — peer needs replication_port, searchhead does not
        local cmd="/opt/splunk/bin/splunk edit cluster-config \
            -mode ${MODE} \
            -manager_uri https://${cm_ip}:8089 \
            -secret ${secret_key}"

        [[ "$MODE" == "peer" ]] && cmd+=" -replication_port 9887"

        # Optional: multi-site
        read -r -p "Enter site name for multi-site cluster or press Enter to skip (for example site1): " site
        [[ -n "$site" ]] && cmd+=" -site ${site}"

        if runuser -l splunk -c "$cmd"; then
            echo "✓ ${MODE} configured. Cluster Manager: ${cm_ip}:8089"

            echo
            read -r -p "Restart Splunk now to apply cluster config? [y/N]: " restart_now
            if [[ "$restart_now" =~ ^[Yy]$ ]]; then
                systemctl restart Splunkd.service || \
                    { echo "ERROR: Restart failed. Manual restart required."; return 1; }
                echo "✓ Splunk restarted"
            fi
            return 0
        else
            echo "ERROR: Failed to configure cluster-config for mode: ${MODE}."
            (( RETRY_COUNT++ ))
            [[ $RETRY_COUNT -lt $MAX_RETRIES ]] && \
                echo "Verify CM IP and secret key. (Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)" && continue
        fi
    done

    echo "ERROR: Max retries reached. Exiting."
    return 1
}

configure_deployment_client() {
    read -r -p "Configure a Deployment Client? [y/N]: " use_ds
    [[ ! "$use_ds" =~ ^[Yy]$ ]] && return 0

    local MAX_RETRIES=2
    local RETRY_COUNT=0

    while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
        read -r -p "Enter Deployment Server IP/hostname: " ds_ip

        if [[ -z "$ds_ip" ]]; then
            echo "ERROR: Deployment Server IP/hostname cannot be empty."
            (( RETRY_COUNT++ ))
            [[ $RETRY_COUNT -lt $MAX_RETRIES ]] && echo "Try again. (Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)" && continue
            echo "WARNING: Max retries reached. Skipping DS configuration."
            return 1
        fi

        if runuser -l splunk -c "/opt/splunk/bin/splunk set deploy-poll ${ds_ip}:8089"; then
            echo "✓ Deployment client configured: ${ds_ip}:8089"
            return 0
        else
            echo "ERROR: Failed to set deployment server."
            (( RETRY_COUNT++ ))
            [[ $RETRY_COUNT -lt $MAX_RETRIES ]] && echo "Try again. (Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)" && continue
        fi
    done

    echo "WARNING: Max retries reached. Skipping DS configuration."
    return 1
}

configure_send_internal_data_to_indexers() {
    read -r -p "Forward internal data to indexers? [y/N]: " send_internal
    [[ ! "$send_internal" =~ ^[Yy]$ ]] && return 0

    local indexers=()
    echo "Enter indexer IPs/hostnames one at a time. Press Enter with no input when done."
    echo

    while true; do
        read -r -p "Enter indexer IP/hostname (or press Enter to finish): " indexer_ip

        # Empty input = done
        [[ -z "$indexer_ip" ]] && break

        indexers+=("${indexer_ip}:9997")
        echo "  + Added ${indexer_ip}:9997"
    done

    if [[ ${#indexers[@]} -eq 0 ]]; then
        echo "WARNING: No indexers provided. Skipping internal data forwarding."
        return 1
    fi

    # Build comma-separated server list
    local server_list
    server_list=$(IFS=','; echo "${indexers[*]}")

    # Write outputs.conf
    local outputs_conf="/opt/splunk/etc/system/local/outputs.conf"
    tee -a "$outputs_conf" > /dev/null <<EOF

[tcpout:splunk_internal_group]
server = ${server_list}

[tcpout-server://splunk_internal_group]
EOF

    chown splunk:splunk "$outputs_conf" 

    echo
    echo "✓ Internal data forwarding configured to: ${server_list}"
    return 0
}

# Configuration Menu
echo "Choose Splunk Instance:"
echo "1) Single Server Deployment (Usually Test / Dev environment)"
echo "2) Heavy Forwarder"
echo "3) Search Head"
echo "4) Deployment Server"
echo "5) Cluster Manager"
echo "6) Peer Node (Indexer)"
echo
read -r -p "Enter your choice [1-6]: " config_choice

case $config_choice in
    1)        
        SPLUNK_INSTANCE="SINGLE_SERVER"
        echo "✓ Single Server mode selected"
        ;;
    2)
        SPLUNK_INSTANCE="HF"
        echo "✓ Heavy Forwarder mode selected"
        ;;
    3)
        SPLUNK_INSTANCE="SH"
        echo "✓ Search Head mode selected"
        ;;    
    4)
        SPLUNK_INSTANCE="DEPLOYMENT_SERVER"
        echo "✓ Deployment Server mode selected"
        ;;
    5)
        SPLUNK_INSTANCE="CM"
        echo "✓ Cluster Manager mode selected"
        ;;
    6)
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

# Pre step: Check if Splunk is already installed
if [[ -d "/opt/splunk" ]]; then
    echo "⚠ WARNING: Splunk appears to already be installed at /opt/splunk"
    read -r -p "Do you want to continue with installation anyway? 
    (This might override conf files!!!!!!!!) [y/N]: " continue_install
    if [[ ! "$continue_install" =~ ^[Yy]$ ]]; then
        echo "Exiting installation script."
        exit 0
    fi
    echo
fi


# Step 1: Disable Transparent Huge Pages (THP)
{
    echo "never" > /sys/kernel/mm/transparent_hugepage/enabled
    echo "never" > /sys/kernel/mm/transparent_hugepage/defrag
} 2>/dev/null
# Create the service unit
cat <<EOF > /etc/systemd/system/disable-thp.service
[Unit]
Description=Disable Transparent Huge Pages

[Service]
Type=simple
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag"

[Install]
WantedBy=multi-user.target
EOF
# Reload and Start - Only warn if it fails
if systemctl daemon-reload && systemctl enable disable-thp --now &>/dev/null; then
    echo "✓ Transparent Huge Pages (THP) Disabled successfully."
else
    echo "⚠ WARNING: Failed to configure THP service. Splunk may experience performance issues."
    echo "  Manual fix: Ensure THP is 'never' in /sys/kernel/mm/transparent_hugepage/enabled"
fi
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

# Step 3: Prepare Splunk installation
while true; do
    read -i "/tmp/" -e -p "Enter the full path to the Splunk tarball (e.g., /tmp/splunk-9.3.2.tgz): " SPLUNK_TARBALL
    if [[ -f "$SPLUNK_TARBALL" ]]; then
        echo "✓ Found tarball at $SPLUNK_TARBALL"
        break
    else
        echo "❌ ERROR: File $SPLUNK_TARBALL does not exist. Please check the path and try again."
    fi
done


# Create splunk username and password
while ! id "splunk" &>/dev/null; do
    read -p "Enter Non-Root Username: " USERNAME
    # Validate username
    if [[ "$USERNAME" =~ [^a-zA-Z0-9] ]] || [ -z "$USERNAME" ]; then
        echo "Invalid username. Please enter a valid username (alphanumeric characters only)."
        continue
    fi
    while true; do
        # Get password from the user
        echo "NOTE: If you are in an organization: Ensure the password complies with your Organization's Password Policy."
        echo
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


tar -xzvf "$SPLUNK_TARBALL" -C /opt || { echo "❌ FATAL: Failed to extract Splunk"; exit 1; }
echo "✓ Splunk extracted successfully"


chown -R splunk:splunk /opt/splunk ||  { echo "WARN: Failed to set ownership";  } 
echo "✓ Ownership set to splunk user"
echo

# Step 4: Test Splunk start and stop
if runuser -l splunk -c "/opt/splunk/bin/splunk start --accept-license"; then
    echo "Stopping Splunk to finalize configuration..."
    if runuser -l splunk -c '/opt/splunk/bin/splunk stop'; then
        echo "✓ Splunk initial setup test complete."
    else
        echo "⚠ WARNING: Splunk started but failed to stop cleanly."
    fi
else
    echo "❌ FATAL: Splunk failed to start. Check /opt/splunk/var/log/splunk/splunkd.log"
    exit 1
fi

# Step 5: Configure Splunk Web (HTTPS)
output=$(runuser -l splunk -c '/opt/splunk/bin/splunk enable web-ssl' 2>&1)
if [ $? -eq 0 ]; then    
    echo "✓ HTTPS enabled for Splunk Web using self-signed certificate."
else
    echo "⚠ WARN: Failed to set web.conf"
    echo "(The command: /opt/splunk/bin/splunk enable web-ssl)"
    echo "Error details: $output"
fi    
echo

# Step 5.5: Configure internal data forwarding (skip for single-server — it indexes its own internal logs locally)
if [[ "$SPLUNK_INSTANCE" != "SINGLE_SERVER" ]]; then
    configure_send_internal_data_to_indexers
fi


# Step 6: Enable boot-start
output=$(/opt/splunk/bin/splunk enable boot-start -systemd-managed 1 -user splunk 2>&1)
if [ $? -eq 0 ]; then
    echo "✓ Boot-start enabled"
else
    echo "FATAL: Failed to enable boot-start"
    echo "Error details: $output"
fi
echo


# Step 7: Reload systemd and start Splunkd service
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
    echo "Visit the Splunk server using https://hostNameOrip:8000 as mentioned above."
    echo
else
    echo "FATAL: Splunk Enterprise has FAILED install!"
    exit 1
fi

# Role-specific configuration
case $SPLUNK_INSTANCE in
    HF)
        echo
        configure_deployment_client
        
        echo "✓ HF configuration complete"
        ;;
    SH)
        echo
        configure_cluster_member "searchhead"

        echo "✓ SH configuration complete"
        ;;
    SINGLE_SERVER)
        echo
        output=$(runuser -l splunk -c '/opt/splunk/bin/splunk add tcp 9997 -app system -index main -disabled 0' 2>&1)
        if [[ $? -eq 0 ]]; then
            echo "✓ TCP 9997 receiver enabled"
        else
            echo "⚠ WARNING: Failed to enable TCP 9997"
            echo "Error details: $output"
        fi

        echo "✓ Splunk configuration complete"
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
        read -r -p "Is this a multi-site cluster? [y/n]: " is_multi_site
        echo
        
        if [[ "$is_multi_site" =~ ^[Yy]$ ]]; then
            # read -r -p "Enter available sites (comma-separated, e.g., site1,site2): " available_sites
            read -r -p "Enter how many sites (will be set to: site1,site2,...): " available_sites

            # Generate site list from number input (e.g., 3 -> "site1,site2,site3")
            num_sites=$available_sites
            available_sites=""
            for ((i=1; i<=num_sites; i++)); do
                if [ $i -gt 1 ]; then
                    available_sites="${available_sites},"
                fi
                available_sites="${available_sites}site${i}"
            done
            
            read -r -p "Enter current site (e.g., site1): " current_site
            read -r -p "Enter site replication factor (e.g., origin:2,total:3): " site_replication_factor
            read -r -p "Enter site search factor (e.g., origin:1,total:2): " site_search_factor
            read -r -p "Enter secret key: " secret_key
            read -r -p "Enter cluster label (e.g., cluster1): " cluster_label
            
            if [[ -n "$available_sites" && -n "$current_site" && -n "$site_replication_factor" && -n "$site_search_factor" && -n "$secret_key" && -n "$cluster_label" ]]; then
                runuser -l splunk -c "/opt/splunk/bin/splunk edit cluster-config -mode manager -multisite true -available_sites ${available_sites} -site ${current_site} -site_replication_factor ${site_replication_factor} -site_search_factor ${site_search_factor} -secret ${secret_key} -cluster_label ${cluster_label}" || { echo "ERROR: Failed to configure multi-site cluster. Exiting..."; exit 1; }
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
            systemctl restart Splunkd.service || { echo "ERROR: Failed to restart Splunk. Exiting..."; exit 1; }
            echo "✓ Splunk restarted"
        fi
        ;;
    PEER_NODE)
        echo        
        output=$(runuser -l splunk -c '/opt/splunk/bin/splunk disable webserver' 2>&1)
        if [ $? -eq 0 ]; then    
            echo "✓ Disabled Splunk Web access."
        else
            echo "⚠ WARN: Failed to disable web access (webserver)"    
            echo "Error details: $output"
        fi    
        echo
        
        # Configure 9997 as inital input
        output=$(runuser -l splunk -c '/opt/splunk/bin/splunk add tcp 9997 -app system -index main -disabled 0' 2>&1)
        if [[ $? -eq 0 ]]; then
            echo "✓ TCP 9997 receiver enabled"
        else
            echo "⚠ WARNING: Failed to enable TCP 9997"
            echo "Error details: $output"
        fi

        configure_cluster_member "peer"
        
        ;;
esac

echo
echo "HAPPY SPLUNKING!!! Splunk PS Bynet Team"
echo
echo

#End of File