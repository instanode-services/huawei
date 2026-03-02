#!/bin/bash

cat <<'EOF' > /etc/motd

	Welcome to Instanodes Service

EOF

sudo bash -c "$(curl -fsSL https://teleport.instanodes.io/scripts/68861d0f7b63220de942529bc5cee022/install-node.sh)"

echo "for huawei-cloud"
echo "----------------------------------------------install initial package----------------------------------------------"

# Function to install package if not already installed
install_if_missing() {
  PKG=$1
  CMD=$2

  if ! command -v "$CMD" >/dev/null 2>&1; then
    echo "$PKG not found, installing..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG"
  else
    echo "$PKG already installed, skipping..."
  fi
}

# Check and install required packages
install_if_missing "logrotate" "logrotate"
install_if_missing "jq" "jq"
install_if_missing "postfix" "postfix"
install_if_missing "curl" "curl"
install_if_missing "unzip" "unzip"
install_if_missing "docker.io" "docker"
install_if_missing "docker-compose" "docker-compose"

echo '----------------------------------------------Start hcloud----------------------------------------------'
mkdir -p /root/kooCli && cd /root/kooCli
curl -sSL https://ap-southeast-3-hwcloudcli.obs.ap-southeast-3.myhuaweicloud.com/cli/latest/hcloud_install.sh -o ./hcloud_install.sh && bash ./hcloud_install.sh -y
yes | hcloud -y
echo '----------------------------------------------Done with hcloud ----------------------------------------------'

# Download the auto-disk-update script
echo "FOR HUAWEI_CLOUD"
cd /root
curl -o /root/huawei-auto-disk-update.sh https://raw.githubusercontent.com/ashu1211/script-public/refs/heads/main/huawei-auto-disk-update.sh
rm -f /root/auto-disk-update.sh
mv /root/huawei-auto-disk-update.sh /root/auto-disk-update.sh
chmod +x /root/auto-disk-update.sh

SCRIPT_PATH="/root/auto-disk-update.sh"
CRON_JOB="*/2 * * * * /root/auto-disk-update.sh >> /var/log/auto-disk-update.log 2>&1"

# Check if the cron job is already set
if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH"; then
  if crontab -l 2>/dev/null | grep -q "$CRON_JOB"; then
    echo "Crontab entry for $SCRIPT_PATH is already correctly set. No changes needed."
  else
    echo "Updating crontab entry for $SCRIPT_PATH..."
    crontab -l | grep -v "$SCRIPT_PATH" | crontab -  # Remove incorrect entry
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -  # Add correct entry
    echo "Crontab entry updated successfully."
  fi
else
  echo "Adding crontab entry for $SCRIPT_PATH..."
  (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
  echo "Crontab entry added successfully."
fi

# Reload crontab
sudo systemctl restart cron

# Source ~/.bashrc to apply changes
source ~/.bashrc

echo "Setup completed."
