#!/bin/bash

# WARNING: this script will destroy data on the selected disk.

set -xeuo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

CLEAN=${CLEAN:-''}

function clean() {
  umount /mnt/boot || true
  zfs umount -a || true
  zpool destroy zroot || true
}

# If CLEAN is set, clean up any broken state we may have lying around
if [ -n "$CLEAN" ]; then
  clean
fi

# Ensure we've got the system booted in EFI
ls /sys/firmware/efi/efivars > /dev/null

# Ensure we have the zfs module
modprobe zfs

MIRRORLIST_URL="https://www.archlinux.org/mirrorlist/?country=US&protocol=https&use_mirror_status=on"

# Only rank the mirrors if we're not cleaning up, indicating this is a fresh run
if [ -z "$CLEAN" ]; then
  echo "Updating mirror list"
  curl -s "$MIRRORLIST_URL" | \
      sed -e 's/^#Server/Server/' -e '/^#/d' | \
      rankmirrors -n 5 - > /etc/pacman.d/mirrorlist
fi

### Set up logging ###
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

# Set the time from NTP
timedatectl set-ntp true

### Setup the disk and partitions ###
### Make sure we provide enough room on boot for multiple kernels.
devicelist=$(lsblk --nodeps --paths --list --noheadings --sort size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --menu "Select installation disk" 0 0 0 ${devicelist}) || exit 1
clear

# Make 3 partitions:
# * 2G boot
# * 1G secrets/encryption/whatev partition
# * remaining root partition, for ZFS
parted --script "${device}" -- \
  mklabel gpt \
  mkpart ESP fat32 1Mib 2GiB \
  set 1 boot on \
  mkpart primary ext4 2GiB 3GiB \
  mkpart primary ext4 3GiB 100%

# Simple globbing was not enough as on one device I needed to match /dev/mmcblk0p1
# but not /dev/mmcblk0boot1 while being able to match /dev/sda1 on other devices.
part_boot="$(ls "${device}"* | grep -E "^${device}p?1$")"
part_root="$(ls "${device}"* | grep -E "^${device}p?3$")"

# Wipe any old fs stuff from the new partitions
wipefs "${part_boot}"
wipefs "${part_root}"
# Write some random data to the beginning of the partitions to guarantee we
# don't confuse anything later
dd if=/dev/urandom of="$part_root" bs=512 count=20480

# Set up the EFI partition
mkfs.vfat -F32 "${part_boot}"

# Set up ZFS partitioning
# Create a pool made up of the drive
zpool create -f zroot -m none "$part_root"

# Create the root (/), with default attributes (|| true because it will fail to
# mount)
# TODO: Figure out a better way to recover from the mount failure. Catching any
# error is not a good idea.
zfs create \
  -o atime=off \
  -o compression=on \
  -o mountpoint=/ \
  -o encryption=on \
  -o keyformat=passphrase \
  zroot/ROOT || true

# Create datasets for all the other partitions we want to isolate, setting
# their mountpoint (|| true because it will fail to mount)
# TODO: Figure out a better way to recover from the mount failure. Catching any
# error is not a good idea.
for path in /home /var /var/log /var/log/journal /etc /data /data /docker; do
  zfs create -o mountpoint=$path zroot/ROOT$path || true
done

# Unmount everything for now
zfs unmount -a

# Set up posix ACL for the journal
zfs set acltype=posixacl zroot/ROOT/var/log/journal
zfs set xattr=sa zroot/ROOT/var/log/journal

zpool set bootfs=zroot/ROOT zroot
zpool export zroot

# Import the pool by id, to ensure we get consistent mounting
zpool import -l -d /dev/disk/by-id -R /mnt zroot
# Set the cachefile for the pool, and then copy it over to the chroot fs
zpool set cachefile=/etc/zfs/zpool.cache zroot
mkdir -p /mnt/etc/zfs
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache

# Make a /boot directory and mount our EFI boot partition there
mkdir /mnt/boot
mount "$part_boot" /mnt/boot

### Install and configure the base system ###

