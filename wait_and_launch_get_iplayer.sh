#!/usr/bin/env bash
#
# wait_and_launch_get_iplayer.sh
#
# Called via @reboot cron. Waits for the NordVPN tunnel to come up,
# then runs the main get_iplayer setup script.
#
# Install:
#   sudo cp wait_and_launch_get_iplayer.sh /usr/local/bin/
#   sudo chmod 755 /usr/local/bin/wait_and_launch_get_iplayer.sh
#
# Then add the cron entry (see bottom of this file).

set -uo pipefail

LOG="/var/log/get_iplayer_boot.log"
SETUP_SCRIPT="/usr/local/bin/setup_get_iplayer.sh"
MAX_ATTEMPTS=30      # 30 × 10s = 5 minutes
RETRY_INTERVAL=10    # seconds between checks

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG}"
}

# ---- Wait for NordVPN tunnel ------------------------------------------------

log "Boot: waiting for NordVPN tunnel..."

attempts=0
while [[ ${attempts} -lt ${MAX_ATTEMPTS} ]]; do
    if nordvpn status 2>/dev/null | grep -qi "status.*connected"; then
        log "NordVPN tunnel is connected."
        break
    fi
    attempts=$((attempts + 1))
    log "  attempt ${attempts}/${MAX_ATTEMPTS} — not yet connected, retrying in ${RETRY_INTERVAL}s..."
    sleep "${RETRY_INTERVAL}"
done

if [[ ${attempts} -ge ${MAX_ATTEMPTS} ]]; then
    log "ERROR: NordVPN did not connect within $((MAX_ATTEMPTS * RETRY_INTERVAL))s. Aborting."
    exit 1
fi

# ---- Launch get_iplayer setup ------------------------------------------------

log "Running ${SETUP_SCRIPT}..."
if bash "${SETUP_SCRIPT}" >> "${LOG}" 2>&1; then
    log "get_iplayer setup completed successfully."
else
    log "ERROR: get_iplayer setup exited with code $?."
    exit 1
fi
