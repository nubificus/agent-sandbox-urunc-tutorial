# Sandbox images

Two minimal sandbox images for the urunc tutorial, plus the Go executor source.

```
images/
├── executor/          Go HTTP executor source (static binary, no dependencies)
├── urunc-qemu-minimal/  urunc + QEMU image (bzImage + virtiofs rootfs)
└── urunc-fc-minimal/    urunc + Firecracker image (vmlinux + block rootfs)
```

## Quick build reference

```
kernel/             Kernel source config and build instructions
  microvm-x86_64-6.1.config   — minimal config (based on Firecracker CI)
  README.md                    — build steps for bzImage and vmlinux
```

Both images share the same kernel config; only the output artifact differs:

| Image | Kernel artifact | Size | Hypervisor |
|---|---|---|---|
| urunc-qemu-minimal | bzImage (7.9 MB) | ~25 MB | QEMU KVM |
| urunc-fc-minimal | vmlinux (43 MB) | ~65 MB | Firecracker |

## Pre-built images

```bash
# QEMU
docker pull harbor.nbfc.io/nubificus/urunc-sandbox-qemu-minimal:latest

# Firecracker
docker pull harbor.nbfc.io/nubificus/urunc-sandbox-fc-minimal:latest
```
