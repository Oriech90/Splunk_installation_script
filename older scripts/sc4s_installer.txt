#!/bin/bash

# If there was a conversion to .txt, or the file system does not recognize the file, run the following command:
# sed -i 's/\r$//' file_name.sh

echo
echo '##############################################'
echo '#                                            #'
echo '# Welcome to the SC4S Installation Script#'
echo '#                                            #'
echo '##############################################'
echo
echo


echo "Starting sysctl configuration..."
echo

#################################
# Variables
#################################

SYSCTL_CONF="/etc/sysctl.conf"
BACKUP="/etc/sysctl.conf.bak.$(date +%Y%m%d-%H%M%S)"

ERROR_FILES=(
    /tmp/sysctl_backup.err
    /tmp/sysctl_buffer.err
    /tmp/sysctl_apply.err
    /tmp/ip_forward_runtime.err
    /tmp/ip_forward_persist.err
    /tmp/sc4s_mkdir.err
    /tmp/sc4s_load_container.err
    /tmp/configuring_sc4s_service.err
    /tmp/env_file_config.err
    /tmp/sc4s_systemd.err
)

#################################
# Cleanup handler (always runs)
#################################

cleanup() {
    echo
    echo "Cleaning up temporary error files..."
    for err in "${ERROR_FILES[@]}"; do
        [[ -f "$err" ]] && rm -f "$err"
    done
    echo "✅ Cleanup completed"
}

trap cleanup EXIT


#################################
# Check if Podman is installed
#################################
# exit 1 if not.
# print version if yes.


#################################
# Backup sysctl.conf
#################################

echo "Creating backup of $SYSCTL_CONF..."

if cp "$SYSCTL_CONF" "$BACKUP" 2> /tmp/sysctl_backup.err; then
    echo "✅ Backup created: $BACKUP"
else
    echo "⚠ WARN: Failed to backup $SYSCTL_CONF" >&2
    echo "    Error: $(cat /tmp/sysctl_backup.err)" >&2
fi
echo

#################################
# Edit receive buffer (16 MB)
#################################

echo "Configuring receive buffer (16 MB)..."
if tee -a "$SYSCTL_CONF" > /dev/null 2> /tmp/sysctl_buffer.err <<EOF

# Receive buffer tuning
net.core.rmem_default = 17039360
net.core.rmem_max = 17039360
EOF
then
    echo "✅ Receive buffer settings written"

    if ! sysctl -p > /dev/null 2> /tmp/sysctl_apply.err; then
        echo "⚠ WARN: Failed to apply sysctl settings" >&2
        echo "    Error: $(cat /tmp/sysctl_apply.err)" >&2
    else
        echo "✅ sysctl settings applied"
    fi
else
    echo "⚠ WARN: Failed to write receive buffer settings" >&2
    echo "    Error: $(cat /tmp/sysctl_buffer.err)" >&2
fi

echo

#################################
# Configure IPv4 forwarding
#################################

echo "Enabling IPv4 forwarding..."
if sysctl -w net.ipv4.ip_forward=1 > /dev/null 2> /tmp/ip_forward_runtime.err; then
    echo "✅ IPv4 forwarding enabled"
else
    echo "⚠ WARN: Failed to enable IPv4 forwarding" >&2
    echo "    Error: $(cat /tmp/ip_forward_runtime.err)" >&2
fi

echo "Persisting IPv4 forwarding across reboots..."
if tee /etc/sysctl.d/99-ipv4-forward.conf > /dev/null 2> /tmp/ip_forward_persist.err <<EOF
net.ipv4.ip_forward=1
EOF
then
    echo "✅ IPv4 forwarding persisted"
else
    echo "⚠ WARN: Failed to persist IPv4 forwarding" >&2
    echo "    Error: $(cat /tmp/ip_forward_persist.err)" >&2
fi
echo


#################################
# Create directory structure
#################################
echo "Creating SC4S local directory structure..."
DIRS=(
  "/opt/sc4s/local"
  "/opt/sc4s/local/config"
  "/opt/sc4s/local/context"
  "/opt/sc4s/archive"
  "/opt/sc4s/tls"
)

for dir in "${DIRS[@]}"; do
  if mkdir -p "$dir" 2> /tmp/sc4s_mkdir.err; then
    echo "✅ Directory ensured: $dir"
  else
    echo "⚠ WARN: Failed to create directory $dir" >&2
    echo "    Error: $(cat /tmp/sc4s_mkdir.err)" >&2
  fi
