#!/bin/bash
# Cloud Shell LXDE: Docker -> LXDE + noVNC -> Google Chrome -> Cloudflare Tunnel
# Made by MinhNeko

# This script needs bash - re-run with bash if it was started with sh
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi

set -e
trap 'rc=$?; echo "ERROR: the script stopped at line $LINENO (exit code $rc)." >&2' ERR

echo "=============================="
echo "  Cloud Shell LXDE"
echo "  Made by MinhNeko"
echo "=============================="

NAME="lxde-novnc"
IMAGE="dorowu/ubuntu-desktop-lxde-vnc"
PORT=8888                                   # noVNC port exposed from Cloud Shell
RESOLUTION="${RESOLUTION:-1366x768}"
DEFAULT_PASS="minhneko"

# The image is amd64-only (and so is the Chrome .deb we install)
if [ "$(uname -m)" != "x86_64" ]; then
  echo "ERROR: this script needs an x86_64 machine (found: $(uname -m))."
  exit 1
fi
for tool in curl awk; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: '$tool' is required but not installed."
    exit 1
  fi
done

# Read from the terminal even when the script is piped (curl ... | bash)
if { : </dev/tty; } 2>/dev/null; then TTY=/dev/tty; else TTY=/dev/stdin; fi

# ---------- User input ----------
# The password is handed to the image's startup script unquoted, so keep it to safe characters
valid_pass() {
  case "$1" in
    ''|*[!A-Za-z0-9._@%+=:,-]*) return 1 ;;
  esac
  return 0
}

# VNC password (leave blank to use the default)
if [ -n "${VNC_PASSWORD:-}" ]; then
  if ! valid_pass "$VNC_PASSWORD"; then
    echo "ERROR: VNC_PASSWORD may only contain letters, digits and . _ @ % + = : , -"
    exit 1
  fi
else
  while true; do
    read -r -p "Enter VNC password (leave blank for default: ${DEFAULT_PASS}): " VNC_PASSWORD <"$TTY" || VNC_PASSWORD=""
    VNC_PASSWORD="${VNC_PASSWORD:-$DEFAULT_PASS}"
    if valid_pass "$VNC_PASSWORD"; then break; fi
    echo "Only letters, digits and . _ @ % + = : , - are allowed. Try again."
  done
fi
# VNC authentication only uses the first 8 characters
if [ "${#VNC_PASSWORD}" -gt 8 ]; then
  VNC_PASSWORD="${VNC_PASSWORD:0:8}"
  echo "Note: VNC passwords are limited to 8 characters. Using: ${VNC_PASSWORD}"
fi

# Cloudflare Tunnel (y/n - choose n to skip if you don't use it)
CF_TOKEN="${CF_TOKEN:-}"
CF_ANSWER=""
if [ -z "$CF_TOKEN" ]; then
  while true; do
    read -r -p "Install Cloudflare Tunnel? (y/n): " CF_ANSWER <"$TTY" || CF_ANSWER="n"
    case "$CF_ANSWER" in
      y|Y|yes|YES)
        read -r -s -p "Enter Cloudflare Tunnel token: " CF_TOKEN <"$TTY" || true
        echo
        break
        ;;
      n|N|no|NO) break ;;
      *) echo "Please answer y or n." ;;
    esac
  done
fi
# Accept a pasted full command too (e.g. "... service install eyJh...") - keep only the token
CF_TOKEN="$(printf '%s' "$CF_TOKEN" | tr -d '\r' | awk '{print $NF}')"
case "$CF_ANSWER" in
  y|Y|yes|YES)
    if [ -z "$CF_TOKEN" ]; then echo "No token entered - skipping Cloudflare Tunnel."; fi
    ;;
esac

# ---------- 1. Docker ----------
echo "==> [1/5] Checking / installing Docker"
if ! command -v docker >/dev/null 2>&1; then
  echo "    Docker not found - installing ..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sudo sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
  sudo usermod -aG docker "$(id -un)" || true
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker could not be installed."
  exit 1
fi

# Use sudo if the current user can't talk to the Docker daemon
if docker info >/dev/null 2>&1; then
  D="docker"
elif sudo docker info >/dev/null 2>&1; then
  D="sudo docker"
else
  echo "ERROR: the Docker daemon is not running or not reachable."
  exit 1
fi
$D --version

# ---------- 2. Image ----------
echo "==> [2/5] Pulling image $IMAGE"
$D pull "$IMAGE"

# ---------- 3. Container ----------
echo "==> [3/5] Starting container $NAME"
$D rm -f "$NAME" >/dev/null 2>&1 || true
if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}$"; then
  echo "ERROR: port ${PORT} is already in use. Free it or change PORT at the top of this script."
  exit 1
