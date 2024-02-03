#!/bin/bash

# Greeting message
clear
echo "This script is proudly presented to you by HOKOHOST."
echo "Stay updated with the latest versions by visiting our website at https://hokohost.com/scripts."
echo "If you find this script valuable and would like to support our work,"
echo "Please consider making a donation at https://hokohost.com/donate."
echo "Your support is greatly appreciated!"
echo ""

os_images_ordered=(
  "Debian 10 EOL-No Support"
  "Debian 11"
  "Debian 12"
  "Ubuntu Server 20.04"
  "Ubuntu Server 22.04"
  "Alma Linux 8"
  "Alma Linux 9"
)

declare -A os_images=(
  ["Debian 10 EOL-No Support"]="https://cloud.debian.org/images/cloud/buster/latest/debian-10-generic-amd64.qcow2"
  ["Debian 11"]="https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2"
  ["Debian 12"]="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
  ["Ubuntu Server 20.04"]="https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"
  ["Ubuntu Server 22.04"]="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  ["Alma Linux 8"]="https://repo.almalinux.org/almalinux/8/cloud/x86_64/images/AlmaLinux-8-GenericCloud-latest.x86_64.qcow2"
  ["Alma Linux 9"]="https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
)

select_os() {
  echo "Please select the OS you want to import:"
  select os_choice in "${os_images_ordered[@]}"; do
    os=${os_choice}
    if [ -n "$os" ]; then
      os_name=$(echo "$os" | tr ' ' '-') # Convert spaces to hyphens for VM name
      echo "You have selected: $os"
      break
    else
      echo "Invalid selection. Please try again."
    fi
  done
}

specify_storage() {
  while true; do
    read -rp "Enter the target storage (e.g., local-lvm): " storage
    if [ -z "$storage" ]; then
      echo "You must input a storage to continue."
    elif ! pvesm list "$storage" &>/dev/null; then
      echo "The specified storage does not exist. Please try again."
    else
      echo "Selected storage: $storage"
      break
    fi
  done
}

specify_vmid() {
  while true; do
    read -rp "Enter the VMID you want to assign (e.g., 1000): " vmid
    if [ -z "$vmid" ]; then
      echo "You must input a VMID to continue."
    elif qm status "$vmid" &>/dev/null; then
      echo "The VMID $vmid is already in use. Please enter another one."
    else
      echo "Selected VMID: $vmid"
      break
    fi
  done
}

setup_template() {
  image_url="${os_images[$os]}"
  echo "Downloading the OS image from $image_url..."
  cd /var/tmp || exit
  wget -O image.qcow2 "$image_url" --quiet --show-progress

  echo "Creating the VM as '$os_name'..."
  qm create "$vmid" --name "$os_name" --memory 2048 --net0 virtio,bridge=vmbr0

  echo "Importing the disk image..."
  disk_import_output=$(qm importdisk "$vmid" image.qcow2 "$storage" --format qcow2)

  # Extract the storage volume identifier from the output
  storage_volume_identifier=$(echo "$disk_import_output" | grep 'Successfully imported disk image' | awk '{print $NF}')

  if [ -z "$storage_volume_identifier" ]; then
    echo "Failed to capture storage volume identifier from import output."
    echo "Output from import: $disk_import_output"
    echo "Failed to import disk image."
    rm -f image.qcow2
    exit 1
  fi

  # Construct the full disk path using the storage identifier and VMID
  full_disk_path="/dev/$storage/$storage_volume_identifier"

  echo "Disk image imported and available as $full_disk_path"

  echo "Configuring VM to use the imported disk..."
  qm set "$vmid" --scsihw virtio-scsi-pci --scsi0 "$full_disk_path"
  qm set "$vmid" --ide2 "$storage":cloudinit
  qm set "$vmid" --boot c --bootdisk scsi0
  qm set "$vmid" --serial0 socket
  qm template "$vmid"

  echo "New template created for $os with VMID $vmid."

  echo "Deleting the downloaded image to save space..."
  rm -f image.qcow2

  # Return the full path of the imported disk image for further use
  echo "$full_disk_path"
}

install_qemu_guest_agent() {
  # Make sure to take the disk_image_path declared globally
  global disk_image_path

  while true; do
    read -rp "Do you want to install qemu-guest-agent in the VM image? [y/N] " install_qga
    case "$install_qga" in
      y|Y)
        if ! command -v virt-customize &>/dev/null; then
          while true; do
            read -rp "virt-customize is required but not installed. Install now? [y/N] " install_vc
            case "$install_vc" in
              y|Y)
                apt-get update && apt-get install -y libguestfs-tools
                if [ $? -ne 0 ]; then
                  echo "Failed to install libguestfs-tools. Please manually install the package and try again."
                  exit 1
                fi
                break ;;
              n|N)
                echo "Skipping the installation of qemu-guest-agent."
                return 0 ;;
              *)
                echo "Invalid input. Please answer y or n." ;;
            esac
          done
        fi

        if [ -f "$disk_image_path" ]; then
          if virt-customize -a "$disk_image_path" --install qemu-guest-agent; then
            echo "qemu-guest-agent has been successfully installed in the image."
          else
            echo "Failed to install qemu-guest-agent."
            exit 1
          fi
        else
          echo "Disk image not found at $disk_image_path."
          exit 1
        fi
        break ;;
      n|N)
        echo "Continuing without installing qemu-guest-agent."
        break ;;
      *)
        echo "Invalid input. Please answer y or n." ;;
    esac
  done
}

want_to_continue() {
  read -rp "Do you want to continue and make another OS template? [y/N] " choice
  case "$choice" in
    y|Y ) ;;
    * ) echo "Exiting script."; exit 0 ;;
  esac
}

# Main loop
while true; do
  select_os
  specify_storage
  specify_vmid
  if setup_template; then
    install_qemu_guest_agent
  fi
  want_to_continue
done
