# urunc + agent-sandbox tutorial

Run AI agent sandboxes inside KVM VMs on Kubernetes using
[urunc](https://github.com/urunc-dev/urunc) and
[agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox).

Each sandbox pod boots a dedicated Linux kernel — no shared memory or
filesystem with the host or other pods.

## Prerequisites

- Kubernetes 1.28+ with `containerd`
- A node with `/dev/kvm` accessible (bare-metal or nested-virt VM)
- `kubectl` access

## Install urunc

```bash
# RBAC for the installer DaemonSet
kubectl apply -f https://raw.githubusercontent.com/urunc-dev/urunc/main/deployment/urunc-deploy/urunc-rbac/urunc-rbac.yaml

# Deploy urunc shim to all nodes (k3s overlay — patches containerd config path)
kubectl kustomize https://github.com/urunc-dev/urunc/deployment/urunc-deploy/urunc-deploy/overlays/k3s | kubectl apply -f -
kubectl -n kube-system rollout status daemonset/urunc-deploy --timeout=5m

# Register the RuntimeClass
kubectl apply -f https://raw.githubusercontent.com/urunc-dev/urunc/main/deployment/urunc-deploy/runtimeclasses/runtimeclass.yaml
```

> **Note:** If using a custom firecracker binary (e.g. one with an MTU fix), copy it over after the DaemonSet finishes:
> ```bash
> sudo cp /path/to/firecracker /opt/urunc/bin/firecracker
> ```

## Install agent-sandbox

```bash
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.4.2/manifest.yaml
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.4.2/extensions.yaml
kubectl -n agent-sandbox-system rollout status deployment/agent-sandbox-controller --timeout=60s
```

## Create the tutorial namespace

```bash
kubectl create namespace urunc-tutorial
```

---

## Part 0: Verify urunc works

Boot a hello-world VM. `kubectl exec` does not work for urunc pods — use
`kubectl logs` instead.

```bash
kubectl apply -f 00-hello-pod.yaml
kubectl logs -n urunc-tutorial urunc-hello --follow
```

Expected output includes `Linux version`, `Hypervisor detected: KVM`, and
the hello banner. If you see the kernel boot lines, urunc is working.

```bash
kubectl delete -f 00-hello-pod.yaml
```

> **Note:** `dnsPolicy: None` with explicit nameservers is required for all
> urunc pods. Cluster DNS is not reachable from inside the VM.

---

## Part 1: Bare Sandbox

The controller creates a Pod and a Service, then sets `status.serviceFQDN`.

```bash
kubectl apply -f 01-sandbox.yaml
kubectl get sandbox hello-sandbox -n urunc-tutorial -w
```

Wait for `Ready=True`, then talk to the executor:

```bash
FQDN=hello-sandbox.urunc-tutorial.svc.cluster.local

curl http://${FQDN}:8080/health

curl -s -X POST http://${FQDN}:8080/execute \
  -H 'Content-Type: application/json' \
  -d '{"code": "import platform; print(platform.uname())", "language": "python"}'
```

The response includes `"kernel":"6.12.42"` and `"runtime":"urunc"` — the Go server running inside the VM.

```bash
kubectl delete -f 01-sandbox.yaml
```

---

## Part 2: SandboxTemplate + SandboxClaim

Separate the pod spec (template, set by a platform team) from individual
requests (claims, made by agents or users).

```bash
# Apply the template once
kubectl apply -f 02-template.yaml

# Claim a sandbox (repeat as needed)
kubectl apply -f 02-claim.yaml
kubectl wait sandboxclaim agent-beta -n urunc-tutorial \
  --for=condition=Ready --timeout=60s

# Get the service FQDN
kubectl get sandbox agent-beta -n urunc-tutorial \
  -o jsonpath='{.status.serviceFQDN}'
```

```bash
kubectl delete -f 02-claim.yaml
kubectl delete -f 02-template.yaml
```

---

## Part 3: SandboxWarmPool

Measured on a 4-core / 16 GB node, k3s + Calico, image pre-cached (n=7, median [min–max]).
urunc images use a minimal kernel: bzImage (7.9 MB) for QEMU, vmlinux (43 MB) for FC.
Sandbox cold start = time to pod container ready.

| Scenario | runc | urunc (QEMU) | urunc (FC) | kata-qemu | kata-fc |
|---|---|---|---|---|---|
| Plain Pod cold start | 2664 ms [2447–4277] | 3498 ms [2303–4362] | 2597 ms [2360–3661] | 4591 ms [4330–5667] | 4687 ms [3511–5969] |
| Sandbox cold start | 2598 ms [1588–3656] | 2624 ms [2469–3556] | 3435 ms [2514–5657] | 4733 ms [3645–5770] | 4680 ms [3628–6633] |
| WarmPool claim | 448 ms [389–509] | 456 ms [388–501] | 421 ms [352–574] | 522 ms [407–881] | 549 ms [431–676] |

**Sandbox cold start ≈ plain pod for all VM runtimes** — Service creation runs
concurrently with VM boot. urunc Firecracker is the fastest VM boot (2597 ms),
~900 ms ahead of urunc QEMU; Firecracker skips BIOS/PCI/ACPI emulation.
Kata adds ~2 s across both scenarios (kata-agent overhead). WarmPool claims
are runtime-independent (420–550 ms pure API overhead once pre-booted).

A warm pool pre-boots VMs so the first claim binds in ~370–510 ms (API
overhead only, VM already running). Size replicas to match your expected
concurrency — on a 4-core node, keep replicas ≤ 2 to avoid CPU contention
during concurrent VM boots.

```bash
# Re-apply the template if deleted above
kubectl apply -f 02-template.yaml

# Create a pool of 2 pre-booted VMs (adjust replicas to match node CPU count)
kubectl apply -f 03-warmpool.yaml

# Wait for all replicas to be ready
kubectl get pods -n urunc-tutorial -w
```

Claim against the pool — the VM is already running:

```bash
kubectl apply -f 03-claim-warm.yaml
kubectl wait sandboxclaim agent-beta -n urunc-tutorial \
  --for=condition=Ready --timeout=30s

kubectl get sandboxclaim agent-beta -n urunc-tutorial \
  -o jsonpath='{.status.sandbox.name}'
# Returns a pool member name (e.g. urunc-pool-abc12), not a fresh pod
```

The pool controller automatically replenishes consumed replicas.

### Measure cold start vs warm claim

**Cold:**

```bash
NAMESPACE=urunc-tutorial
kubectl -n $NAMESPACE delete sandbox bench 2>/dev/null || true
until ! kubectl -n $NAMESPACE get pod bench 2>/dev/null | grep -q bench; do sleep 1; done

START=$(date +%s%3N)
kubectl -n $NAMESPACE apply -f - <<EOF
apiVersion: agents.x-k8s.io/v1alpha1
kind: Sandbox
metadata:
  name: bench
  namespace: $NAMESPACE
spec:
  podTemplate:
    spec:
      runtimeClassName: urunc
      dnsPolicy: None
      dnsConfig:
        nameservers: ["8.8.8.8"]
      containers:
      - name: executor
        image: harbor.nbfc.io/nubificus/urunc-sandbox-go:latest
        ports:
        - containerPort: 8080
EOF
until kubectl -n $NAMESPACE get pod bench \
    -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null \
    | grep -q "true"; do sleep 0.2; done
END=$(date +%s%3N)
echo "Cold start: $(( END - START )) ms"
```

**Warm:**

```bash
NAMESPACE=urunc-tutorial
until kubectl -n $NAMESPACE get sandboxwarmpool urunc-pool \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "[1-9]"; do sleep 1; done

kubectl -n $NAMESPACE delete sandboxclaim timing-claim 2>/dev/null || true

START=$(date +%s%3N)
kubectl -n $NAMESPACE apply -f - <<EOF
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: timing-claim
  namespace: $NAMESPACE
spec:
  sandboxTemplateRef:
    name: urunc-go
  warmpool: default
EOF
until kubectl -n $NAMESPACE get sandboxclaim timing-claim \
    -o jsonpath='{.status.conditions[0].status}' 2>/dev/null \
    | grep -q "True"; do sleep 0.1; done
END=$(date +%s%3N)
echo "Warm claim: $(( END - START )) ms"
kubectl -n $NAMESPACE delete sandboxclaim timing-claim
```

---

## Cleanup

```bash
kubectl delete sandboxclaim agent-beta -n urunc-tutorial 2>/dev/null || true
kubectl delete -f 03-warmpool.yaml 2>/dev/null || true
kubectl delete -f 02-template.yaml 2>/dev/null || true
kubectl delete namespace urunc-tutorial
```

---

## Known constraints

| Constraint | Detail |
|---|---|
| No `kubectl exec` | VM kernel has no exec channel back to containerd; use HTTP or `kubectl logs` |
| `dnsPolicy: None` required | Cluster DNS bind-mount is not visible inside the VM |
| No projected volumes | Service account tokens are injected after the virtiofs snapshot; pass credentials via env vars |
| Firecracker needs devmapper | QEMU works with default overlayfs; FC requires the devmapper snapshotter |
| Images must be Bunny-built | Arbitrary OCI images silently fall back to runc |

## References

- [urunc](https://github.com/urunc-dev/urunc)
- [agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox)
- [Bunny image builder](https://github.com/nubificus/bunny)
- [urunc-agent-sandbox-examples](https://github.com/nubificus/urunc-agent-sandbox-examples)
- [Blog post: Secure AI Agent Sandboxes on Kubernetes](https://nubificus.co.uk/blog/urunc-agent-sandbox-k8s)
