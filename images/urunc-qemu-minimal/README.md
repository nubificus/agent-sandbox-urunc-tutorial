# urunc QEMU minimal image

A minimal urunc + QEMU image containing only the kernel (bzImage) and a
statically-linked Go HTTP executor. The container rootfs is mounted into
the VM via virtiofs at boot — no separate rootfs image is needed.

**Image size: ~25 MB** (vs ~53 MB for the debian-based reference image)

## Prerequisites

1. **bzImage** — build from `../../kernel/` (7.9 MB):
   ```bash
   cd ../../kernel
   # follow README.md to build, then:
   cp linux-6.1.169/arch/x86/boot/bzImage .
   ```

2. **urunit** — urunc's init process. Extract from any urunc image:
   ```bash
   docker create --name tmp harbor.nbfc.io/nubificus/urunc-sandbox-go:latest
   docker cp tmp:/urunit ./urunit
   docker rm tmp
   ```
   Or build from source: `https://github.com/urunc-dev/urunc`

## Build (plain Docker)

```bash
# From this directory (bzImage and urunit must be present)
docker build -t urunc-sandbox-qemu-minimal:latest .
```

## Build (Bunny)

Bunny provides a higher-level build that handles rootfs packaging automatically.

```bash
# Build the static executor first
cd ../executor
CGO_ENABLED=0 go build -ldflags="-s -w" -o ../urunc-qemu-minimal/executor .
cd ../urunc-qemu-minimal

# Package the rootfs as a tar (busybox + executor)
docker run --rm busybox:musl tar -c /bin/busybox | \
  tar -x --strip-components=2 -C rootfs/
cp executor rootfs/
tar -cf rootfs.tar -C rootfs .

# Build with Bunny (requires buildkit with bunny frontend)
docker buildx build --file bunnyfile \
  -t harbor.nbfc.io/nubificus/urunc-sandbox-qemu-minimal:latest .
```

## Test

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: qemu-min-test
  namespace: urunc-tutorial
spec:
  runtimeClassName: urunc
  restartPolicy: Never
  dnsPolicy: None
  dnsConfig:
    nameservers: ["8.8.8.8"]
  containers:
  - name: executor
    image: urunc-sandbox-qemu-minimal:latest
    ports:
    - containerPort: 8080
EOF

POD_IP=$(kubectl get pod qemu-min-test -n urunc-tutorial -o jsonpath='{.status.podIP}')
curl http://$POD_IP:8080/health
```