done

echo

#################################
# load container
#################################
echo "Trying to load oci_conatiner..."
if podman load < /tmp/oci_conatiner.tar.gz 2> /tmp/sc4s_load_container.err; then
    echo "✅ container loaded"
else
    echo "ERROR: Failed to load container" >&2
    echo "Error: $(cat /tmp/sc4s_load_container.err)" >&2
fi


#################################
# create sc4s.service
#################################
echo "Configuring SC4S service..."

if tee "/etc/systemd/system/sc4s.service" > /dev/null 2> /tmp/configuring_sc4s_service.err <<EOF
[Unit]
Description=SC4S Container
Wants=NetworkManager.service network-online.target
After=NetworkManager.service network-online.target

[Install]
WantedBy=multi-user.target

[Service]
Environment="SC4S_IMAGE=ghcr.io/splunk/splunk-connect-for-syslog/container3:latest"
Environment="SC4S_PERSIST_MOUNT=splunk-sc4s-var:/var/lib/syslog-ng"
Environment="SC4S_LOCAL_MOUNT=/opt/sc4s/local:/etc/syslog-ng/conf.d/local:z"
Environment="SC4S_ARCHIVE_MOUNT=/opt/sc4s/archive:/var/lib/syslog-ng/archive:z"
Environment="SC4S_TLS_MOUNT=/opt/sc4s/tls:/etc/syslog-ng/tls:z"

TimeoutStartSec=0

ExecStartPre=/usr/bin/podman pull \$SC4S_IMAGE
ExecStartPre=/usr/bin/bash -c "/usr/bin/systemctl set-environment SC4SHOST=\$(hostname -s)"
ExecStartPre=/usr/bin/bash -c "/usr/bin/podman rm SC4S > /dev/null 2>&1 || true"

ExecStart=/usr/bin/podman run \
  -e "SC4S_CONTAINER_HOST=\${SC4SHOST}" \
  -v "\$SC4S_PERSIST_MOUNT" \
  -v "\$SC4S_LOCAL_MOUNT" \
  -v "\$SC4S_ARCHIVE_MOUNT" \
  -v "\$SC4S_TLS_MOUNT" \
  --env-file=/opt/sc4s/env_file \
  --health-cmd="/usr/sbin/syslog-ng-ctl healthcheck --timeout 5" \
  --health-interval=2m --health-retries=6 --health-timeout=5s \
  --network host \
  --name SC4S \
  --rm \$SC4S_IMAGE

Restart=on-failure
EOF
then
    echo "✅ sc4s service file configured"
else
    echo "⚠ WARN: Failed to configure sc4s service" >&2
    echo "    Error: $(cat /tmp/configuring_sc4s_service.err)" >&2
fi
echo
echo



#################################
# create env_file
#################################
echo "Please enter the Splunk HEC URL (without https:// and port):"
read -r SC4S_DEST_SPLUNK_HEC_DEFAULT_URL
echo "Please enter the Splunk HEC Token:"
read -r HEC_TOKEN
echo
# read ip from the user
echo "Configuring SC4S environment file..."
if tee "/opt/sc4s/env_file" > /dev/null 2> /tmp/env_file_config.err <<EOF
SC4S_DEST_SPLUNK_HEC_DEFAULT_URL=https://$SC4S_DEST_SPLUNK_HEC_DEFAULT_URL:8088
SC4S_DEST_SPLUNK_HEC_DEFAULT_TOKEN=$HEC_TOKEN
#Uncomment the following line if using untrusted SSL certificates
SC4S_DEST_SPLUNK_HEC_DEFAULT_TLS_VERIFY=no
EOF
then
    echo "✅ SC4S env_file configured"
else
    echo "⚠ ERROR: Coudln't create or configure env_file" >&2
    echo "    Error: $(cat /tmp/env_file_config.err)" >&2
fi
echo
echo


#################################
# Configure SC4S for systemd and start SC4S
#################################
if systemctl daemon-reload > /dev/null 2> /tmp/sc4s_systemd.err; then
    echo "daemon reloaded"
fi
systemctl enable sc4s 2> /tmp/sc4s_systemd.err
systemctl start sc4s > /dev/null 2> /tmp/sc4s_systemd.err
