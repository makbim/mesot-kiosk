#!/bin/bash
set -e

CONFIG_PATH="/opt/mesot-kiosk/config.json"
CONFIG_URL="https://raw.githubusercontent.com/makbim/mesot-kiosk/main/config.json"
CHECK_SCRIPT="/opt/mesot-kiosk/check_version.sh"

echo "### Checking prerequisites..."
if ! command -v jq &>/dev/null; then
    echo "Installing jq..."
    sudo apt update -y
    sudo apt install -y jq
fi

sudo mkdir -p "$(dirname "$CONFIG_PATH")"
sudo mkdir -p /opt/mesot-kiosk
sudo mkdir -p /var/lib/mesot-kiosk
sudo mkdir -p /var/log

if [ ! -f "$CONFIG_PATH" ]; then
    echo "Downloading config.json..."
    sudo curl -fsSL "$CONFIG_URL" -o "$CONFIG_PATH"
else
    echo "Found existing config.json"
fi

echo "Available profiles:"
jq -r '.profiles | keys[]' "$CONFIG_PATH"

while true; do
    read -rp "Enter profile name: " PROFILE
    if jq -e --arg p "$PROFILE" '.profiles[$p]' "$CONFIG_PATH" >/dev/null; then
        echo "Using profile: $PROFILE"
        break
    else
        echo "Invalid profile! Try again."
    fi
done

WIFI_SSID=$(jq -r --arg p "$PROFILE" '.profiles[$p].wifi.ssid' "$CONFIG_PATH")
WIFI_PASS=$(jq -r --arg p "$PROFILE" '.profiles[$p].wifi.password' "$CONFIG_PATH")
KIOSK_URL=$(jq -r --arg p "$PROFILE" '.profiles[$p].url' "$CONFIG_PATH")
VERSION=$(jq -r --arg p "$PROFILE" '.profiles[$p].version' "$CONFIG_PATH")

echo
echo "Profile details:"
echo " - Version: $VERSION"
echo " - Wi-Fi SSID: $WIFI_SSID"
echo " - URL: $KIOSK_URL"
echo

read -rp "Proceed with these settings? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Setup cancelled."
    exit 1
fi

DEFAULT_IFACE="wlan0"
while true; do
    read -rp "Enter Wi-Fi interface name [default: $DEFAULT_IFACE]: " WIFI_IFACE
    WIFI_IFACE=${WIFI_IFACE:-$DEFAULT_IFACE}
    if ip link show "$WIFI_IFACE" &>/dev/null; then
        echo "Using interface: $WIFI_IFACE"
        break
    else
        echo "Interface '$WIFI_IFACE' not found. Available interfaces:"
        iw dev 2>/dev/null | awk '/Interface/ {print $2}' || ip -brief link show
    fi
done

echo "### Configuring Wi-Fi..."

EXISTING_CONNS=$(nmcli -t -f NAME connection show | grep -Fx "$WIFI_SSID" || true)
if [ -n "$EXISTING_CONNS" ]; then
    echo "Removing existing Wi-Fi connections named '$WIFI_SSID'..."
    nmcli connection delete "$WIFI_SSID" || true
fi

sudo nmcli connection add type wifi ifname "$WIFI_IFACE" con-name "$WIFI_SSID" ssid "$WIFI_SSID" || true
sudo nmcli connection modify "$WIFI_SSID" wifi-sec.key-mgmt wpa-psk
sudo nmcli connection modify "$WIFI_SSID" wifi-sec.psk "$WIFI_PASS"
sudo nmcli connection modify "$WIFI_SSID" connection.autoconnect yes
sudo nmcli connection modify "$WIFI_SSID" connection.autoconnect-priority 100
sudo nmcli connection modify "$WIFI_SSID" ipv4.method auto ipv6.method auto
sudo nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASS" ifname "$WIFI_IFACE" || true

echo "### Installing dependencies..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y snapd sway curl jq

echo "### Installing Chromium..."
sudo snap install chromium