fi
$D run -d \
  --name "$NAME" \
  --shm-size=2g \
  -p "${PORT}:80" \
  -e RESOLUTION="$RESOLUTION" \
  -e VNC_PASSWORD="$VNC_PASSWORD" \
  "$IMAGE"

echo "    Waiting for noVNC on port ${PORT} ..."
READY=0
for _ in $(seq 1 30); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT}/" || true)"
  if [ -n "$CODE" ] && [ "$CODE" != "000" ]; then READY=1; break; fi
  sleep 2
done
if [ "$READY" -ne 1 ]; then
  echo "    WARNING: noVNC did not answer yet. Check: $D logs $NAME"
fi

# ---------- 4. Chrome ----------
echo "==> [4/5] Installing Google Chrome inside the container"
CHROME_OK=1
$D exec -u root "$NAME" bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  # Remove any stale Chrome repo so apt update does not fail on an expired key
  rm -f /etc/apt/sources.list.d/google-chrome*.list
  apt-get update || true
  apt-get install -y wget ca-certificates
  wget -nv -O /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  apt-get install -y /tmp/chrome.deb
  rm -f /tmp/chrome.deb
  [ -x /opt/google/chrome/chrome ] || { echo "Chrome binary not found after install"; exit 1; }

  # Running as root, so Chrome needs --no-sandbox. Two layers, so every way of starting it works:
  # 1) the launcher script itself
  LAUNCHER=/opt/google/chrome/google-chrome
  if [ -f "$LAUNCHER" ] && ! grep -q -- "--no-sandbox" "$LAUNCHER"; then
    sed -i "s|\"\$HERE/chrome\" \"\$@\"|\"\$HERE/chrome\" --no-sandbox --disable-dev-shm-usage \"\$@\"|" "$LAUNCHER"
  fi
  # 2) the menu / desktop entry
  DESKTOP=/usr/share/applications/google-chrome.desktop
  sed -i "/--no-sandbox/! s|^Exec=/usr/bin/google-chrome-stable|Exec=/usr/bin/google-chrome-stable --no-sandbox --disable-dev-shm-usage|" "$DESKTOP"

  # Desktop shortcut + do not ask "Execute file?" when it is double-clicked
  mkdir -p /root/Desktop /root/.config/libfm
  cp "$DESKTOP" /root/Desktop/
  chmod +x /root/Desktop/google-chrome.desktop
  printf "[config]\nquick_exec=1\n" > /root/.config/libfm/libfm.conf
' || CHROME_OK=0
if [ "$CHROME_OK" -ne 1 ]; then
  echo "    WARNING: Chrome installation failed (the desktop itself still works)."
fi

# ---------- 5. Cloudflare ----------
echo "==> [5/5] Cloudflare Tunnel"
CF_OK=0
CF_CONNECTED=0
if [ -n "$CF_TOKEN" ]; then
  $D rm -f cloudflared >/dev/null 2>&1 || true
  $D run -d \
    --name cloudflared \
    --restart unless-stopped \
    --network host \
    -e TUNNEL_TOKEN="$CF_TOKEN" \
    cloudflare/cloudflared:latest tunnel --no-autoupdate run
  CF_OK=1
  echo "    Waiting for the tunnel to connect ..."
  for _ in $(seq 1 15); do
    if $D logs cloudflared 2>&1 | grep -q "Registered tunnel connection"; then CF_CONNECTED=1; break; fi
    sleep 2
  done
  if [ "$CF_CONNECTED" -eq 1 ]; then
    echo "    Tunnel connected."
  else
    $D logs --tail 5 cloudflared 2>&1 || true
    echo "    WARNING: tunnel is not connected yet. Check the token and: $D logs cloudflared"
  fi
  echo "The Public Hostname in Cloudflare must point to: http://localhost:${PORT}"
else
  echo "Skipping Cloudflare Tunnel."
fi

# ---------- Summary ----------
echo
echo "=============================="
echo "  SETUP COMPLETE!"
echo "=============================="
echo "VNC password : ${VNC_PASSWORD}"
echo "Web Preview  : click 'Web Preview' (top right) -> 'Change port' -> enter ${PORT} -> 'Change and Preview'."
if [ "$CF_OK" -eq 1 ]; then
  if [ "$CF_CONNECTED" -eq 1 ]; then
    echo "Cloudflare   : connected - open the domain you set in Public Hostname (-> http://localhost:${PORT})."
  else
    echo "Cloudflare   : started but NOT connected yet (see the warning above)."
  fi
fi
if [ "$CHROME_OK" -ne 1 ]; then
  echo "Chrome       : NOT installed (see the warning above)."
fi
echo "=============================="
echo "Made by MinhNeko"
