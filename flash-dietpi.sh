#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -i, --image <path>    Path to DietPi image (default: DietPi_RPi234-ARMv8-Trixie.img.xz)"
    echo "  -t, --target <dev>    Target block device (default: /dev/mmcblk0)"
    echo "  -s, --secrets <path>  Path to secrets env file (default: ${HOME}/homelab.env)"
    echo "  -h, --help            Display this help message"
    exit 1
}

# Default values
IMAGE="DietPi_RPi234-ARMv8-Trixie.img.xz"
TARGET="/dev/mmcblk0"
SECRETS_FILE="${HOME}/homelab.env"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--image)
            IMAGE="$2"
            shift 2
            ;;
        -t|--target)
            TARGET="$2"
            shift 2
            ;;
        -s|--secrets)
            SECRETS_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown option $1"
            usage
            ;;
    esac
done

if [ ! -f "$IMAGE" ]; then
    echo "Error: Image file '$IMAGE' not found."
    exit 1
fi

if [ ! -f "$SECRETS_FILE" ]; then
    echo "Error: Secrets file '$SECRETS_FILE' not found."
    exit 1
fi

if [ ! -b "$TARGET" ]; then
    echo "Error: Target '$TARGET' is not a block device. Did you insert your SD card?"
    exit 1
fi

if lsblk -n -o MOUNTPOINT "$TARGET" 2>/dev/null | grep -qv '^$'; then
    echo "Error: Target device '$TARGET' (or its partitions) has active mounts:"
    lsblk -o NAME,MOUNTPOINT "$TARGET"
    echo "Unmount the device manually before proceeding."
    exit 1
fi

source "$SECRETS_FILE"

echo "==> Flashing $IMAGE to $TARGET..."
xzcat "$IMAGE" | sudo dd of="$TARGET" bs=4M status=progress conv=fsync
sync

echo "==> Waiting for partitions to register..."
sleep 2
sudo blockdev --rereadpt "$TARGET"
udevadm settle

# Determine boot partition name
if [ -b "${TARGET}p1" ]; then
    BOOT_PART="${TARGET}p1"
else
    BOOT_PART="${TARGET}1"
fi

TEMP_DIR=$(mktemp -d)
echo "==> Mounting boot partition ($BOOT_PART)..."
sudo mount "$BOOT_PART" "$TEMP_DIR"

cleanup() {
    echo "==> Unmounting and syncing..."
    sudo umount "$TEMP_DIR"
    rmdir "$TEMP_DIR"
    sync
}
trap 'cleanup' EXIT

# Batch application function taking a target file and an array of KEY=VALUE strings
apply_configs() {
    local file="$1"
    shift

    for entry in "$@"; do
        local key="${entry%%=*}"
        local val="${entry#*=}"

        # Check if key exists (commented or uncommented) using fixed-string match
        if sudo grep -qF "${key}=" "$file"; then
            # Escape regex special characters (including brackets) for sed
            local esc_key
            esc_key=$(printf '%s\n' "$key" | sed 's/[[\.*^$()+?{|]/\\&/g; s/]/\\&/g')
            sudo sed -i -E "s|^[[:space:]#]*${esc_key}[[:space:]]*=.*|${key}=${val}|" "$file"
        else
            echo "Error: Required configuration key '${key}' not found in $(basename "$file"). Aborting." >&2
            exit 1
        fi
    done
}

echo "==> Configuring dietpi.txt..."
dietpi_settings=(
    "AUTO_SETUP_GLOBAL_PASSWORD=$DIETPI_PASSWORD"
    "AUTO_SETUP_KEYBOARD_LAYOUT=fi"
    "AUTO_SETUP_TIMEZONE=Europe/Helsinki"
    "AUTO_SETUP_NET_ETHERNET_ENABLED=0"
    "AUTO_SETUP_NET_WIFI_ENABLED=1"
    "AUTO_SETUP_SWAPFILE_LOCATION=zram"
    "AUTO_UNMASK_LOGIND=1"
    "AUTO_SETUP_CUSTOM_SCRIPT_EXEC=0"
    "AUTO_SETUP_SSH_PUBKEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEQZWl1cIfsXXKlTWenUlXqVG+txLKagrJatP+82OGin veke@thinkpad-e470"
    "AUTO_SETUP_LOGGING_INDEX=-2"
    "AUTO_SETUP_INSTALL_SOFTWARE_ID=58"
    "AUTO_SETUP_AUTOMATED=1"
    "SURVEY_OPTED_IN=0"
    "CONFIG_CHECK_DIETPI_UPDATES=0"
    "CONFIG_CHECK_APT_UPDATES=0"
    )
