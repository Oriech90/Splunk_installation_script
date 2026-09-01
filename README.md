# Splunk Install / Reset Scripts

Two companion scripts for standing up and tearing down a Splunk Enterprise
instance on a Linux host:

| Script | Purpose |
|---|---|
| `splunk_installer.sh` | Interactive installer — extracts Splunk, creates the service user, configures THP/ulimits, and sets up role-specific config (single server, HF, SH, CM, peer, deployment server). |
| `reset_script.sh` | Fully reverts everything the installer did, so the host is back to a clean pre-install state. |

---

## Requirements

- Root or sudo access
- A downloaded Splunk Enterprise tarball (e.g. `splunk-9.x.x-xxxxxxx-Linux-x86_64.tgz`) before running the installer
- systemd-based host (both scripts manage `.service` units)

---

## `splunk_installer.sh`

### What it does, in order

1. **THP (Transparent Huge Pages)** — sets `never` for `enabled`/`defrag` and installs a `disable-thp.service` unit so this persists across reboots.
2. **ulimits** — raises file descriptor / process limits for the current shell, and appends `DefaultLimitFSIZE`, `DefaultLimitNOFILE`, `DefaultLimitNPROC` to `/etc/systemd/system.conf`.
3. **Splunk user** — prompts for a username and creates it with `useradd -m`.
4. **Extract & install** — untars the Splunk package into `/opt/splunk`, sets ownership to the new user.
5. **First start/stop** — starts Splunk once (accepting the license) to finalize install, then stops it.
6. **Web SSL** — enables HTTPS for Splunk Web.
7. **Boot-start** — registers Splunk as a systemd-managed service (`Splunkd.service`).
8. **Role-specific setup** — based on your menu choice:
   - **Single Server** — enables a TCP 9997 receiver.
   - **Heavy Forwarder** — optionally configures a deployment client.
   - **Search Head** — joins a cluster as a search head.
   - **Deployment Server** — creates an app folder under `deployment-apps`.
   - **Cluster Manager** — configures single- or multi-site clustering.
   - **Peer Node (Indexer)** — disables Splunk Web, enables the 9997 receiver, joins a cluster as a peer.
   - For HF/SH/CM/Peer roles, you're also asked whether to forward internal logs to a set of indexers.

### Usage

```bash
sudo ./splunk_installer.sh
```

You'll be prompted for: instance role, a non-root username/password, the path
to the Splunk tarball, and role-specific details (cluster manager IP, secret
key, indexer list, etc.) as applicable.

### ⚠️ Known quirk to be aware of

The username prompt in Step 3 has a loop condition that only checks for a
user literally named `splunk` — so if you enter a different username at that
prompt, the script will keep re-prompting in a loop, or (depending on your
input) may end up creating an account under a name other than `splunk`. **For
predictable results, enter `splunk` as the username when prompted.** The
reset script accounts for this by asking you to confirm the username if it
can't find one called `splunk`.

---

## `reset_script.sh`

Reverses everything above so you can re-run the installer from a clean
slate. It is **destructive** and **idempotent** — safe to run more than
once, and safe to run after a partial/failed install.

### What it does, in order

1. Disables Splunk boot-start (via the Splunk binary, before removing it).
2. Stops, disables, and removes the `Splunkd.service` unit.
3. Stops, disables, and removes the `disable-thp.service` unit.
4. Removes `/opt/splunk` entirely.
5. Removes the Splunk OS user (kills any lingering processes first, then `userdel -r`).
6. Removes the `DefaultLimitFSIZE` / `DefaultLimitNOFILE` / `DefaultLimitNPROC` lines it finds in `/etc/systemd/system.conf`.
7. Reloads the systemd daemon.
8. Reports the current THP state (does **not** revert it automatically — see below).

### Usage

```bash
sudo ./reset_script.sh
```

If you forget `sudo`, the script won't silently fail — it prints the exact
command to re-run (`sudo ./reset_script.sh`) and exits.

Before touching anything, it **scans the system and prints exactly what it's
about to do**, e.g.:

```
===============================================
 Splunk Reset — the following actions will run:
===============================================
  [1] Disable Splunk boot-start integration
  [2] Stop, disable, and remove service: Splunkd.service
  [3] Stop, disable, and remove service: disable-thp.service   (skip — not registered)
  [4] Delete directory: /opt/splunk  (2.1G)
  [5] Delete OS user 'splunk' and their home directory
  [6] Remove 3 Splunk ulimit line(s) from /etc/systemd/system.conf
  [7] Reload systemd daemon
  [8] Report current THP state (not modified automatically)

 NOT touched: the Splunk tarball, firewall rules, and any
 deployment-apps content placed outside /opt/splunk.
===============================================
Type 'YES' to proceed with the actions above:
```

Steps that don't apply (e.g. a service that was never registered) are shown
as `(skip — ...)` rather than silently omitted, so you can see the full
picture of what the script checked. If no user named `splunk` exists, you'll
be prompted for the actual username before the preview is shown — that way
the preview reflects the real account that will be deleted. Nothing is
modified until you type `YES`.

### What it deliberately does *not* touch

- **The downloaded tarball** — not removed, since it lives outside `/opt/splunk` and you'll likely want it for the next install.
- **THP setting** — left as-is; the script only reports the current state and prints the manual command to revert it (`echo always > /sys/kernel/mm/transparent_hugepage/enabled`). This is intentional: if the host isn't dedicated to Splunk, other software may also depend on THP being disabled.
- **Firewall rules** — if you opened ports (8000, 8089, 9997, etc.) manually, those aren't tracked or reverted.
- **Deployment-apps content placed outside `/opt/splunk`**, if any.

### Open decision: should THP auto-revert?

If this host is **dedicated to Splunk only**, it's reasonable to have the
reset script also run:
```bash
echo always > /sys/kernel/mm/transparent_hugepage/enabled
echo always > /sys/kernel/mm/transparent_hugepage/defrag
```
This isn't automated yet since it's a host-wide kernel setting, not
something scoped to Splunk. Uncomment/add this in `report_thp()` if you
want that behavior.

---

## Typical workflow

```bash
# Fresh install
sudo ./splunk_installer.sh

# Something's wrong, start over
sudo ./reset_script.sh
sudo ./splunk_installer.sh
```

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `bad interpreter`, `$'\r': command not found`, or the **script is not recognized as an executable/shell script** | The file was copied or edited on Windows (e.g. transferred as `.txt`, edited in Notepad) and has Windows-style line endings (`\r\n`) instead of Unix (`\n`). Strip the carriage returns with:<br>`sed -i 's/\r$//' file_name.sh`<br>Run this on whichever script is affected (`splunk_installer.sh` and/or `reset_script.sh`), then try running it again. |
| `userdel -r` fails during reset | A process owned by the Splunk user is still running (script attempts `pkill` first, but check `ps -u splunk` manually if it persists). |
| Reset script can't find the Splunk user | Installer was run with a username other than `splunk` — enter the actual username when prompted. |
| Boot-start disable fails during reset | `/opt/splunk/bin/splunk` was already removed or corrupted before running the reset script; the systemd service removal steps will still clean up the unit file regardless. |
| Duplicate limit lines in `/etc/systemd/system.conf` after several install/reset cycles | You're running an older version of the reset script that didn't include the `system.conf` cleanup step — re-run the current version. |