# usage: pacstrap [options] root [packages...]
#
#   Options:
#     -C config      Use an alternate config file for pacman
#     -c             Use the package cache on the host, rather than the target
#     -G             Avoid copying the host's pacman keyring to the target
#     -i             Prompt for package confirmation when needed
#     -M             Avoid copying the host's mirrorlist to the target
#
#     -h             Print this help message
#
# pacstrap installs packages to the specified new root directory. If no packages
# are given, pacstrap defaults to the "base" group.
pacstrap /mnt \
  base \
  git \
  linux \
  linux-firmware \
  linux-headers \
  linux-lts \
  linux-lts-headers \
  neovim \
  networkmanager \
  openssh \
  sudo \
  tmux

# Generate an fstab and put it in the chroot environment. We only want the boot
# partition in it; the rest gets handled by ZFS
genfstab -t PARTUUID /mnt | grep -A 1 "$part_boot" > /mnt/etc/fstab

# Set up the hostname and /etc/hosts
function set_hostname() {
  hostname=$(dialog --stdout --inputbox "Enter hostname" 0 0) || exit 1
  clear
  : ${hostname:?"hostname cannot be empty"}

  echo "$hostname" > /mnt/etc/hostname

  hostname_short="$(echo "$hostname" | cut -d '.' -f 1)"
  cat <<EOF > /mnt/etc/hosts
127.0.0.1 localhost
::1       localhost
::1       $hostname $hostname_short
127.0.1.1	$hostname $hostname_short
EOF
}
set_hostname

# Set the timezone
arch-chroot /mnt ln -sf /usr/share/zoneinfo/America/Los_Angeles /etc/localtime

# Sync time
arch-chroot /mnt hwclock --systohc

# Truncate the vconsole file, since we'll append to it below, and don't want to
# duplicate contents on subsequent runs of the script.
truncate --size 0 /mnt/etc/vconsole.conf

# Set up tho locale. Setting this before installing the zfs modules means that
# the language setting should get picked up and be set correctly in the ramdisk.
echo "en_US.UTF-8 UTF-8" > /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
echo "KEYMAP=dvorak" >> /mnt/etc/vconsole.conf

# Set up the hooks correctly for allowing us to unlock the encrypted partitions.
# Doing this here _should_ mean that when we install the zfs- modules below, the
# kernels' ramdisks etc. should pick it up.
sed -i \
  's/^HOOKS.*/HOOKS=(base udev keyboard keymap autodetect modconf block encrypt zfs filesystems)/' \
  /mnt/etc/mkinitcpio.conf

# Install zfs modules
cat <<EOF >>/mnt/etc/pacman.conf
[archzfs]
Server = https://archzfs.com/\$repo/x86_64
EOF

arch-chroot /mnt pacman-key --recv-keys F75D9D76
arch-chroot /mnt pacman-key --lsign-key F75D9D76
arch-chroot /mnt pacman -Sy --needed --noconfirm zfs-linux zfs-linux-lts

# Install the bootloader
arch-chroot /mnt bootctl install

# Enable SSH and nm
arch-chroot /mnt systemctl enable sshd
arch-chroot /mnt systemctl enable NetworkManager.service
arch-chroot /mnt systemctl enable systemd-timesyncd.service

# Set up wifi
if dialog --yesno "Configure wifi for target system?" 0 0; then
  wifi_ssid=$(dialog --stdout --inputbox "Enter wifi SSID" 0 0) || exit 1
  clear
  : ${wifi_ssid:?"Wifi SSID cannot be empty"}

  wifi_password=$(dialog --stdout --inputbox "Enter wifi password (will print)" 0 0) || exit 1
  clear
  : ${wifi_password:?"Wifi password cannot be empty"}

  cat <<EOF > "/mnt/etc/NetworkManager/system-connections/$wifi_ssid.nmconnection"
[connection]
id=$wifi_ssid
type=wifi

[wifi]
mode=infrastructure
ssid=$wifi_ssid

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
psk=$wifi_password

[ipv4]
dns-search=
method=auto

[ipv6]
addr-gen-mode=stable-privacy
dns-search=
method=auto
EOF
fi

# Set default boot options, which are pretty straightforward. This will attempt
# to mount the root fs from the zroot pool, and will prompt for encryption
# passwords as though you'd invoked 'zpool import -l zroot'.
boot_options="zfs=zroot rw"

# Figure out what system we're installing on, in case we need to make any
# customization to the boot options.
product_name=$(dmidecode \
  | grep -A 3 'System Information' \
  | grep 'Product Name' \
  | cut -d : -f 2 \
  | tr -d '[:blank:]')

