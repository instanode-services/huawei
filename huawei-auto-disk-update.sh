#!/bin/bash
if ! dpkg -s postfix >/dev/null 2>&1; then
    echo "Postfix not found, installing..."
    # sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postfix
else
    echo "Postfix is already installed."
fi
sleep 10

# Variables
METADATA_URL="http://169.254.169.254/openstack/latest/meta_data.json"
DF_CMD="df -T"  # Using df -T to avoid human-readable sizes
JQ_CMD="jq -r"
HCL_CMD="hcloud"
RESIZE_PERCENT=5
SLEEP_DURATION=10
DISK_USAGE_THRESHOLD=95  # Percentage threshold for disk usage

# Function to get ID_SERIAL for a given device
get_id_serial() {
  local device=$1
  local base_device="${device##*/}"

  local id_serial=$(find /dev/disk/by-id/ -type l -lname "*$base_device" -exec readlink -f {} \; | xargs -I{} basename $(dirname {})/$(basename {}))
  id_serial=$(echo "$id_serial" | head -n 1)

  if [[ -z "$id_serial" || "$id_serial" == "$base_device" ]]; then
    id_serial=$(find /dev/disk/by-id/ -type l -lname "*$base_device" -exec basename {} \; | grep -v "$base_device" | head -n 1)
  fi

  if [[ "$id_serial" =~ ^virtio-(.{20})-part[0-9]+$ ]]; then
    id_serial="${BASH_REMATCH[1]}"
  elif [[ "$id_serial" =~ ^virtio-(.{20}) ]]; then
    id_serial="${BASH_REMATCH[1]}"
  else
    id_serial=""
  fi

  echo "Extracted ID_SERIAL for $device is: $id_serial"
  echo "$id_serial"
}

# Function to resize disk
resize_disk() {
  local device=$1
  local fstype=$2
  local use_percent=$3
  local mount_point=$4

  # Fetch metadata and attachments
  PROJECTID=$(curl -s "$METADATA_URL" | $JQ_CMD '.project_id')
  INSTANCEID=$(curl -s "$METADATA_URL" | $JQ_CMD '.uuid')
  REGION=$(curl -s "$METADATA_URL" | $JQ_CMD '.region_id')

  echo "Project ID: $PROJECTID"
  echo "Instance ID: $INSTANCEID"
  echo "Region: $REGION"

  ATTACHMENTS=$($HCL_CMD ECS ListServerVolumeAttachments --cli-region=$REGION --project_id=$PROJECTID --server_id=$INSTANCEID | $JQ_CMD '.volumeAttachments[] | "\(.device): \(.id)"')

  echo "Attachments:"
  echo "$ATTACHMENTS"

  base_device=$(echo "$device" | sed 's/[0-9]$//')

  # Get ID_SERIAL
  id_serial=$(get_id_serial "$device")
  echo "ID_SERIAL for $device is: $id_serial"

  potential_volume_ids=$(echo "$ATTACHMENTS" | grep "${id_serial}" | cut -d' ' -f2)
  volume_id=$(echo "$potential_volume_ids" | head -n 1)

  echo "Potential volume IDs: $potential_volume_ids"
  echo "Selected volume_id: $volume_id"

  if [[ -z "$volume_id" ]]; then
    echo "No match found with ID_SERIAL. Exiting."
    exit 1
  fi

  # Query current volume details
  volume_details=$($HCL_CMD EVS ShowVolume --cli-region=$REGION --project_id=$PROJECTID --volume_id=$volume_id)
  current_volume_size_gb=$(echo "$volume_details" | $JQ_CMD '.volume.size')

  echo "Current Volume Size (from API): $current_volume_size_gb GB"

  # Calculate new size (always greater than current size)
  new_size=$(( (current_volume_size_gb * (100 + RESIZE_PERCENT) + 99) / 100 ))  # round up
  if (( new_size <= current_volume_size_gb )); then
    new_size=$((current_volume_size_gb + 1))
  fi

  echo "Resizing from $current_volume_size_gb GB → $new_size GB..."

  # Resize EVS volume
  response=$($HCL_CMD EVS ResizeVolume --cli-region=$REGION --os-extend.new_size=$new_size --project_id=$PROJECTID --volume_id=$volume_id --bssParam.isAutoPay="true")

  if [[ "$response" =~ "error" ]]; then
    echo "Error resizing volume: $response"
    return
  fi

  sleep $SLEEP_DURATION

  # Grow filesystem
  if [[ "$fstype" == "xfs" ]]; then
    echo "Growing XFS filesystem on $mount_point..."
    growpart "$base_device" 1
    xfs_growfs "$mount_point"
  elif [[ "$fstype" == "ext4" ]]; then
    echo "Growing ext4 filesystem on $device..."
    growpart "$base_device" 1
    resize2fs "$device"
  else
    echo "Unsupported filesystem type $fstype on $device. Skipping grow."
  fi

  echo "Volume $device resized successfully."
}

# Main check
echo "Checking volumes consuming more than $DISK_USAGE_THRESHOLD%:"
df_output=$($DF_CMD)
echo "$df_output" | awk 'NR>1' | while read -r line; do
  device=$(echo "$line" | awk '{print $1}')
  fstype=$(echo "$line" | awk '{print $2}')
  use_percent=$(echo "$line" | awk '{print $6}' | tr -d '%')
  mount_point=$(echo "$line" | awk '{print $7}')

  if [[ -z "$use_percent" || ! "$use_percent" =~ ^[0-9]+$ ]]; then
    echo "Invalid usage for $device: $use_percent (skipping)"
    continue
  fi

  if (( use_percent > DISK_USAGE_THRESHOLD )); then
    echo "Disk $device is using $use_percent% (threshold: $DISK_USAGE_THRESHOLD%)"
    resize_disk "$device" "$fstype" "$use_percent" "$mount_point"
  fi
done