apply_configs "$TEMP_DIR/dietpi.txt" "${dietpi_settings[@]}"

echo "==> Configuring dietpi-wifi.txt..."
wifi_settings=(
    "aWIFI_SSID[0]='$WIFI_SSID'"
    "aWIFI_KEY[0]='$WIFI_KEY'"
)
apply_configs "$TEMP_DIR/dietpi-wifi.txt" "${wifi_settings[@]}"

# Create Automation_Custom_Script.sh
sudo tee "$TEMP_DIR/Automation_Custom_Script.sh" > /dev/null << 'EOF'
#!/usr/bin/env bash

export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get install -y \
    git \
    podman \
    podman-compose \
    uidmap \
    passt \
    netavark \
    aardvark-dns \
    nftables \
    dbus-user-session \
    ncurses-term

TARGET_HOME="/home/dietpi"
HOMELAB_DIR="${TARGET_HOME}/homelab"

git clone https://github.com/vnopanen/homelab.git "$HOMELAB_DIR"

cat << 'ENV_EOF' > "${HOMELAB_DIR}/.env"
VAULTWARDEN_ADMIN_TOKEN=
SAMBA_USER=
SAMBA_PASSWORD=
CLOUDFLARE_TUNNEL_TOKEN=

ENV_EOF

chmod 600 "$HOMELAB_DIR/.env"

mkdir -p \
    ${HOMELAB_DIR}/data/adguard/work \
    ${HOMELAB_DIR}/data/adguard/conf \
    ${HOMELAB_DIR}/data/vaultwarden \
    ${HOMELAB_DIR}/data/filebrowser \
    ${HOMELAB_DIR}/data/samba/share

cat << 'FILEBROWSER_EOF' > "${HOMELAB_DIR}/data/filebrowser/config.yaml"
server:
  cacheDir: /home/filebrowser/data/tmp
  sources:
    - path: /srv
      config:
        defaultEnabled: true

FILEBROWSER_EOF

TAILSCALE_AUTH_KEY=
tailscale up --authkey="$TAILSCALE_AUTH_KEY"

# allow rootless users to bind ports < 1024 (e.g., 80, 443)
echo "net.ipv4.ip_unprivileged_port_start=53" > /etc/sysctl.d/99-podman-ports.conf
sysctl --system

# Enable user lingering for dietpi user so rootless services persist across reboots
loginctl enable-linger dietpi

SYSTEMD_USER_DIR="$TARGET_HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"

cat << 'SERVICE_EOF' > "$SYSTEMD_USER_DIR/homelab.service"
[Unit]
Description=Homelab Rootless Podman Compose Stack
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=true
WorkingDirectory=/home/dietpi/homelab
ExecStart=/usr/bin/podman compose up -d
ExecStop=/usr/bin/podman compose down

[Install]
WantedBy=default.target

SERVICE_EOF

chown -R dietpi:dietpi "$TARGET_HOME/.config" "$HOMELAB_DIR"

su - dietpi -c "systemctl --user daemon-reload && systemctl --user enable --now homelab.service"

EOF

echo "==> Configuring Automation_Custom_Script.sh..."
secrets=(
    VAULTWARDEN_ADMIN_TOKEN=${VAULTWARDEN_ADMIN_TOKEN}
    SAMBA_USER=${SAMBA_USER}
    SAMBA_PASSWORD=${SAMBA_PASSWORD}
    CLOUDFLARE_TUNNEL_TOKEN=${CLOUDFLARE_TUNNEL_TOKEN}
    TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY}
    )
apply_configs "$TEMP_DIR/Automation_Custom_Script.sh" "${secrets[@]}"

echo "==> Flash and configuration complete!"
