# End-to-end demo walkthrough
## urunc + agent-sandbox on Kubernetes

---

## Slide bullets

- Kubernetes AI agents need **VM isolation per task** — container namespaces are not enough
- **agent-sandbox** CRDs give a declarative lifecycle: `SandboxTemplate` → `SandboxClaim` → `SandboxWarmPool`
- **urunc** boots a real KVM VM (Firecracker or QEMU) from a plain OCI image — same `kubectl` UX, one extra label
- Cold TTFR: runc ~3 s, **urunc-FC ~3 s** (same!), kata ~5 s — VM isolation for free
- WarmPool pre-boots VMs: **~700 ms** claim-to-HTTP for any runtime

---

## Part 1 — Install agent-sandbox

Apply the core controller (Sandbox CRD) and the extensions controller (SandboxClaim, SandboxTemplate, SandboxWarmPool):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.4.2/manifest.yaml
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.4.2/extensions.yaml
```

Wait for the controller to be ready:

```bash
kubectl -n agent-sandbox-system rollout status deployment/agent-sandbox-controller
```

Verify CRDs are installed:

```bash
kubectl get crds | grep agents
# sandboxclaims.extensions.agents.x-k8s.io
# sandboxes.agents.x-k8s.io
# sandboxtemplates.extensions.agents.x-k8s.io
# sandboxwarmpools.extensions.agents.x-k8s.io
```

---

## Part 2 — Install urunc

### 2a. Set up the devmapper thin-pool (Firecracker needs it)

Firecracker uses the `devmapper` containerd snapshotter. Create a loop-device-backed thin pool:

```bash
sudo mkdir -p /var/lib/containerd/io.containerd.snapshotter.v1.devmapper

# Create sparse backing files (100 GB data, 10 GB metadata)
sudo truncate -s 100G /var/lib/containerd/io.containerd.snapshotter.v1.devmapper/data
sudo truncate -s 10G  /var/lib/containerd/io.containerd.snapshotter.v1.devmapper/meta

# Attach loop devices
DATA_DEV=$(sudo losetup --find --show \
  /var/lib/containerd/io.containerd.snapshotter.v1.devmapper/data)
META_DEV=$(sudo losetup --find --show \
  /var/lib/containerd/io.containerd.snapshotter.v1.devmapper/meta)

# Create the thin-pool DM device
DATA_SIZE=$(sudo blockdev --getsz $DATA_DEV)
sudo dmsetup create containerd-pool \
  --table "0 $DATA_SIZE thin-pool $META_DEV $DATA_DEV 512 32768"

sudo dmsetup ls | grep containerd-pool
```

### 2b. Configure containerd for urunc + devmapper

Add the urunc runtime to containerd:

```bash
sudo tee /etc/containerd/config.d/urunc-deploy.toml <<'EOF'
[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.urunc]
runtime_type = "io.containerd.urunc.v2"
container_annotations = ["com.urunc.unikernel.*"]
snapshotter = "devmapper"
EOF
```

Add devmapper snapshotter config to the k3s containerd template (or the equivalent for your distribution):

```bash
# For k3s: edit /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl
# Add inside the file:
sudo tee -a /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl <<'EOF'

[plugins.'io.containerd.snapshotter.v1.devmapper']
  pool_name = "containerd-pool"
  root_path = "/var/lib/containerd/io.containerd.snapshotter.v1.devmapper"
  base_image_size = "10GB"
  discard_blocks = true
  fs_type = "ext2"
EOF
```

Restart the container runtime:

```bash
# k3s
sudo systemctl restart k3s
# Or for plain containerd:
# sudo systemctl restart containerd
```

### 2c. Install urunc binaries

```bash
URUNC_VERSION=0.7.0
curl -fsSL -o /tmp/urunc \
  "https://github.com/urunc-dev/urunc/releases/download/v${URUNC_VERSION}/urunc_linux_amd64"
curl -fsSL -o /tmp/containerd-shim-urunc-v2 \
  "https://github.com/urunc-dev/urunc/releases/download/v${URUNC_VERSION}/containerd-shim-urunc-v2_linux_amd64"

