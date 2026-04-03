#!/usr/bin/env bash
#
# Phase 06: Package VM image
# Converts the rootfs into OVA (VirtualBox) and QCOW2 (QEMU/KVM) formats
#
set -euo pipefail

log "Packaging VM image..."

RAW_DISK="${BUILD_DIR}/${VM_NAME}.raw"
QCOW2_DISK="${OUTPUT_DIR}/${VM_NAME}.qcow2"
OVA_FILE="${OUTPUT_DIR}/${VM_NAME}.ova"

# ── Unmount chroot filesystems ─────────────────────────────────────
log "Unmounting chroot filesystems..."
for mp in "${ROOTFS}/dev/pts" "${ROOTFS}/dev" "${ROOTFS}/proc" "${ROOTFS}/sys" "${ROOTFS}/run"; do
    mountpoint -q "$mp" 2>/dev/null && umount -lf "$mp" || true
done

# ── Create raw disk image ─────────────────────────────────────────
log "Creating raw disk image (${DISK_SIZE})..."
qemu-img create -f raw "$RAW_DISK" "$DISK_SIZE"

# Create partition table and single ext4 partition
log "Partitioning disk..."
parted -s "$RAW_DISK" mklabel msdos
parted -s "$RAW_DISK" mkpart primary ext4 1MiB 100%
parted -s "$RAW_DISK" set 1 boot on

# Set up loop device
LOOP_DEV=$(losetup --find --show --partscan "$RAW_DISK")
PART_DEV="${LOOP_DEV}p1"

# Wait for partition device to appear
sleep 2
if [[ ! -b "$PART_DEV" ]]; then
    partprobe "$LOOP_DEV"
    sleep 2
fi

# Format partition
log "Formatting partition as ext4..."
mkfs.ext4 -L "AgentOS" "$PART_DEV"

# Mount and copy rootfs
MOUNT_POINT="${BUILD_DIR}/mnt"
mkdir -p "$MOUNT_POINT"
mount "$PART_DEV" "$MOUNT_POINT"

log "Copying rootfs to disk image (this takes a few minutes)..."
rsync -aHAX --info=progress2 "${ROOTFS}/" "${MOUNT_POINT}/"

# ── Install GRUB bootloader ───────────────────────────────────────
log "Installing GRUB bootloader..."

# Mount necessary filesystems for GRUB install
mount --bind /dev  "${MOUNT_POINT}/dev"
mount --bind /dev/pts "${MOUNT_POINT}/dev/pts"
mount -t proc proc "${MOUNT_POINT}/proc"
mount -t sysfs sys "${MOUNT_POINT}/sys"

# Update fstab with correct UUID
PART_UUID=$(blkid -s UUID -o value "$PART_DEV")
cat > "${MOUNT_POINT}/etc/fstab" <<EOF
UUID=${PART_UUID}  /  ext4  errors=remount-ro  0  1
EOF

# Install GRUB
chroot "${MOUNT_POINT}" grub-install --target=i386-pc "$LOOP_DEV"

# Configure GRUB (varies by edition)
if [[ "$EDITION" == "--server" ]]; then
    cat > "${MOUNT_POINT}/etc/default/grub" <<'GRUB'
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="AgentOS"
GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200n8"
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_OS_PROBER=true
GRUB_TERMINAL="serial console"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB
else
    cat > "${MOUNT_POINT}/etc/default/grub" <<'GRUB'
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="AgentOS"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_OS_PROBER=true
GRUB_THEME=/boot/grub/themes/agentos/theme.txt
GRUB
fi

chroot "${MOUNT_POINT}" update-grub

# Unmount
umount -lf "${MOUNT_POINT}/dev/pts" || true
umount -lf "${MOUNT_POINT}/dev" || true
umount -lf "${MOUNT_POINT}/proc" || true
umount -lf "${MOUNT_POINT}/sys" || true
umount -lf "${MOUNT_POINT}"

# Detach loop device
losetup -d "$LOOP_DEV"

# ── Convert to QCOW2 ──────────────────────────────────────────────
log "Converting to QCOW2..."
qemu-img convert -f raw -O qcow2 -c "$RAW_DISK" "$QCOW2_DISK"
ok "QCOW2 image: ${QCOW2_DISK} ($(du -h "$QCOW2_DISK" | cut -f1))"

# ── Convert to OVA (VirtualBox) ───────────────────────────────────
log "Creating OVA for VirtualBox..."

VMDK_DISK="${BUILD_DIR}/${VM_NAME}.vmdk"
qemu-img convert -f raw -O vmdk "$RAW_DISK" "$VMDK_DISK"

