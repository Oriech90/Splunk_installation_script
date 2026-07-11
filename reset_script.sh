#!/bin/bash
#
# Splunk Reset Script
# Reverts everything performed by splunk_installer.sh so the host is
# back to a clean pre-install state.
#
# Safe to re-run: every step checks whether its target exists before
# acting, so a partial or repeated run won't error out.

set -uo pipefail

SPLUNK_HOME="/opt/splunk"
SERVICE_NAME="Splunkd.service"
THP_SERVICE="disable-thp.service"
SYSTEM_CONF="/etc/systemd/system.conf"

log()  { echo -e "[*] $*"; }
ok()   { echo -e "[✓] $*"; }
warn() { echo -e "[!] $*"; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "[!] This script must be run as root (it stops services, deletes" >&2
        echo "    system files, and removes an OS user)." >&2
        echo >&2
        echo "    Re-run it with:" >&2
        echo "      sudo $0 $*" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------
# Inspect the current system state and print exactly what this run
# will change, before anything is touched. Nothing here is destructive
# — it only checks whether each target exists.
# ---------------------------------------------------------------------
preview_changes() {
    echo "==============================================="
    echo " Splunk Reset — the following actions will run:"
    echo "==============================================="

    if [[ -x "${SPLUNK_HOME}/bin/splunk" ]]; then
        echo "  [1] Disable Splunk boot-start integration"
    else
        echo "  [1] Disable Splunk boot-start integration   (skip — binary not found)"
    fi

    if systemctl list-unit-files "$SERVICE_NAME" 2>/dev/null | grep -q "$SERVICE_NAME"; then
        echo "  [2] Stop, disable, and remove service: ${SERVICE_NAME}"
    else
        echo "  [2] Stop, disable, and remove service: ${SERVICE_NAME}   (skip — not registered)"
    fi

    if systemctl list-unit-files "$THP_SERVICE" 2>/dev/null | grep -q "$THP_SERVICE"; then
        echo "  [3] Stop, disable, and remove service: ${THP_SERVICE}"
    else
        echo "  [3] Stop, disable, and remove service: ${THP_SERVICE}   (skip — not registered)"
    fi

    if [[ -d "$SPLUNK_HOME" ]]; then
        local size
        size=$(du -sh "$SPLUNK_HOME" 2>/dev/null | cut -f1)
        echo "  [4] Delete directory: ${SPLUNK_HOME}  (${size:-unknown size})"
    else
        echo "  [4] Delete directory: ${SPLUNK_HOME}   (skip — does not exist)"
    fi

    if [[ -n "${SPLUNK_USER:-}" ]] && id "$SPLUNK_USER" &>/dev/null; then
        echo "  [5] Delete OS user '${SPLUNK_USER}' and their home directory"
    else
        echo "  [5] Delete OS user   (skip — no user resolved/found)"
    fi

    if [[ -f "$SYSTEM_CONF" ]]; then
        local count
        count=$(grep -cE '^DefaultLimitFSIZE=-1$|^DefaultLimitNOFILE=64000$|^DefaultLimitNPROC=20480$' "$SYSTEM_CONF" 2>/dev/null || true)
        if [[ "${count:-0}" -gt 0 ]]; then
            echo "  [6] Remove ${count} Splunk ulimit line(s) from ${SYSTEM_CONF}"
        else
            echo "  [6] Remove Splunk ulimit lines from ${SYSTEM_CONF}   (skip — none found)"
        fi
    fi

    echo "  [7] Reload systemd daemon"
    echo "  [8] Report current THP state (not modified automatically)"
    echo
    echo " NOT touched: the Splunk tarball, firewall rules, and any"
    echo " deployment-apps content placed outside ${SPLUNK_HOME}."
    echo "==============================================="
}

confirm() {
    read -r -p "Type 'YES' to proceed with the actions above: " CONFIRM
    if [[ "$CONFIRM" != "YES" ]]; then
        echo "Aborted. No changes made."
        exit 0
    fi
}

# ---------------------------------------------------------------------
# Determine the OS user Splunk is running as.
# The installer has a bug: it prompts for a username but only loops
# until a user named "splunk" exists, so the real account created
# could have a different name. Ask, but default sensibly.
# ---------------------------------------------------------------------
resolve_splunk_user() {
    local default_user="splunk"
    if id "$default_user" &>/dev/null; then
        SPLUNK_USER="$default_user"
    else
        read -r -p "No OS user named 'splunk' found. Enter the username Splunk was installed under (or press Enter to skip user removal): " SPLUNK_USER
    fi
}

# ---------------------------------------------------------------------
# 1. Disable Splunk's own boot-start integration WHILE the binary
#    still exists (must happen before we delete /opt/splunk).
# ---------------------------------------------------------------------
disable_boot_start() {
    if [[ -x "${SPLUNK_HOME}/bin/splunk" ]]; then
        log "Disabling Splunk boot-start..."
        "${SPLUNK_HOME}/bin/splunk" disable boot-start &>/dev/null \
            && ok "Boot-start disabled" \
            || warn "Failed to disable boot-start (continuing anyway)"
    else
        log "Splunk binary not found, skipping boot-start disable"
    fi
}

# ---------------------------------------------------------------------
# 2. Stop + disable a systemd service, then remove its unit file.
# ---------------------------------------------------------------------
remove_service() {
    local svc="$1"
    local unit_path="/etc/systemd/system/${svc}"

    if systemctl list-unit-files "$svc" &>/dev/null && systemctl list-unit-files "$svc" | grep -q "$svc"; then
        log "Stopping ${svc}..."
        systemctl stop "$svc" &>/dev/null || warn "Could not stop ${svc} (may already be stopped)"
        log "Disabling ${svc}..."
        systemctl disable "$svc" &>/dev/null || warn "Could not disable ${svc} (may already be disabled)"
    else
        log "${svc} not registered with systemd, skipping stop/disable"
    fi

    if [[ -f "$unit_path" ]]; then
        rm -f "$unit_path" && ok "Removed ${unit_path}"
    else
        log "${unit_path} does not exist, skipping"
    fi
}

# ---------------------------------------------------------------------
# 3. Remove the Splunk install directory.
# ---------------------------------------------------------------------
remove_splunk_dir() {
    if [[ -d "$SPLUNK_HOME" ]]; then
        log "Removing ${SPLUNK_HOME}..."
        rm -rf "$SPLUNK_HOME" && ok "Removed ${SPLUNK_HOME}" || warn "Failed to remove ${SPLUNK_HOME}"
    else
        log "${SPLUNK_HOME} does not exist, skipping"
    fi
}

# ---------------------------------------------------------------------
# 4. Remove the OS user Splunk ran as.
# ---------------------------------------------------------------------
remove_splunk_user() {
    if [[ -z "${SPLUNK_USER:-}" ]]; then
        log "No user specified, skipping user removal"
        return
    fi
    if id "$SPLUNK_USER" &>/dev/null; then
        log "Removing user '${SPLUNK_USER}'..."
        # Kill any lingering processes owned by the user first, otherwise
        # userdel -r can fail with "user is currently used by process".
        pkill -u "$SPLUNK_USER" &>/dev/null || true
        userdel -r "$SPLUNK_USER" &>/dev/null \
            && ok "Removed user '${SPLUNK_USER}'" \
            || warn "Failed to remove user '${SPLUNK_USER}' (check for running processes or open files)"
    else
        log "User '${SPLUNK_USER}' does not exist, skipping"
    fi
}

# ---------------------------------------------------------------------
# 5. Undo the ulimit lines the installer appended to system.conf.
#    Removed by exact match so we don't disturb unrelated settings.
# ---------------------------------------------------------------------
revert_system_conf() {
    if [[ -f "$SYSTEM_CONF" ]]; then
        log "Reverting Splunk-related limits in ${SYSTEM_CONF}..."
        local before
        before=$(grep -cE '^DefaultLimitFSIZE=-1$|^DefaultLimitNOFILE=64000$|^DefaultLimitNPROC=20480$' "$SYSTEM_CONF" 2>/dev/null || true)
        if [[ "${before:-0}" -gt 0 ]]; then
            sed -i \
                -e '/^DefaultLimitFSIZE=-1$/d' \
                -e '/^DefaultLimitNOFILE=64000$/d' \
                -e '/^DefaultLimitNPROC=20480$/d' \
                "$SYSTEM_CONF"
            ok "Removed ${before} Splunk limit line(s) from ${SYSTEM_CONF}"
        else
            log "No Splunk limit lines found in ${SYSTEM_CONF}, skipping"
        fi
    fi
}

# ---------------------------------------------------------------------
# 6. Report on Transparent Huge Pages state (informational only —
#    we don't force it back since other apps on the host may rely
#    on THP being off).
# ---------------------------------------------------------------------
report_thp() {
    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        log "Current THP state: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
        warn "THP was left as configured by the installer. Manually set it back to 'always' if desired:"
        echo "     echo always > /sys/kernel/mm/transparent_hugepage/enabled"
        echo "     echo always > /sys/kernel/mm/transparent_hugepage/defrag"
    fi
}

main() {
    require_root "$@"
    resolve_splunk_user
    preview_changes
    confirm

    disable_boot_start
    remove_service "$SERVICE_NAME"
    remove_service "$THP_SERVICE"
    remove_splunk_dir
    remove_splunk_user
    revert_system_conf

    log "Reloading systemd daemon..."
    systemctl daemon-reload && ok "systemd daemon reloaded"

    report_thp

    echo
    echo "==============================================="
    ok "Splunk reset complete."
    echo "==============================================="
    echo
    echo "Manual checks you may still want to do:"
    echo "  - Any firewall rules opened for ports 8000/8089/9997 etc."
    echo "  - Downloaded tarball at the path you gave the installer (not touched by this script)"
    echo "  - Any deployment-apps content if it was placed outside /opt/splunk"
}

main "$@"