sudo install -m 0755 /tmp/urunc /usr/local/bin/urunc
sudo install -m 0755 /tmp/containerd-shim-urunc-v2 /usr/local/bin/containerd-shim-urunc-v2
```

### 2d. Register the urunc RuntimeClass

```bash
kubectl apply -f - <<'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: urunc
handler: urunc
EOF
```

Verify:

```bash
kubectl get runtimeclass urunc
```

---

## Part 3 — Build the executor image

The executor is a static Go HTTP server that exposes `/health`, `/execute` (Python/shell), `/command`, and file I/O endpoints.

### 3a. Build the Go binary

```bash
cd images/executor
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -ldflags="-s -w" -o executor .
```

### 3b. Build the standard OCI image (runc / gvisor / kata)

No kernel needed — the container runtime provides the kernel.

```bash
cd images/oci-executor
docker build -t harbor.nbfc.io/nubificus/oci-executor:latest .
docker push harbor.nbfc.io/nubificus/oci-executor:latest
```

---

## Part 4 — Build the kernel

Both urunc variants use the same minimal Linux 6.1 kernel (Firecracker's microvm config).

```bash
cd kernel

# Install build dependencies
sudo apt-get install -y flex bison pahole libelf-dev libssl-dev bc make gcc

# Download source
KVER=6.1.169
curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KVER}.tar.xz" | tar -xJ
cd linux-${KVER}

# Apply the microvm config
cp ../microvm-x86_64-6.1.config .config
make ARCH=x86_64 olddefconfig

# Build both artifacts (takes ~5 min on 4 cores)
make ARCH=x86_64 bzImage vmlinux -j$(nproc)

# Copy results out
cp arch/x86/boot/bzImage  ..   # 7.9 MB — used by urunc QEMU
cp vmlinux                ..   # 43 MB  — used by urunc Firecracker
```

---

## Part 5 — Build the urunc images

### 5a. urunc + QEMU (virtiofs rootfs)

```bash
cd images/urunc-qemu-minimal

# Copy kernel and urunit init
cp ../../kernel/bzImage .
docker create --name tmp harbor.nbfc.io/nubificus/urunc-sandbox-go:latest
docker cp tmp:/urunit ./urunit
docker rm tmp

docker build -t harbor.nbfc.io/nubificus/urunc-sandbox-qemu-minimal:latest .
docker push harbor.nbfc.io/nubificus/urunc-sandbox-qemu-minimal:latest
```

### 5b. urunc + Firecracker (devmapper block rootfs)

```bash
cd images/urunc-fc-minimal

# Copy kernel and init
cp ../../kernel/vmlinux .
docker create --name tmp harbor.nbfc.io/nubificus/urunc-sandbox-fc:latest
docker cp tmp:/init ./init
docker rm tmp

docker build -t harbor.nbfc.io/nubificus/urunc-sandbox-fc-minimal:latest .
docker push harbor.nbfc.io/nubificus/urunc-sandbox-fc-minimal:latest
```

### 5c. Build with Bunny (alternative: OCI-native build tool)

Bunny produces a fully-labelled urunc image from a `bunnyfile` without manually
copying kernel/init:

```bash
cd images/urunc-fc-minimal

# Build executor and rootfs tar
cp ../executor/executor .
mkdir -p rootfs/bin
docker run --rm busybox:musl sh -c 'cat /bin/busybox' > rootfs/bin/busybox
chmod +x rootfs/bin/busybox
cp executor rootfs/
tar -cf rootfs.tar -C rootfs .

# Build via Bunny (requires Docker buildx and the Bunny BuildKit frontend)
docker buildx build --file bunnyfile \
  -t harbor.nbfc.io/nubificus/urunc-sandbox-fc-minimal:latest \
  --push .
```

---

## Part 6 — Create the namespace

```bash
kubectl create namespace urunc-tutorial
```

---

## Part 7 — Verify: plain urunc pod (cold VM boot)

Pull the image on the node first (devmapper snapshotter must initialise it):

```bash
sudo crictl pull harbor.nbfc.io/nubificus/urunc-sandbox-fc-minimal:latest
```

Apply the pod:

```bash
kubectl apply -f 00-hello-pod.yaml
# (or inline:)
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: urunc-hello
  namespace: urunc-tutorial
spec:
  runtimeClassName: urunc
  restartPolicy: Never
  dnsPolicy: None
  dnsConfig:
    nameservers: ["8.8.8.8"]
  containers:
  - name: executor
    image: harbor.nbfc.io/nubificus/urunc-sandbox-fc-minimal:latest
    ports:
    - containerPort: 8080
EOF
```

Watch it start and hit the HTTP endpoint:

```bash
kubectl get pod urunc-hello -n urunc-tutorial -w

IP=$(kubectl get pod urunc-hello -n urunc-tutorial -o jsonpath='{.status.podIP}')

# Health check
curl http://$IP:8080/health

# Run code inside the VM
curl -s -X POST http://$IP:8080/execute \
  -H 'Content-Type: application/json' \
  -d '{"code":"import platform; print(platform.uname())", "language":"python"}'

# Run a shell command
curl -s -X POST http://$IP:8080/command \
  -H 'Content-Type: application/json' \
  -d '{"command":"uname -r"}'