# Create OVF descriptor
VMDK_SIZE=$(stat -c%s "$VMDK_DISK")
cat > "${BUILD_DIR}/${VM_NAME}.ovf" <<OVF
<?xml version="1.0"?>
<Envelope ovf:version="1.0"
  xmlns="http://schemas.dmtf.org/ovf/envelope/1"
  xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"
  xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
  xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData"
  xmlns:vbox="http://www.virtualbox.org/ovf/machine">

  <References>
    <File ovf:href="${VM_NAME}.vmdk" ovf:id="file1" ovf:size="${VMDK_SIZE}"/>
  </References>

  <DiskSection>
    <Info>Virtual disk information</Info>
    <Disk ovf:capacity="${DISK_SIZE//G/}" ovf:capacityAllocationUnits="byte * 2^30"
          ovf:diskId="vmdisk1" ovf:fileRef="file1" ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/>
  </DiskSection>

  <NetworkSection>
    <Info>Logical networks</Info>
    <Network ovf:name="NAT">
      <Description>NAT network</Description>
    </Network>
  </NetworkSection>

  <VirtualSystem ovf:id="${VM_NAME}">
    <Info>AgentOS Virtual Machine</Info>
    <Name>${VM_NAME}</Name>
    <OperatingSystemSection ovf:id="96">
      <Info>Ubuntu 64-bit</Info>
    </OperatingSystemSection>

    <VirtualHardwareSection>
      <Info>Virtual hardware requirements</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemType>virtualbox-2.2</vssd:VirtualSystemType>
      </System>

      <Item>
        <rasd:Caption>${VM_CPUS} virtual CPUs</rasd:Caption>
        <rasd:Description>Number of virtual CPUs</rasd:Description>
        <rasd:InstanceID>1</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>${VM_CPUS}</rasd:VirtualQuantity>
      </Item>

      <Item>
        <rasd:AllocationUnits>MegaBytes</rasd:AllocationUnits>
        <rasd:Caption>${VM_RAM} MB of memory</rasd:Caption>
        <rasd:Description>Memory Size</rasd:Description>
        <rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>${VM_RAM}</rasd:VirtualQuantity>
      </Item>

      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:Caption>disk1</rasd:Caption>
        <rasd:Description>Disk Image</rasd:Description>
        <rasd:HostResource>/disk/vmdisk1</rasd:HostResource>
        <rasd:InstanceID>3</rasd:InstanceID>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>

      <Item>
        <rasd:AutomaticAllocation>true</rasd:AutomaticAllocation>
        <rasd:Caption>Ethernet adapter on NAT</rasd:Caption>
        <rasd:Connection>NAT</rasd:Connection>
        <rasd:InstanceID>4</rasd:InstanceID>
        <rasd:ResourceType>10</rasd:ResourceType>
      </Item>
    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>
OVF

# Package OVA (tar of OVF + VMDK)
log "Packaging OVA..."
cd "${BUILD_DIR}"
tar -cf "$OVA_FILE" "${VM_NAME}.ovf" "${VM_NAME}.vmdk"
cd -

ok "OVA image: ${OVA_FILE} ($(du -h "$OVA_FILE" | cut -f1))"

# ── Compressed raw image for cloud import (Server only) ──────────
if [[ "$EDITION" == "--server" ]]; then
    RAW_GZ="${OUTPUT_DIR}/${VM_NAME}.raw.gz"
    log "Creating compressed raw image for cloud import (AWS/GCP/Azure)..."
    gzip -k -c "$RAW_DISK" > "$RAW_GZ"
    ok "Raw cloud image: ${RAW_GZ} ($(du -h "$RAW_GZ" | cut -f1))"
fi

# ── Clean up raw disk ─────────────────────────────────────────────
log "Cleaning up intermediate files..."
rm -f "$RAW_DISK" "$VMDK_DISK" "${BUILD_DIR}/${VM_NAME}.ovf"

# ── Generate checksums ─────────────────────────────────────────────
log "Generating checksums..."
cd "${OUTPUT_DIR}"
if [[ "$EDITION" == "--server" ]]; then
    sha256sum "${VM_NAME}.qcow2" "${VM_NAME}.ova" "${VM_NAME}.raw.gz" > SHA256SUMS
else
    sha256sum "${VM_NAME}.qcow2" "${VM_NAME}.ova" > SHA256SUMS
fi
cd -

ok "Checksums: ${OUTPUT_DIR}/SHA256SUMS"
ok "Build complete!"
