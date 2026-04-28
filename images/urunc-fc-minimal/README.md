# urunc Firecracker minimal image

A minimal urunc + Firecracker image. The kernel is a flat uncompressed ELF
(`vmlinux`) — Firecracker does not accept a compressed bzImage. The executor
and the urunc init process (`/init`) are embedded directly in the OCI layers;
urunc packages them as a block device snapshot at pod start.

**Image size: ~65 MB** (vs ~199 MB for the debian-based reference image,
which had a 325 MB uncompressed kernel)

## Prerequisites

1. **vmlinux** — build from `../../kernel/` (43 MB):
   ```bash
   cd ../../kernel
   # follow README.md to build, then:
   cp linux-6.1.169/vmlinux .
   ```

2. **init** — urunc's Firecracker init process. Extract from any FC urunc image:
   ```bash
   docker create --name tmp harbor.nbfc.io/nubificus/urunc-sandbox-fc:latest
   docker cp tmp:/init ./init
   docker rm tmp
   ```
   Or build from source: `https://github.com/urunc-dev/urunc`

## Build (plain Docker)

```bash
# From this directory (vmlinux and init must be present)
docker build -t urunc-sandbox-fc-minimal:latest .
```

## Build (Bunny)

```bash
cd ../executor
CGO_ENABLED=0 go build -ldflags="-s -w" -o ../urunc-fc-minimal/executor .
cd ../urunc-fc-minimal

# Build the rootfs tar (busybox + executor)
mkdir -p rootfs/bin
docker run --rm busybox:musl sh -c 'cat /bin/busybox' > rootfs/bin/busybox
chmod +x rootfs/bin/busybox
cp executor rootfs/
tar -cf rootfs.tar -C rootfs .

docker buildx build --file bunnyfile \
  -t harbor.nbfc.io/nubificus/urunc-sandbox-fc-minimal:latest .
```

## Notes

- Firecracker does **not** support virtiofs — `mountRootfs: true` here tells
  urunc to package the OCI layers as a block device using the devmapper
  snapshotter.
- The `containerd` config must have devmapper enabled
  (`/var/lib/rancher/k3s/agent/etc/containerd/config.toml`).
- `kubectl exec` does not work for urunc pods — use `kubectl logs` or the
  `/command` HTTP endpoint.
