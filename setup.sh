#!/bin/bash
set -e

CONFIG_URL="https://raw.githubusercontent.com/makbim/mesot-kiosk/main/config.json"
CONFIG_PATH="/tmp/mesot-config.json"
VERSION_FILE="/etc/mesot-kiosk-version"
PROFILE_FILE="/etc/mesot-kiosk-profile"
UPDATE_SCRIPT="/usr/local/bin/mesot-kiosk-update.sh"

echo "### Downloading configuration..."
curl -sSL "$CONFIG_URL" -o "$CONFIG_PATH"

echo "Available profiles:"
jq -r '.profiles | keys[]' "$CONFIG_PATH"

if [ -f "$PROFILE_FILE" ]; then
    PROFILE=$(cat "$PROFILE_FILE")
else
    while true; do
        read -rp "Select a profile from above: " PROFILE
        if jq -e ".profiles[\"$PROFILE\"]" "$CONFIG_PATH" &>/dev/null; then
            echo "$PROFILE" | sudo tee "$PROFILE_FILE" > /dev/null
            break
        else
            echo "Profile '$PROFILE' not found! Try again."
        fi
    done
fi

PROFILE_VERSION=$(jq -r ".profiles[\"$PROFILE\"].version" "$CONFIG_PATH")
WIFI_SSID=$(jq -r ".profiles[\"$PROFILE\"].wifi.ssid" "$CONFIG_PATH")
WIFI_PASS=$(jq -r ".profiles[\"$PROFILE\"].wifi.password" "$CONFIG_PATH")
KIOSK_URL=$(jq -r ".profiles[\"$PROFILE\"].url" "$CONFIG_PATH")

echo "### Updating system and installing required packages..."
sudo apt update && sudo apt upgrade -y
sudo systemctl disable systemd-networkd-wait-online.service && sudo systemctl mask systemd-networkd-wait-online.service
sudo apt install -y snapd sway jq curl

echo "### Installing Chromium (Snap)..."
sudo snap install chromium || true

echo "### Creating kiosk user..."
if ! id "kiosk" &>/dev/null; then
    sudo adduser --disabled-password --gecos "" kiosk
else
    echo "User 'kiosk' already exists, skipping..."
fi

echo "### Configuring automatic login..."
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d/
sudo tee /etc/systemd/system/getty@tty1.service.d/override.conf > /dev/null << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin kiosk --noclear %I \$TERM
Type=idle
EOF

DEFAULT_IFACE="wlp3s0"
WIFI_IFACE=${DEFAULT_IFACE}

echo "### Configuring Wi-Fi connection '$WIFI_SSID'..."
sudo nmcli connection add type wifi ifname "$WIFI_IFACE" con-name "$WIFI_SSID" ssid "$WIFI_SSID" || true
sudo nmcli connection modify "$WIFI_SSID" wifi-sec.key-mgmt wpa-psk
sudo nmcli connection modify "$WIFI_SSID" wifi-sec.psk "$WIFI_PASS"
sudo nmcli connection modify "$WIFI_SSID" connection.autoconnect yes
sudo nmcli connection modify "$WIFI_SSID" connection.autoconnect-priority 100
sudo nmcli connection modify "$WIFI_SSID" ipv4.method auto ipv6.method auto
sudo nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASS" ifname "$WIFI_IFACE" || true

echo "### Setting up Sway configuration..."
sudo -u kiosk mkdir -p /home/kiosk/.config/sway
sudo tee /home/kiosk/.config/sway/config > /dev/null << EOF
seat * { hide_cursor 0 }

input * { xkb_layout us }

exec_always chromium \\
    --kiosk \\
    --noerrdialogs \\
    --no-first-run \\
    --disable-features=TranslateUI \\
    --app="$KIOSK_URL" \\
    --enable-features=UseOzonePlatform \\
    --ozone-platform=wayland \\
    --disable-gpu
EOF

sudo tee -a /home/kiosk/.profile > /dev/null << EOF

