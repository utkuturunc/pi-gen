#!/bin/bash -e

echo "Running stage 2 custom script"

# Load config file
source "${STAGE_DIR}/05-custom/custom.conf"

# Disable first-boot user rename system
rm -f /etc/xdg/autostart/piwiz.desktop

# Install dependencies
apt-get update
apt-get install -y sshfs sshpass udisks2 sudo

# Install FileBrowser
curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

# --- Create or Rename User FIRST ---
if id "$OS_USER" &>/dev/null; then
  echo "User $OS_USER already exists"
else
  if id pi &>/dev/null; then
    usermod -l "$OS_USER" -d /home/"$OS_USER" -m pi
    groupmod -n "$OS_USER" pi
  else
    useradd -m -s /bin/bash "$OS_USER"
  fi

  echo "User $OS_USER created"
fi

echo "Setting password and sudo rights"

# Set password and sudo rights
echo "$OS_USER:$OS_PASS" | chpasswd
usermod -aG sudo "$OS_USER"

# Prepare script and config dirs
mkdir -p /home/$OS_USER/scripts

# Write mount config
cat <<EOF >/home/$OS_USER/scripts/mount.conf
SFTP_USER="$SFTP_USER"
SFTP_PASS="$SFTP_PASS"
SFTP_HOST="$SFTP_HOST"
SFTP_REMOTE_PATH="$SFTP_REMOTE_PATH"
SFTP_MOUNT="/mnt/sftp"
SFTP_RETRIES=3
SFTP_DELAY=5

USB_UUID="$USB_UUID"
USB_MOUNT="/mnt/usb"
USB_RETRIES=3
USB_DELAY=5
EOF

# --- USB Mount Script ---
cat <<'EOF' >/home/$OS_USER/scripts/mount-usb.sh
#!/bin/bash
source /home/$OS_USER/scripts/mount.conf

mkdir -p "$USB_MOUNT"

for i in $(seq 1 "$USB_RETRIES"); do
    if mountpoint -q "$USB_MOUNT"; then
        echo "[mount-usb] Already mounted"
        exit 0
    fi

    if DEVICE=$(blkid -U "$USB_UUID" 2>/dev/null); then
        mount "$DEVICE" "$USB_MOUNT" && {
            echo "[mount-usb] Mounted $DEVICE successfully"
            exit 0
        }
    fi

    echo "[mount-usb] Attempt $i of $USB_RETRIES failed"
    sleep "$USB_DELAY"
done

echo "[mount-usb] Failed to mount USB"
exit 1
EOF

# --- SFTP Mount Script ---
cat <<'EOF' >/home/$OS_USER/scripts/mount-sftp.sh
#!/bin/bash
source /home/$OS_USER/scripts/mount.conf

mkdir -p "$SFTP_MOUNT"

for i in $(seq 1 "$SFTP_RETRIES"); do
    if mountpoint -q "$SFTP_MOUNT"; then
        echo "[mount-sftp] Already mounted"
        exit 0
    fi

    sshfs_opts="-o reconnect -o ServerAliveInterval=15 -o ServerAliveCountMax=3"

    sshpass -p "$SFTP_PASS" sshfs "$SFTP_USER@$SFTP_HOST:$SFTP_REMOTE_PATH" "$SFTP_MOUNT" $sshfs_opts && {
        echo "[mount-sftp] Mounted successfully"
        exit 0
    }

    echo "[mount-sftp] Attempt $i of $SFTP_RETRIES failed"
    sleep "$SFTP_DELAY"
done

echo "[mount-sftp] Failed to mount SFTP"
exit 1
EOF

# Permissions
chmod +x /home/$OS_USER/scripts/*.sh
chown -R $OS_USER:$OS_USER /home/$OS_USER/scripts

# --- Systemd Services ---

# USB
cat <<EOF >/etc/systemd/system/mount-usb.service
[Unit]
Description=Mount USB if present
After=local-fs.target

[Service]
ExecStart=/home/$OS_USER/scripts/mount-usb.sh
Type=oneshot
RemainAfterExit=true
User=$OS_USER

[Install]
WantedBy=multi-user.target
EOF

# SFTP
cat <<EOF >/etc/systemd/system/mount-sftp.service
[Unit]
Description=Mount SFTP share
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/home/$OS_USER/scripts/mount-sftp.sh
Type=oneshot
RemainAfterExit=true
User=$OS_USER

[Install]
WantedBy=multi-user.target
EOF

# --- Wi-Fi Configuration ---
mkdir -p /etc/wpa_supplicant
cat <<EOF >/etc/wpa_supplicant/wpa_supplicant.conf
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=DE

network={
  ssid="$WIFI_SSID"
  psk="$WIFI_PASS"
  key_mgmt=WPA-PSK
}
EOF

chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf

# --- Set Hostname ---
echo "${HOSTNAME}" >"${ROOTFS_DIR}/etc/hostname"
echo "127.0.1.1		${HOSTNAME}" >>"${ROOTFS_DIR}/etc/hosts"

on_chroot <<EOF
	SUDO_USER="${OS_USER}" raspi-config nonint do_net_names 1
EOF

# --- FileBrowser systemd service ---
cat <<EOF >/etc/systemd/system/filebrowser.service
[Unit]
Description=File Browser
After=network.target

[Service]
ExecStart=/usr/local/bin/filebrowser -r /mnt -a 0.0.0.0 --port 8080
User=$OS_USER
Restart=always

[Install]
WantedBy=multi-user.target
EOF

on_chroot <<EOF
systemctl enable ssh
EOF

systemctl enable mount-usb.service
systemctl enable mount-sftp.service
systemctl enable filebrowser