echo "### Creating kiosk user..."
if ! id "kiosk" &>/dev/null; then
    sudo adduser --disabled-password --gecos "" kiosk
else
    echo "User 'kiosk' already exists, skipping..."
fi

echo "### Configuring autologin..."
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d/
sudo tee /etc/systemd/system/getty@tty1.service.d/override.conf > /dev/null << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin kiosk --noclear %I \$TERM
Type=idle
EOF

echo "### Writing Sway configuration..."
sudo -u kiosk mkdir -p /home/kiosk/.config/sway
sudo tee /home/kiosk/.config/sway/config > /dev/null << EOF
seat * { hide_cursor 0 }

input * { xkb_layout us }

exec_always bash -c '
CONFIG_URL="https://raw.githubusercontent.com/makbim/mesot-kiosk/main/config.json"
LOCAL_PROFILE_FILE="/var/lib/mesot-kiosk/active_profile"
LOCAL_VERSION_FILE="/var/lib/mesot-kiosk/version"
CONFIG_PATH="/opt/mesot-kiosk/config.json"
LOG_FILE="/var/log/mesot-kiosk-version.log"
CONFIG_TMP="/tmp/mesot-config.json"

mkdir -p /var/log

if [ ! -f "$LOCAL_PROFILE_FILE" ] || [ ! -f "$LOCAL_VERSION_FILE" ]; then
  echo "$(date) [WARN] Missing local profile/version files" >> "$LOG_FILE"
  exit 0
fi

PROFILE=$(cat "$LOCAL_PROFILE_FILE")
LOCAL_VERSION=$(cat "$LOCAL_VERSION_FILE")

if ! curl -fsSL "$CONFIG_URL" -o "$CONFIG_TMP"; then
  echo "$(date) [ERROR] Failed to fetch remote config" >> "$LOG_FILE"
  exit 0
fi

REMOTE_VERSION=$(jq -r --arg p "$PROFILE" ".profiles[$p].version" "$CONFIG_TMP")

if [ -z "$REMOTE_VERSION" ] || [ "$REMOTE_VERSION" = "null" ]; then
  echo "$(date) [ERROR] Profile '$PROFILE' not found remotely" >> "$LOG_FILE"
  exit 0
fi

if [ "$REMOTE_VERSION" != "$LOCAL_VERSION" ]; then
  echo "$(date) [INFO] Updating from $LOCAL_VERSION to $REMOTE_VERSION for profile $PROFILE" >> "$LOG_FILE"
  sudo cp "$CONFIG_TMP" "$CONFIG_PATH"
  echo "$REMOTE_VERSION" | sudo tee "$LOCAL_VERSION_FILE" >/dev/null
  echo "$(date) [OK] Updated config applied." >> "$LOG_FILE"
else
  echo "$(date) [OK] No new version ($LOCAL_VERSION)" >> "$LOG_FILE"
fi

KIOSK_URL=$(jq -r --arg p "$PROFILE" ".profiles[$p].url" "$CONFIG_PATH")

chromium \
  --kiosk \
  --noerrdialogs \
  --no-first-run \
  --disable-features=TranslateUI \
  --app="$KIOSK_URL" \
  --enable-features=UseOzonePlatform \
  --ozone-platform=wayland \
  --disable-gpu
'
EOF


sudo tee -a /home/kiosk/.profile > /dev/null << EOF

# Auto-start sway on tty1
if [ -z "\$DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
    exec sway
fi
EOF

sudo chown -R kiosk:kiosk /home/kiosk/.config
sudo chmod -R 700 /home/kiosk/.config

echo "### Saving active profile info..."
echo "$PROFILE" | sudo tee /var/lib/mesot-kiosk/active_profile >/dev/null
echo "$VERSION" | sudo tee /var/lib/mesot-kiosk/version >/dev/null

echo "### Setup complete (Profile: $PROFILE, Version: $VERSION)"
echo "Chromium kiosk will run in background."
echo "Rebooting..."
sudo reboot