```

Delete:

```bash
kubectl delete pod urunc-hello -n urunc-tutorial
```

---

## Part 8 — SandboxTemplate + SandboxClaim (cold, declarative)

Create the template that describes what a sandbox looks like:

```bash
kubectl apply -f 02-template.yaml
# (or inline:)
kubectl apply -f - <<'EOF'
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxTemplate
metadata:
  name: urunc-fc
  namespace: urunc-tutorial
spec:
  podTemplate:
    spec:
      runtimeClassName: urunc
      dnsPolicy: None
      dnsConfig:
        nameservers: ["8.8.8.8"]
      containers:
      - name: executor
        image: harbor.nbfc.io/nubificus/urunc-sandbox-fc-minimal:latest
        ports:
        - containerPort: 8080
EOF
```

Claim a sandbox — the controller creates the pod and a stable Service:

```bash
kubectl apply -f 02-claim.yaml
# (or inline:)
kubectl apply -f - <<'EOF'
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: agent-task-1
  namespace: urunc-tutorial
spec:
  sandboxTemplateRef:
    name: urunc-fc
EOF
```

Watch the claim become Ready:

```bash
kubectl get sandboxclaim agent-task-1 -n urunc-tutorial -w
```

Once Ready, get the IP and use it:

```bash
kubectl get sandboxclaim agent-task-1 -n urunc-tutorial -o json | python3 -m json.tool

IP=$(kubectl get sandboxclaim agent-task-1 -n urunc-tutorial \
  -o jsonpath='{.status.sandbox.podIPs[0]}')

curl http://$IP:8080/health
curl -s -X POST http://$IP:8080/execute \
  -H 'Content-Type: application/json' \
  -d '{"code":"print(\"hello from the agent sandbox\")", "language":"python"}'
```

Release the sandbox (controller deletes the pod):

```bash
kubectl delete sandboxclaim agent-task-1 -n urunc-tutorial
```

---

## Part 9 — SandboxWarmPool (pre-booted, fast path)

Create a pool of 2 pre-booted VMs:

```bash
kubectl apply -f 03-warmpool.yaml
# (or inline:)
kubectl apply -f - <<'EOF'
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxWarmPool
metadata:
  name: urunc-pool
  namespace: urunc-tutorial
spec:
  replicas: 2
  sandboxTemplateRef:
    name: urunc-fc
EOF
```

Watch the pool fill (readyReplicas reaches 2):

```bash
kubectl get sandboxwarmpool urunc-pool -n urunc-tutorial -w

# The two VMs are already running:
kubectl get pods -n urunc-tutorial
```

Claim from the pool — VM is already running, this is the fast path:

```bash
START_NS=$(date +%s%N)

kubectl apply -f - <<'EOF'
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: agent-fast-1
  namespace: urunc-tutorial
spec:
  sandboxTemplateRef:
    name: urunc-fc
EOF

until IP=$(kubectl get sandboxclaim agent-fast-1 -n urunc-tutorial \
  -o jsonpath='{.status.sandbox.podIPs[0]}' 2>/dev/null) && [ -n "$IP" ]; do true; done
until curl -sf --connect-timeout 1 --max-time 2 http://$IP:8080/health >/dev/null 2>&1; do true; done

echo "TTFR: $(( ($(date +%s%N) - START_NS) / 1000000 ))ms"
```

The pool replenishes automatically — a new VM boots in the background:

```bash
kubectl get sandboxwarmpool urunc-pool -n urunc-tutorial
# NAME         READY
# urunc-pool   1       ← rebuilding, back to 2 in a few seconds
```

Release the claim:

```bash
kubectl delete sandboxclaim agent-fast-1 -n urunc-tutorial
```

---

## Part 10 — Cleanup

```bash
kubectl delete sandboxclaim    --all -n urunc-tutorial
kubectl delete sandboxwarmpool --all -n urunc-tutorial
kubectl delete sandboxtemplate --all -n urunc-tutorial
kubectl delete namespace urunc-tutorial
```

---

## Reference: measured TTFR (n=10, this machine)

| Path | runc | gvisor | urunc-FC | urunc-QEMU | kata-qemu | kata-fc |
|---|---|---|---|---|---|---|
| Cold pod | 3085 ms | 3853 ms | **3121 ms** | 4051 ms | 5112 ms | 5289 ms |
| Cold SandboxClaim | 3237 ms | 4211 ms | **3310 ms** | 3467 ms | 5499 ms | 5380 ms |
| WarmPool claim | 1306 ms | 1485 ms | **1177 ms** | 1257 ms | 1406 ms | 1349 ms |

Metric: wall-clock from `kubectl apply` to first HTTP 200 on `/health`.