if [ -z "\$DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
    exec sway
fi
EOF

sudo chown -R kiosk:kiosk /home/kiosk/.config
sudo chmod -R 700 /home/kiosk/.config

echo "$PROFILE_VERSION" | sudo tee "$VERSION_FILE" > /dev/null

echo "### Creating self-update script..."
sudo tee "$UPDATE_SCRIPT" > /dev/null << 'EOF'
#!/bin/bash
set -e

LOGFILE="/var/log/mesot-kiosk-update.log"
exec >> "$LOGFILE" 2>&1

echo "### $(date): Starting kiosk update ###"

CONFIG_URL="https://raw.githubusercontent.com/makbim/mesot-kiosk/main/config.json"
CONFIG_PATH="/tmp/mesot-config.json"
VERSION_FILE="/etc/mesot-kiosk-version"
PROFILE_FILE="/etc/mesot-kiosk-profile"

echo "Downloading configuration..."
curl -sSL "$CONFIG_URL" -o "$CONFIG_PATH"

PROFILE=$(cat "$PROFILE_FILE")
PROFILE_VERSION=$(jq -r ".profiles[\"$PROFILE\"].version" "$CONFIG_PATH")
WIFI_SSID=$(jq -r ".profiles[\"$PROFILE\"].wifi.ssid" "$CONFIG_PATH")
WIFI_PASS=$(jq -r ".profiles[\"$PROFILE\"].wifi.password" "$CONFIG_PATH")
KIOSK_URL=$(jq -r ".profiles[\"$PROFILE\"].url" "$CONFIG_PATH")

CURRENT_VERSION=""
if [ -f "$VERSION_FILE" ]; then
    CURRENT_VERSION=$(cat "$VERSION_FILE")
fi

if [ "$CURRENT_VERSION" != "$PROFILE_VERSION" ]; then
    echo "$(date): Profile version changed ($CURRENT_VERSION → $PROFILE_VERSION). Updating Wi-Fi and Kiosk URL..."
    echo "$PROFILE_VERSION" | sudo tee "$VERSION_FILE" > /dev/null

    DEFAULT_IFACE="wlp3s0"
    WIFI_IFACE=${DEFAULT_IFACE}

    echo "Configuring Wi-Fi connection '$WIFI_SSID'..."
    sudo nmcli connection add type wifi ifname "$WIFI_IFACE" con-name "$WIFI_SSID" ssid "$WIFI_SSID" || true
    sudo nmcli connection modify "$WIFI_SSID" wifi-sec.key-mgmt wpa-psk
    sudo nmcli connection modify "$WIFI_SSID" wifi-sec.psk "$WIFI_PASS"
    sudo nmcli connection modify "$WIFI_SSID" connection.autoconnect yes
    sudo nmcli connection modify "$WIFI_SSID" connection.autoconnect-priority 100
    sudo nmcli connection modify "$WIFI_SSID" ipv4.method auto ipv6.method auto
    sudo nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASS" ifname "$WIFI_IFACE" || true

    echo "Updating Sway configuration..."
    sudo -u kiosk mkdir -p /home/kiosk/.config/sway
    sudo tee /home/kiosk/.config/sway/config > /dev/null << EOC
seat * { hide_cursor 0 }

input * { xkb_layout us }

exec_always chromium \\
    --kiosk \\
    --noerrdialogs \\
    --no-first-run \\
    --disable-features=TranslateUI \\
    --app="$KIOSK_URL" \\
    --enable-features=UseOzonePlatform \\
    --ozone-platform=wayland \\
    --disable-gpu
EOC

    sudo chown -R kiosk:kiosk /home/kiosk/.config
    sudo chmod -R 700 /home/kiosk/.config

    echo "$(date): Update completed."
else
    echo "$(date): Profile version ($PROFILE_VERSION) up-to-date."
fi
EOF

sudo chmod +x "$UPDATE_SCRIPT"

echo "### Creating systemd service and timer for auto-update..."
sudo tee /etc/systemd/system/mesot-kiosk-update.service > /dev/null << EOF
[Unit]
Description=Kiosk auto-update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$UPDATE_SCRIPT
EOF

sudo tee /etc/systemd/system/mesot-kiosk-update.timer > /dev/null << EOF
[Unit]
Description=Run kiosk update

[Timer]
OnBootSec=5s
OnUnitActiveSec=10s
AccuracySec=1s
Unit=mesot-kiosk-update.service

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now mesot-kiosk-update.timer

echo "### Setup complete. Reboot system..."
