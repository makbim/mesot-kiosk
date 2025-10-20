#!/bin/bash

set -e

while true; do
    read -rp "Enter Wi-Fi SSID (network name): " WIFI_SSID
    if [[ -n "$WIFI_SSID" ]]; then
        echo "Using SSID: $WIFI_SSID"
        break
    else
        echo "SSID cannot be empty!"
    fi
done

while true; do
    read -rsp "Enter Wi-Fi password: " WIFI_PASS
    echo
    if [[ -n "$WIFI_PASS" ]]; then
            echo "Password accepted."
            break
    else
        echo "Password cannot be empty!"
    fi
done

DEFAULT_IFACE="wlan0"
while true; do
    read -rp "Enter Wi-Fi interface name [default: $DEFAULT_IFACE]: " WIFI_IFACE
    WIFI_IFACE=${WIFI_IFACE:-$DEFAULT_IFACE}

    if ip link show "$WIFI_IFACE" &>/dev/null; then
        echo "Using interface: $WIFI_IFACE"
        break
    else
        echo "Interface '$WIFI_IFACE' not found. Available wireless interfaces:"
        iw dev 2>/dev/null | awk '/Interface/ {print $2}' || ip -brief link show
        echo "If your wireless interface has a different name, enter it now. To try again with default, press Enter."
    fi
done

echo "Configuring Wi-Fi connection '$WIFI_SSID' via NetworkManager..."
sudo nmcli connection add type wifi ifname "$WIFI_IFACE" con-name "$WIFI_SSID" ssid "$WIFI_SSID" || true
sudo nmcli connection modify "$WIFI_SSID" wifi-sec.key-mgmt wpa-psk
sudo nmcli connection modify "$WIFI_SSID" wifi-sec.psk "$WIFI_PASS"
sudo nmcli connection modify "$WIFI_SSID" connection.autoconnect yes
sudo nmcli connection modify "$WIFI_SSID" connection.autoconnect-priority 100
sudo nmcli connection modify "$WIFI_SSID" ipv4.method auto ipv6.method auto

echo "Attempting to connect to Wi-Fi (may fail if AP not in range)..."
sudo nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASS" ifname "$WIFI_IFACE" || true

# Prompt user for URL (default: http://127.0.0.1:3000)
while true; do
    read -rp "Enter the Kiosk URL (must start with http:// or https://) [default: http://127.0.0.1:3000]: " KIOSK_URL
    KIOSK_URL=${KIOSK_URL:-http://127.0.0.1:3000}
    
    if [[ $KIOSK_URL =~ ^https?:// ]]; then
        echo "Using URL: $KIOSK_URL"
        break
    else
        echo "Invalid URL! Must start with http:// or https://"
    fi
done

echo "Using URL: $KIOSK_URL"

echo "### Updating system and installing required packages..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y snapd sway

echo "### Installing Chromium (Snap)..."
sudo snap install chromium

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

echo "### Setting up Sway configuration..."
sudo -u kiosk mkdir -p /home/kiosk/.config/sway
sudo tee /home/kiosk/.config/sway/config > /dev/null << EOF
# Sway configuration for kiosk mode

# Hide mouse cursor immediately
seat * {
    hide_cursor 0
}

# Keyboard layout
input * {
    xkb_layout us
}

# Launch Chromium in kiosk mode
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

echo "### Configuring automatic start of Sway..."
sudo tee -a /home/kiosk/.profile > /dev/null << EOF

# Automatically start Sway on login
if [ -z "\$DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
    exec sway
fi
EOF

echo "### Adjusting permissions..."
sudo chown -R kiosk:kiosk /home/kiosk/.config
sudo chmod -R 700 /home/kiosk/.config

echo "### Setup complete. Rebooting system..."
sudo reboot