# TODO: Use regex here instead of all the grepping and cutting.
if [ "${product_name}" == "XPS159560" ]; then
  # The XPS 15 9560 has a hi-res display with a discrete graphics card, so we'll
  # install and make default a larger font
  arch-chroot /mnt pacman -Sy --needed --noconfirm terminus-font
  echo FONT=ter-132n >> /mnt/etc/vconsole.conf

  # We also need to set the following options to avoid hanging at some point
  # after boot, in improve power consumption
  boot_options="${boot_options} nouveau.modeset=0 acpi_rev_override=1 enable_fbc=1 enable_psr=1 disable_power_well=0 pci=noaer"
fi

# Write bootloader entries for the standard kernel also the LTS kernel, which
# can be used for fallback.
cat <<EOF > /mnt/boot/loader/entries/arch.conf
title    Arch Linux
linux    /vmlinuz-linux
initrd   /initramfs-linux.img
options  $boot_options
EOF

# This is the LTS kernel, and should stay stable even if something breaks with
# the zfs-linux module.
cat <<EOF > /mnt/boot/loader/entries/arch-lts.conf
title    Arch Linux LTS
linux    /vmlinuz-linux-lts
initrd   /initramfs-linux-lts.img
options  $boot_options
EOF

# Boot the standard kernel by default
cat <<EOF > /mnt/boot/loader/loader.conf
default arch
timeout 3
EOF

function add_user() {
  # figure out which user we want to use
  user=$(dialog --stdout --inputbox "Enter admin username" 0 0) || exit 1
  clear
  : ${user:?"user cannot be empty"}

  # Add the user
  arch-chroot /mnt useradd -mU \
    --uid 1185 \
    -G wheel,uucp,video,audio,storage,games,input \
    "$user"

  # Set the password
  echo -n "$user password: "; arch-chroot /mnt passwd "$user"
}
add_user

# Write a first-boot file that we'll run the first time the system is
# rebooted after running this install script. This will configure things
# correctly so that the system continues booting.
cat <<EOF > "/mnt/home/$user/first-boot.sh"
#!/bin/bash

set -euo pipefail

echo "


!! WE WILL NOW PERFORM FIRST-BOOT CONFIGURATION OF THE ZFS SYSTEM !!
   DO NOT SKIP THIS OR YOUR SYSTEM WILL FAIL TO BOOT AGAIN

   If you don't have an internet connection, sort that out and then
   run './first-boot.sh'. Afterwards, remove the final line from
   .bashrc so this doesn't run again.


"

# Check for internet
ping -c 1 github.com > /dev/null

sudo zpool set cachefile=/etc/zfs/zpool.cache zroot
sudo systemctl enable zfs.target
sudo systemctl enable zfs-import-cache
sudo systemctl enable zfs-mount
sudo systemctl enable zfs-import.target
sudo zgenhostid \$(hostid)
sudo mkinitcpio -p linux
sudo mkinitcpio -p linux-lts

echo "


First run configuration has been completed. It's suggested that you restart
before proceeding to do anything else. You can find the script that was used to
install the system in \$(pwd).

"

EOF
chmod +x "/mnt/home/$user/first-boot.sh"

cat <<EOF >> "/mnt/home/$user/.bashrc"
# Run the first-boot.sh script on first boot, delete it, and clear the line from
# bashrc
~/first-boot.sh && rm ~/first-boot.sh && sed -i '/first-boot/d' ~/.bashrc
EOF

# Make sure everything in the user's home directory is owned by them
arch-chroot /mnt chown -R "$user:" "/home/$user"

# Set up the wheel group to have sudo access
echo "%wheel ALL=(ALL) ALL" >> /mnt/etc/sudoers

# Set a random password for the root user.
password="$(openssl rand -base64 32)"
echo "root:$password" | chpasswd --root /mnt

# Copy this script into the new installation for reference
cp "$0" /mnt/home/$user/$(basename "$0")

# Unmount everything to get ready for reboot
umount /mnt/boot
zfs umount -a
zpool export zroot

cat <<EOF



Installation complete!

You may now reboot, or enter the installed environment
via \`arch-chroot /mnt\`.
EOF
