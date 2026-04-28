# Minimal kernel for urunc (QEMU + Firecracker)

Both the QEMU and Firecracker urunc images use the same minimal Linux 6.1 kernel
built from Firecracker's upstream microvm config. The only difference is the
output artifact: **bzImage** for QEMU, **vmlinux** (uncompressed ELF) for
Firecracker.

## Build

```bash
# Install build dependencies (Debian/Ubuntu)
sudo apt-get install -y flex bison pahole libelf-dev libssl-dev bc make gcc

# Download kernel source
KVER=6.1.169
curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KVER}.tar.xz" \
  | tar -xJ

cd linux-${KVER}

# Apply the microvm config (based on Firecracker's upstream CI config)
cp ../microvm-x86_64-6.1.config .config
make ARCH=x86_64 olddefconfig

# Build bzImage for QEMU (7.9 MB compressed)
make ARCH=x86_64 bzImage -j$(nproc)
# Output: arch/x86/boot/bzImage

# Build vmlinux for Firecracker (43 MB uncompressed ELF)
make ARCH=x86_64 vmlinux -j$(nproc)
# Output: vmlinux
```

## Config notes

`microvm-x86_64-6.1.config` is derived from
[Firecracker's CI config](https://github.com/firecracker-microvm/firecracker/blob/main/resources/guest_configs/microvm-kernel-ci-x86_64-6.1.config)
with `make olddefconfig` applied. Key features enabled:

| Feature | Why |
|---|---|
| `CONFIG_VIRTIO_NET` | VM networking |
| `CONFIG_VIRTIO_BLK` | Block device rootfs (Firecracker) |
| `CONFIG_EXT4_FS` | Rootfs filesystem |
| `CONFIG_9P_FS` + `CONFIG_VIRTIO_FS` | Shared-fs rootfs (QEMU virtiofs) |
| `CONFIG_BINFMT_ELF` | Run the Go executor |
| `CONFIG_TMPFS` | `/tmp` inside VM |

USB, PCI, ACPI, and most driver subsystems are disabled — not needed for
KVM microVMs.

## Sizes

| Artifact | Size | Used by |
|---|---|---|
| bzImage | 7.9 MB | urunc QEMU |
| vmlinux | 43 MB | urunc Firecracker |
| Original urunc-sandbox-go kernel | ~7 MB | urunc QEMU (reference) |
| Original urunc-sandbox-fc kernel | 325 MB | urunc FC (bloated, replaced) |
