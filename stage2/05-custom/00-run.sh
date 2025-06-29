#!/bin/bash
set -e

source /stage2/05-custom/custom.conf

# Install dependencies
apt-get update
apt-get install -y sshfs sshpass udisks2 curl bash fuse blkid sudo

# Install FileBrowser
curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

mkdir -p /home/$OS_USER/scripts

cat <<EOF >/home/$OS_USER/scripts/mount.conf
SFTP_USER="$SFTP_USER"
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

# USB mount script (mount by UUID)
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
            echo "[mount-usb] Mounted $DEVICE by UUID successfully"
            exit 0
        }
    fi

    echo "[mount-usb] USB device with UUID $USB_UUID not ready, attempt $i of $USB_RETRIES"
    sleep "$USB_DELAY"
done

echo "[mount-usb] Failed to mount USB by UUID $USB_UUID"
exit 1
EOF

# SFTP mount script using sshfs
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

    sshpass -p "$SFTP_PASS" sshfs $SFTP_USER@$SFTP_HOST:"$SFTP_REMOTE_PATH" "$SFTP_MOUNT" $sshfs_opts && {
        echo "[mount-sftp] Mounted successfully"
        exit 0
    }

    echo "[mount-sftp] Failed to mount, attempt $i of $SFTP_RETRIES"
    sleep "$SFTP_DELAY"
done

echo "[mount-sftp] All $SFTP_RETRIES attempts failed"
exit 1
EOF

chmod +x /home/$OS_USER/scripts/*.sh
chown -R $OS_USER:$OS_USER /home/$OS_USER/scripts

# Create systemd service for USB mount
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

# Create systemd service for SFTP mount
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

systemctl enable mount-usb.service
systemctl enable mount-sftp.service

# Create OS user or rename pi to OS_USER if necessary
if id "$OS_USER" &>/dev/null; then
  echo "User $OS_USER exists"
else
  if id pi &>/dev/null; then
    usermod -l "$OS_USER" -d /home/"$OS_USER" -m pi
    groupmod -n "$OS_USER" pi
  else
    useradd -m -s /bin/bash "$OS_USER"
  fi
fi

# Set password for OS_USER
echo "$OS_USER:$OS_PASS" | chpasswd
