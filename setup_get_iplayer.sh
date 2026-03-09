#!/usr/bin/env bash
#
# setup_get_iplayer.sh
#
# Installs or updates get_iplayer on a Raspberry Pi (Debian/Raspbian-based).
# Checks the latest release from GitHub and only installs if needed.
# Configures output and profile directories, launches the Web PVR Manager,
# and sets up an hourly cron job for automatic PVR recording.
#
# Usage:  sudo ./setup_get_iplayer.sh
#
# Configuration — edit these to taste:
MEDIA_DIR="/mnt/Media/TV"
PROFILE_DIR="${MEDIA_DIR}/.get_iplayer"
INSTALL_DIR="/usr/local/bin"
CGI_PORT=1935
CGI_LISTEN="127.0.0.1"
LOG_FILE="/var/log/get_iplayer_setup.log"
GITHUB_API_URL="https://api.github.com/repos/get-iplayer/get_iplayer/releases/latest"

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

die() {
    log "FATAL" "$@"
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "This script must be run as root (use sudo)."
    fi
}

command_exists() {
    command -v "$1" &>/dev/null
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

require_root
log "INFO" "=== get_iplayer setup started ==="

# Ensure log file is writable
touch "${LOG_FILE}" 2>/dev/null || true

# Check we're on a Debian-based system
if ! command_exists apt-get; then
    die "apt-get not found — this script is intended for Debian/Raspbian-based systems."
fi

# Check network connectivity (robust: try multiple hosts)
network_ok=false
for host in api.github.com github.com 8.8.8.8; do
    if ping -c 1 -W 5 "${host}" &>/dev/null; then
        network_ok=true
        break
    fi
done
if [[ "${network_ok}" != "true" ]]; then
    die "No network connectivity detected. Please check your connection."
fi

# ---------------------------------------------------------------------------
# 1. Install system dependencies
# ---------------------------------------------------------------------------

log "INFO" "Checking and installing system dependencies..."

PACKAGES=(
    perl
    libwww-perl
    liblwp-protocol-https-perl
    libmojolicious-perl
    libxml-libxml-perl
    libcgi-pm-perl
    ffmpeg
    atomicparsley
    jq
    curl
)

packages_to_install=()
for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -s "${pkg}" &>/dev/null; then
        packages_to_install+=("${pkg}")
    fi
done

if [[ ${#packages_to_install[@]} -gt 0 ]]; then
    log "INFO" "Installing missing packages: ${packages_to_install[*]}"
    apt-get update -qq || die "apt-get update failed."
    apt-get install -y -qq "${packages_to_install[@]}" || die "apt-get install failed."
    log "INFO" "Package installation complete."
else
    log "INFO" "All system dependencies already installed."
fi

# ---------------------------------------------------------------------------
# 2. Determine installed and latest versions
# ---------------------------------------------------------------------------

installed_version="none"
if [[ -x "${INSTALL_DIR}/get_iplayer" ]]; then
    # get_iplayer --info outputs version on first line; extract the number
    installed_version=$("${INSTALL_DIR}/get_iplayer" --nocopyright --info 2>/dev/null \
        | grep -oP 'get_iplayer\s+v?\K[0-9]+\.[0-9]+' | head -1) || true
    if [[ -z "${installed_version}" ]]; then
        # Fallback: try --help which also prints version
        installed_version=$("${INSTALL_DIR}/get_iplayer" --help 2>&1 \
            | grep -oP 'v?\K[0-9]+\.[0-9]+' | head -1) || true
    fi
    [[ -z "${installed_version}" ]] && installed_version="unknown"
fi
log "INFO" "Installed version: ${installed_version}"

log "INFO" "Querying GitHub for latest release..."
latest_json=$(curl -fsSL --retry 3 --retry-delay 5 "${GITHUB_API_URL}") \
    || die "Failed to fetch latest release info from GitHub API."

latest_version=$(echo "${latest_json}" | jq -r '.tag_name // empty' | sed 's/^v//')
tarball_url=$(echo "${latest_json}" | jq -r '.tarball_url // empty')

if [[ -z "${latest_version}" || -z "${tarball_url}" ]]; then
    die "Could not parse latest release info from GitHub API response."
fi
log "INFO" "Latest release version: ${latest_version}"

# ---------------------------------------------------------------------------
# 3. Install or update get_iplayer if needed
# ---------------------------------------------------------------------------

if [[ "${installed_version}" == "${latest_version}" ]]; then
    log "INFO" "get_iplayer is already up to date (v${latest_version}). Skipping install."
else
    log "INFO" "Installing get_iplayer v${latest_version}..."

    tmpdir=$(mktemp -d /tmp/get_iplayer_install.XXXXXX)
    trap 'rm -rf "${tmpdir}"' EXIT

    log "INFO" "Downloading tarball from ${tarball_url}..."
    curl -fsSL --retry 3 --retry-delay 5 "${tarball_url}" -o "${tmpdir}/get_iplayer.tar.gz" \
        || die "Failed to download get_iplayer tarball."

    tar -xzf "${tmpdir}/get_iplayer.tar.gz" -C "${tmpdir}" \
        || die "Failed to extract get_iplayer tarball."

    # The extracted directory name is unpredictable; find it
    src_dir=$(find "${tmpdir}" -maxdepth 1 -type d -name 'get-iplayer*' | head -1)
    if [[ -z "${src_dir}" || ! -f "${src_dir}/get_iplayer" ]]; then
        die "Could not locate get_iplayer script inside the extracted tarball."
    fi

    install -m 755 "${src_dir}/get_iplayer"     "${INSTALL_DIR}/get_iplayer" \
        || die "Failed to install get_iplayer to ${INSTALL_DIR}."
    install -m 755 "${src_dir}/get_iplayer.cgi"  "${INSTALL_DIR}/get_iplayer.cgi" \
        || die "Failed to install get_iplayer.cgi to ${INSTALL_DIR}."

    rm -rf "${tmpdir}"
    trap - EXIT

    log "INFO" "get_iplayer v${latest_version} installed to ${INSTALL_DIR}."
fi

# Quick sanity check
if ! "${INSTALL_DIR}/get_iplayer" --nocopyright --help &>/dev/null; then
    die "get_iplayer installed but failed a basic --help test. Check Perl dependencies."
fi

# ---------------------------------------------------------------------------
# 4. Verify directory structure and configure get_iplayer
# ---------------------------------------------------------------------------

log "INFO" "Checking that media and profile directories exist..."

if [[ ! -d "${MEDIA_DIR}" ]]; then
    die "${MEDIA_DIR} does not exist. Please create it (and mount the underlying storage) before running this script."
fi

if [[ ! -d "${PROFILE_DIR}" ]]; then
    die "${PROFILE_DIR} does not exist. Please create it before running this script."
fi

# Always ensure the output directory preference is set correctly.
# --prefs-add merges into the existing options file (or creates it if
# absent), so this is safe to run every time — it won't clobber any
# other preferences the user has added manually.
OPTIONS_FILE="${PROFILE_DIR}/options"
if [[ -f "${OPTIONS_FILE}" ]]; then
    log "INFO" "Options file already exists at ${OPTIONS_FILE}."
else
    log "INFO" "No existing options file — one will be created."
fi

log "INFO" "Ensuring output directory preference is set to ${MEDIA_DIR}..."
"${INSTALL_DIR}/get_iplayer" \
    --nocopyright \
    --profile-dir="${PROFILE_DIR}" \
    --prefs-add \
    --output="${MEDIA_DIR}" \
    2>&1 | tee -a "${LOG_FILE}" || log "WARN" "prefs-add for --output may have had issues."

# Verify the preference was actually written
if grep -q "^output " "${OPTIONS_FILE}" 2>/dev/null; then
    log "INFO" "Confirmed: output preference present in ${OPTIONS_FILE}."
else
    log "WARN" "output preference not found in ${OPTIONS_FILE} — get_iplayer may save to the current directory."
fi

# ---------------------------------------------------------------------------
# 5. Set GETIPLAYER_PROFILE system-wide
# ---------------------------------------------------------------------------
#
# This ensures that any user (including root) can simply run
#   get_iplayer --pvr
# without needing to remember --profile-dir every time.

PROFILE_D_FILE="/etc/profile.d/get_iplayer.sh"
log "INFO" "Installing system-wide GETIPLAYER_PROFILE in ${PROFILE_D_FILE}..."

cat > "${PROFILE_D_FILE}" <<EOF
# Set get_iplayer profile directory for all login shells
export GETIPLAYER_PROFILE="${PROFILE_DIR}"
EOF

chmod 644 "${PROFILE_D_FILE}" || log "WARN" "Could not chmod ${PROFILE_D_FILE}."

# Also export it right now for the remainder of this script
export GETIPLAYER_PROFILE="${PROFILE_DIR}"

log "INFO" "GETIPLAYER_PROFILE=${PROFILE_DIR} will be set for all future login shells."

# ---------------------------------------------------------------------------
# 6. Set up hourly PVR cron job
# ---------------------------------------------------------------------------

CRON_COMMENT="# get_iplayer PVR - hourly run"
CRON_CMD="0 * * * * root ${INSTALL_DIR}/get_iplayer --nocopyright --profile-dir=${PROFILE_DIR} --pvr >> /var/log/get_iplayer_pvr.log 2>&1"
CRON_FILE="/etc/cron.d/get_iplayer_pvr"

log "INFO" "Setting up hourly PVR cron job..."

cat > "${CRON_FILE}" <<EOF
${CRON_COMMENT}
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
GETIPLAYER_PROFILE=${PROFILE_DIR}
${CRON_CMD}
EOF

chmod 644 "${CRON_FILE}" || log "WARN" "Could not chmod cron file."

log "INFO" "Cron job installed at ${CRON_FILE}."

# Create the PVR log file if it doesn't exist
touch /var/log/get_iplayer_pvr.log 2>/dev/null || true

# ---------------------------------------------------------------------------
# 7. Launch the Web PVR Manager (CGI server)
# ---------------------------------------------------------------------------

log "INFO" "Preparing to launch Web PVR Manager on port ${CGI_PORT}..."

# Kill any existing instance gracefully
existing_pid=$(pgrep -f "get_iplayer\.cgi.*-p\s*${CGI_PORT}" 2>/dev/null || true)
if [[ -n "${existing_pid}" ]]; then
    log "INFO" "Stopping existing Web PVR Manager (PID: ${existing_pid})..."
    kill "${existing_pid}" 2>/dev/null || true
    # Wait up to 10 seconds for it to exit
    for i in $(seq 1 10); do
        if ! kill -0 "${existing_pid}" 2>/dev/null; then
            break
        fi
        sleep 1
    done
    # Force kill if still running
    if kill -0 "${existing_pid}" 2>/dev/null; then
        kill -9 "${existing_pid}" 2>/dev/null || true
        log "WARN" "Had to force-kill old Web PVR Manager process."
    fi
fi

# GETIPLAYER_PROFILE was already exported in section 5

# Launch in background; nohup keeps it running after this script exits
nohup "${INSTALL_DIR}/get_iplayer.cgi" \
    -p "${CGI_PORT}" \
    -l "${CGI_LISTEN}" \
    -g "${INSTALL_DIR}/get_iplayer" \
    --ffmpeg "$(command -v ffmpeg)" \
    >> /var/log/get_iplayer_cgi.log 2>&1 &

cgi_pid=$!

# Give it a few seconds to start, then verify
sleep 3
if kill -0 "${cgi_pid}" 2>/dev/null; then
    log "INFO" "Web PVR Manager running (PID: ${cgi_pid}) on http://${CGI_LISTEN}:${CGI_PORT}/"
else
    log "ERROR" "Web PVR Manager failed to start. Check /var/log/get_iplayer_cgi.log"
fi

# ---------------------------------------------------------------------------
# 8. Run PVR once now to prime caches
# ---------------------------------------------------------------------------

log "INFO" "Running initial PVR pass to populate programme caches..."
"${INSTALL_DIR}/get_iplayer" \
    --nocopyright \
    --profile-dir="${PROFILE_DIR}" \
    --pvr \
    >> /var/log/get_iplayer_pvr.log 2>&1 &

log "INFO" "Initial PVR pass started in background."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

cat <<SUMMARY

============================================================
  get_iplayer setup complete
============================================================

  Version:        ${latest_version}
  Install dir:    ${INSTALL_DIR}
  Media output:   ${MEDIA_DIR}
  Profile dir:    ${PROFILE_DIR}

  Web PVR:        http://${CGI_LISTEN}:${CGI_PORT}/
                  (set CGI_LISTEN=0.0.0.0 at the top of the
                   script to access from other devices)

  PVR cron:       Runs every hour (${CRON_FILE})
  Logs:
    Setup:        ${LOG_FILE}
    CGI server:   /var/log/get_iplayer_cgi.log
    PVR runs:     /var/log/get_iplayer_pvr.log

  WARNING: The Web PVR Manager has no authentication.
           Do NOT expose it to the public internet.
============================================================

SUMMARY

log "INFO" "=== get_iplayer setup finished ==="
