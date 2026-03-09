# setupGetIplayer

Automated setup, installation, and management of [get_iplayer](https://github.com/get-iplayer/get_iplayer) on a Raspberry Pi. Designed for headless, unattended operation behind a NordVPN tunnel.

The scripts handle everything from first-run dependency installation through to launching the Web PVR Manager and scheduling hourly PVR recordings. They are idempotent — safe to re-run at any time to pick up new get_iplayer releases without disturbing your existing configuration.

## What it does

1. Installs all required system packages (Perl modules, ffmpeg, AtomicParsley, etc.) via `apt-get` if they are not already present.
2. Queries the GitHub API for the latest get_iplayer release and compares it to the currently installed version. Only downloads and installs if an update is available.
3. Ensures the `output` preference in get_iplayer's options file points to the correct media directory (`/mnt/Media/TV` by default), without overwriting any other preferences you have set.
4. Sets the `GETIPLAYER_PROFILE` environment variable system-wide (via `/etc/profile.d/`) so that any user — including root — can simply run `get_iplayer --pvr` without needing to specify `--profile-dir` every time.
5. Installs an hourly cron job (`/etc/cron.d/get_iplayer_pvr`) that runs the PVR automatically.
6. Stops any existing Web PVR Manager instance and launches a fresh one on the configured port.
7. Kicks off an initial PVR pass in the background to populate the programme cache.

## Repository contents

| File | Purpose |
|---|---|
| `setup_get_iplayer.sh` | Main setup script. Installs/updates get_iplayer, configures preferences, starts the Web PVR Manager, and sets up the cron job. |
| `wait_and_launch_get_iplayer.sh` | Boot wrapper. Waits for NordVPN to establish a tunnel, then calls `setup_get_iplayer.sh`. Intended to be run via a `@reboot` cron entry. |

## Prerequisites

- **Hardware:** Raspberry Pi (any model) running Raspberry Pi OS or another Debian-based distribution.
- **Storage:** The media and profile directories must already exist before running the script. By default these are:
  - `/mnt/Media/TV` — where downloaded programmes are saved.
  - `/mnt/Media/TV/.get_iplayer` — where get_iplayer stores its options, caches, PVR searches, and download history.
- **Network:** A working internet connection. If using NordVPN, auto-connect should be enabled:
  ```bash
  nordvpn set autoconnect on uk
  ```
- **Permissions:** The scripts must be run as root (e.g. via `sudo`).

## Installation

Clone the repository onto your Raspberry Pi and copy the scripts into place:

```bash
git clone https://github.com/psmith1303/setupGetIplayer.git
cd setupGetIplayer

sudo cp setup_get_iplayer.sh /usr/local/bin/
sudo cp wait_and_launch_get_iplayer.sh /usr/local/bin/
sudo chmod 755 /usr/local/bin/setup_get_iplayer.sh
sudo chmod 755 /usr/local/bin/wait_and_launch_get_iplayer.sh
```

Create the media and profile directories if they don't already exist:

```bash
sudo mkdir -p /mnt/Media/TV/.get_iplayer
```

## Usage

### Manual run

```bash
sudo setup_get_iplayer.sh
```

This will install or update get_iplayer if needed, ensure preferences are correct, launch the Web PVR Manager, install the hourly cron job, and run an initial PVR pass. You can re-run it at any time — it only downloads a new version when one is available.

### Automatic start at boot (with NordVPN)

Add a `@reboot` entry to root's crontab:

```bash
sudo crontab -e
```

Add this line:

```
@reboot /usr/local/bin/wait_and_launch_get_iplayer.sh &
```

At boot, the wrapper script will poll `nordvpn status` every 10 seconds for up to 5 minutes, waiting for the tunnel to report "Connected". Once the VPN is up, it calls `setup_get_iplayer.sh`. If the VPN does not connect within the timeout the wrapper exits with an error (logged to `/var/log/get_iplayer_boot.log`).

### Running the PVR manually

Once the setup script has been run at least once, the `GETIPLAYER_PROFILE` environment variable is set system-wide. This means you can run PVR commands as root in any terminal without extra flags:

```bash
get_iplayer --pvr
```

To add a new PVR search (for example, to automatically record a specific show):

```bash
get_iplayer --pvr-add=MyShow "show name here" --type=tv
```

### Accessing the Web PVR Manager

By default the Web PVR Manager listens on `127.0.0.1:1935`. Open it in a browser on the Pi itself:

```
http://127.0.0.1:1935/
```

To access it from another machine on your network, either set up an SSH tunnel:

```bash
ssh -L 1935:127.0.0.1:1935 pi@<your-pi-ip>
```

…or change `CGI_LISTEN` to `0.0.0.0` at the top of `setup_get_iplayer.sh` and re-run the script.

> **Warning:** The Web PVR Manager has no authentication. Do not expose it to the public internet.

## Configuration

All configurable values are defined as variables at the top of `setup_get_iplayer.sh`:

| Variable | Default | Description |
|---|---|---|
| `MEDIA_DIR` | `/mnt/Media/TV` | Where downloaded programmes are saved. Also used as the get_iplayer `--output` preference. |
| `PROFILE_DIR` | `/mnt/Media/TV/.get_iplayer` | Where get_iplayer stores its options, caches, PVR searches, and download history. |
| `INSTALL_DIR` | `/usr/local/bin` | Where `get_iplayer` and `get_iplayer.cgi` are installed. |
| `CGI_PORT` | `1935` | TCP port for the Web PVR Manager. |
| `CGI_LISTEN` | `127.0.0.1` | Listen address for the Web PVR Manager. Change to `0.0.0.0` for network access. |
| `LOG_FILE` | `/var/log/get_iplayer_setup.log` | Log file for the setup script itself. |

The boot wrapper `wait_and_launch_get_iplayer.sh` has its own tunables:

| Variable | Default | Description |
|---|---|---|
| `MAX_ATTEMPTS` | `30` | Number of times to check for VPN connectivity before giving up. |
| `RETRY_INTERVAL` | `10` | Seconds between VPN connectivity checks. |

## Log files

| Log file | Contents |
|---|---|
| `/var/log/get_iplayer_setup.log` | Output from each run of `setup_get_iplayer.sh`. |
| `/var/log/get_iplayer_boot.log` | Output from the boot wrapper, including the NordVPN wait. |
| `/var/log/get_iplayer_cgi.log` | Output from the Web PVR Manager process. |
| `/var/log/get_iplayer_pvr.log` | Output from hourly PVR cron runs and the initial cache-priming pass. |

## How it works in detail

### Version checking

The setup script queries the [GitHub releases API](https://api.github.com/repos/get-iplayer/get_iplayer/releases/latest) for the latest release tag. It compares this against the version string reported by the currently installed `get_iplayer` binary. If they match, the download is skipped entirely.

### Preferences and the options file

get_iplayer stores its preferences in a plain-text file at `<profile-dir>/options`. The setup script uses `get_iplayer --prefs-add --output=<dir>` on every run to ensure the output directory is correctly set. The `--prefs-add` command merges into the existing options file — it only adds or updates the specific preference you pass and leaves everything else untouched.

### System-wide profile directory

The `GETIPLAYER_PROFILE` environment variable tells get_iplayer where to find its profile directory. The setup script installs this in two places:

- `/etc/profile.d/get_iplayer.sh` — picked up by all interactive login shells (including root).
- `/etc/cron.d/get_iplayer_pvr` — set as an environment variable inside the cron file, since cron does not source profile.d scripts.

This means `get_iplayer --pvr` works correctly regardless of how it is invoked — from an interactive root session, from the cron scheduler, or from the boot wrapper.

### System packages installed

The setup script installs the following via `apt-get` if not already present:

- `perl` — runtime for get_iplayer
- `libwww-perl` — LWP (HTTP access to BBC servers)
- `liblwp-protocol-https-perl` — HTTPS support for LWP
- `libmojolicious-perl` — web toolkit required by get_iplayer
- `libxml-libxml-perl` — subtitle formatting and HTML parsing
- `libcgi-pm-perl` — required by the Web PVR Manager
- `ffmpeg` — converts MPEG-DASH and MPEG-TS streams to MP4/M4A
- `atomicparsley` — metadata tagging for MP4/M4A files
- `jq` — JSON parsing (used to query the GitHub API)
- `curl` — HTTP downloads

## Uninstalling

To reverse the setup:

```bash
# Stop the Web PVR Manager
sudo pkill -f get_iplayer.cgi

# Remove the cron jobs
sudo rm /etc/cron.d/get_iplayer_pvr
sudo crontab -l | grep -v wait_and_launch_get_iplayer | sudo crontab -

# Remove the system-wide environment variable
sudo rm /etc/profile.d/get_iplayer.sh

# Remove the installed scripts
sudo rm /usr/local/bin/get_iplayer
sudo rm /usr/local/bin/get_iplayer.cgi
sudo rm /usr/local/bin/setup_get_iplayer.sh
sudo rm /usr/local/bin/wait_and_launch_get_iplayer.sh

# Optionally remove log files
sudo rm /var/log/get_iplayer_*.log
```

Your downloaded programmes and get_iplayer profile (PVR searches, download history, etc.) in `/mnt/Media/TV` are left intact.

## Related projects

- [get_iplayer](https://github.com/get-iplayer/get_iplayer) — the underlying tool that does the actual downloading.
- [get_iplayer wiki](https://github.com/get-iplayer/get_iplayer/wiki) — official documentation, including the [installation guide](https://github.com/get-iplayer/get_iplayer/wiki/installation), [PVR usage](https://github.com/get-iplayer/get_iplayer/wiki/pvr), and [Web PVR Manager](https://github.com/get-iplayer/get_iplayer/wiki/webpvr).
- [Marginal/docker-get_iplayer](https://github.com/Marginal/docker-get_iplayer) — a Docker image for get_iplayer that inspired some of the design choices in these scripts.

## Licence

This project is provided as-is with no warranty. get_iplayer is a separate project with its own [licence](https://github.com/get-iplayer/get_iplayer/blob/master/LICENSE.txt).
