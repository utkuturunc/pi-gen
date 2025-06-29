#!/bin/bash -e

echo "Running stage 2 custom script"

echo "FIRST_USER_NAME: ${FIRST_USER_NAME}"
echo "SFTP_USER: ${SFTP_USER}"

# Install dependencies
on_chroot <<EOF
apt-get update
apt-get install -y sshfs sshpass udisks2 sudo
EOF

# Install FileBrowser
on_chroot <<EOF
curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
EOF

# Prepare script dirs and mount points
mkdir -p "${ROOTFS_DIR}/home/${FIRST_USER_NAME}/scripts"
mkdir -p "${ROOTFS_DIR}/mnt/usb"
mkdir -p "${ROOTFS_DIR}/mnt/sftp"

# Set proper ownership for mount points
on_chroot <<EOF
chown ${FIRST_USER_NAME}:${FIRST_USER_NAME} /mnt/usb /mnt/sftp
EOF

# --- USB Mount Script ---
cat >"${ROOTFS_DIR}/home/${FIRST_USER_NAME}/scripts/mount-usb.sh" <<EOF
#!/bin/bash

USB_UUID="$USB_UUID"
USB_MOUNT="/mnt/usb"
USB_RETRIES=3
USB_DELAY=5

for i in \$(seq 1 \$USB_RETRIES); do
    if mountpoint -q "\$USB_MOUNT"; then
        echo "[mount-usb] Already mounted"
        exit 0
    fi

    if DEVICE=\$(blkid -U "\$USB_UUID" 2>/dev/null); then
        mount "\$DEVICE" "\$USB_MOUNT" && {
            echo "[mount-usb] Mounted \$DEVICE successfully"
            exit 0
        }
    fi

    echo "[mount-usb] Attempt \$i of \$USB_RETRIES failed"
    sleep \$USB_DELAY
done

echo "[mount-usb] Failed to mount USB"
exit 1
EOF

# --- SFTP Mount Script ---
cat >"${ROOTFS_DIR}/home/${FIRST_USER_NAME}/scripts/mount-sftp.sh" <<EOF
#!/bin/bash

SFTP_USER="$SFTP_USER"
SFTP_PASS="$SFTP_PASS"
SFTP_HOST="$SFTP_HOST"
SFTP_REMOTE_PATH="$SFTP_REMOTE_PATH"
SFTP_MOUNT="/mnt/sftp"
SFTP_RETRIES=2
SFTP_DELAY=300

for i in \$(seq 1 \$SFTP_RETRIES); do
    if mountpoint -q "\$SFTP_MOUNT"; then
        echo "[mount-sftp] Already mounted"
        exit 0
    fi

    sshfs_opts="-o reconnect -o ServerAliveInterval=15 -o ServerAliveCountMax=3  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o debug -o sshfs_debug"

    sshpass -p "\$SFTP_PASS" sshfs "\$SFTP_USER@\$SFTP_HOST:\$SFTP_REMOTE_PATH" "\$SFTP_MOUNT" \$sshfs_opts && {
        echo "[mount-sftp] Mounted successfully"
        exit 0
    }

    echo "[mount-sftp] Attempt \$i of \$SFTP_RETRIES failed"
    sleep \$SFTP_DELAY
done

echo "[mount-sftp] Failed to mount SFTP"
exit 1
EOF

# Permissions
on_chroot <<EOF
chmod +x "/home/${FIRST_USER_NAME}/scripts/mount-usb.sh"
chmod +x "/home/${FIRST_USER_NAME}/scripts/mount-sftp.sh"
chown -R "${FIRST_USER_NAME}:${FIRST_USER_NAME}" "/home/${FIRST_USER_NAME}/scripts"
EOF

# --- Systemd Services ---

# USB
cat <<EOF >"${ROOTFS_DIR}/etc/systemd/system/mount-usb.service"
[Unit]
Description=Mount USB if present
After=local-fs.target

[Service]
ExecStart=/home/${FIRST_USER_NAME}/scripts/mount-usb.sh
Type=oneshot
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

# SFTP
cat <<EOF >"${ROOTFS_DIR}/etc/systemd/system/mount-sftp.service"
[Unit]
Description=Mount SFTP share
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/home/${FIRST_USER_NAME}/scripts/mount-sftp.sh
Type=oneshot
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

# --- Configure FileBrowser ---
mkdir -p "${ROOTFS_DIR}/home/${FIRST_USER_NAME}/.filebrowser"

# Create FileBrowser config
cat <<EOF >"${ROOTFS_DIR}/home/${FIRST_USER_NAME}/.filebrowser/filebrowser.json"
{
    "port": 8080,
    "baseURL": "",
    "address": "0.0.0.0",
    "log": "stdout",
    "database": "/home/${FIRST_USER_NAME}/.filebrowser/filebrowser.db",
    "root": "/mnt"
}
EOF

# Initialize FileBrowser database and create default user
on_chroot <<EOF
cd /home/${FIRST_USER_NAME}/.filebrowser
/usr/local/bin/filebrowser config init --config /home/${FIRST_USER_NAME}/.filebrowser/filebrowser.json
/usr/local/bin/filebrowser config set --minimum-password-length 1 --config /home/${FIRST_USER_NAME}/.filebrowser/filebrowser.json
/usr/local/bin/filebrowser users add ${FIRST_USER_NAME} ${FIRST_USER_PASS} --perm.admin=true --config /home/${FIRST_USER_NAME}/.filebrowser/filebrowser.json
chown -R ${FIRST_USER_NAME}:${FIRST_USER_NAME} /home/${FIRST_USER_NAME}/.filebrowser
EOF

# --- FileBrowser systemd service ---
cat <<EOF >"${ROOTFS_DIR}/etc/systemd/system/filebrowser.service"
[Unit]
Description=File Browser
After=network.target

[Service]
ExecStart=/usr/local/bin/filebrowser --config /home/${FIRST_USER_NAME}/.filebrowser/filebrowser.json
WorkingDirectory=/home/${FIRST_USER_NAME}
User=${FIRST_USER_NAME}
Restart=always

[Install]
WantedBy=multi-user.target
EOF

on_chroot <<EOF
systemctl enable mount-usb.service
systemctl enable mount-sftp.service
systemctl enable filebrowser
EOF
