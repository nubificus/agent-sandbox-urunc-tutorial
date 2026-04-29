#!/usr/bin/env bash
# bench-ttfr.sh — Time-to-first-response benchmark across all runtimes.
#
# Measures three scenarios per runtime:
#   cold  — plain pod creation to first HTTP /health response
#   sandbox — SandboxClaim (cold) to first HTTP /health response
#   warmpool — SandboxWarmPool claim to first HTTP /health response
#
# Runtimes: runc, gvisor, kata-qemu, kata-fc, urunc-qemu, urunc-fc
# Usage: sudo ./bench-ttfr.sh [trials] [scenario]
#   trials   — number of trials per runtime (default: 10)
#   scenario — cold|sandbox|warmpool|all (default: all)

set -euo pipefail

NAMESPACE=urunc-tutorial
TRIALS=${1:-10}
SCENARIO=${2:-all}
RESULTS_DIR="$(pwd)/results-ttfr-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR"

KUBECTL="sudo kubectl"
# devmapper runtimes (kata-fc, urunc-fc, urunc-qemu) run first while the system is freshly
# restarted — they share the devmapper pool and fail if run after other runtimes exhaust
# the pool's page-cache warmth. overlayfs runtimes (kata-qemu, gvisor, runc) run after.
RUNTIMES=(kata-fc urunc-fc urunc-qemu kata-qemu gvisor runc)

# Runtime → image map
declare -A RUNTIME_IMAGE=(
  [runc]="harbor.nbfc.io/nubificus/oci-executor:latest"
  [gvisor]="harbor.nbfc.io/nubificus/oci-executor:latest"
  [kata-qemu]="harbor.nbfc.io/nubificus/oci-executor:latest"
  [kata-fc]="harbor.nbfc.io/nubificus/oci-executor:latest"
  [urunc-qemu]="harbor.nbfc.io/nubificus/urunc-sandbox-qemu-minimal:latest"
  [urunc-fc]="harbor.nbfc.io/nubificus/urunc-sandbox-fc-minimal:latest"
)

# Runtime → runtimeClassName (empty = default runc)
declare -A RUNTIME_CLASS=(
  [runc]=""
  [gvisor]="gvisor"
  [kata-qemu]="kata-qemu"
  [kata-fc]="kata-fc"
  [urunc-qemu]="urunc"
  [urunc-fc]="urunc"
)

# VM runtimes need custom DNS to avoid issues inside VM
declare -A NEEDS_DNS=(
  [runc]="false" [gvisor]="false"
  [kata-qemu]="true" [kata-fc]="true"
  [urunc-qemu]="true" [urunc-fc]="true"
)

# Runtimes using devmapper snapshotter need extra settle time between trials:
# kata-fc/urunc-* use devmapper, and the thin-pool device cleanup is not
# instantaneous even after `kubectl delete --wait` returns.
declare -A INTER_TRIAL_SLEEP=(
  [runc]="0" [gvisor]="0" [kata-qemu]="0"
  [kata-fc]="20" [urunc-qemu]="15" [urunc-fc]="15"
)

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

# Wait until HTTP /health returns 200, return elapsed ms since $start_ns
wait_for_http() {
  local ip=$1 start_ns=$2
  while true; do
    if curl -sf --connect-timeout 1 --max-time 2 "http://${ip}:8080/health" >/dev/null 2>&1; then
      echo $(( ($(date +%s%N) - start_ns) / 1000000 ))
      return
    fi
    sleep 0.05
  done
}

# Get pod IP (poll until assigned, timeout seconds)
wait_for_pod_ip() {
  local pod_name=$1 timeout_s=${2:-300}
  local deadline=$(( $(date +%s) + timeout_s ))
  while true; do
    local ip
    ip=$($KUBECTL get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.podIP}' 2>/dev/null)
    [ -n "$ip" ] && echo "$ip" && return
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "ERROR: timed out (${timeout_s}s) waiting for IP of $pod_name"
      $KUBECTL describe pod "$pod_name" -n "$NAMESPACE" >&2 || true
      return 1
    fi
    sleep 0.1
  done
}

# Pre-warm a runtime by creating a pod, waiting for HTTP response, then deleting.
# Ensures the runtime binary is in page cache before we start measuring.
prewarm_runtime() {
  local runtime=$1
  local name="prewarm-${runtime}-$$"
  local image="${RUNTIME_IMAGE[$runtime]}"
  log "Pre-warming runtime ${runtime}..."
  pod_yaml "$name" "$runtime" "$image" | $KUBECTL apply -f - >/dev/null 2>&1 || { log "  prewarm apply failed, skipping"; return 0; }
  local ip
  ip=$(wait_for_pod_ip "$name" 360) || { $KUBECTL delete pod "$name" -n "$NAMESPACE" --force --grace-period=0 >/dev/null 2>&1 || true; return 0; }
  wait_for_http "$ip" "$(date +%s%N)" >/dev/null || true
  $KUBECTL delete pod "$name" -n "$NAMESPACE" --ignore-not-found --wait >/dev/null 2>&1 || true
  sleep 5
  log "  pre-warm done for ${runtime}"
}

pod_yaml() {
  local name=$1 runtime=$2 image=$3
  local rc_line=""
  [ -n "${RUNTIME_CLASS[$runtime]}" ] && rc_line="runtimeClassName: ${RUNTIME_CLASS[$runtime]}"
  local dns_lines=""
  if [ "${NEEDS_DNS[$runtime]}" = "true" ]; then
    dns_lines="  dnsPolicy: None
  dnsConfig:
    nameservers: [\"8.8.8.8\"]"
  fi
  cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
spec:
  ${rc_line}
  restartPolicy: Never
${dns_lines}
  containers:
  - name: executor
    image: ${image}
    ports:
    - containerPort: 8080
YAML
}

bench_cold() {
  local runtime=$1 trial=$2
  local name="bench-cold-${runtime}-${trial}"
  local image="${RUNTIME_IMAGE[$runtime]}"
  # Clean up any leftover pod from a previous run of this trial name
  $KUBECTL delete pod "$name" -n "$NAMESPACE" --ignore-not-found --wait >/dev/null 2>&1 || true

  local start_ns
  start_ns=$(date +%s%N)
  pod_yaml "$name" "$runtime" "$image" | $KUBECTL apply -f - >/dev/null 2>&1

  local ip
  ip=$(wait_for_pod_ip "$name")
  local ms
  ms=$(wait_for_http "$ip" "$start_ns")
  # Synchronous delete: wait for pod and its devmapper snapshot to be fully removed
  $KUBECTL delete pod "$name" -n "$NAMESPACE" --ignore-not-found --wait >/dev/null 2>&1 || true
  # Extra settle time for devmapper runtimes
  local settle="${INTER_TRIAL_SLEEP[$runtime]:-0}"
  [ "$settle" -gt 0 ] && sleep "$settle"
  echo "$ms"
}

bench_sandbox() {
  local runtime=$1 trial=$2
  local tmpl="bench-${runtime}"
  local claim_name="sc-${runtime}-${trial}"
  local sandbox_name=""

  $KUBECTL delete sandboxclaim "$claim_name" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  sleep 1

  local start_ns
  start_ns=$(date +%s%N)
  $KUBECTL apply -f - >/dev/null 2>&1 <<YAML
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: ${claim_name}
  namespace: ${NAMESPACE}
spec:
  sandboxTemplateRef:
    name: ${tmpl}
YAML

  # Wait for sandbox to get an IP (populated in status.sandbox.podIPs once pod is running)
  local ip=""
  while true; do
    ip=$($KUBECTL get sandboxclaim "$claim_name" -n "$NAMESPACE" \
      -o jsonpath='{.status.sandbox.podIPs[0]}' 2>/dev/null || true)
    [ -n "$ip" ] && break
    sleep 0.05
  done

  local ms
  ms=$(wait_for_http "$ip" "$start_ns")

  $KUBECTL delete sandboxclaim "$claim_name" -n "$NAMESPACE" --ignore-not-found --wait >/dev/null 2>&1 || true
  echo "$ms"
}

bench_warmpool() {
  local runtime=$1 trial=$2 pool_name=$3
  local claim_name="wpc-${runtime}-${trial}"

  # Delete previous claim to return the pre-booted pod to the pool
  local prev=$(( trial - 1 ))
  $KUBECTL delete sandboxclaim "wpc-${runtime}-${prev}" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true

  # Wait until warm pool has at least 1 ready slot
  log "  waiting for warmpool ${pool_name} readiness..."
  while true; do
    local ready
    ready=$($KUBECTL get sandboxwarmpool "$pool_name" -n "$NAMESPACE" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    [ "${ready:-0}" -ge 1 ] && break
    sleep 1
  done

  local start_ns
  start_ns=$(date +%s%N)
  $KUBECTL apply -f - >/dev/null 2>&1 <<YAML
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: ${claim_name}
  namespace: ${NAMESPACE}
spec:
  sandboxTemplateRef:
    name: bench-${runtime}
YAML

  local ip=""
  while true; do
    ip=$($KUBECTL get sandboxclaim "$claim_name" -n "$NAMESPACE" \
      -o jsonpath='{.status.sandbox.podIPs[0]}' 2>/dev/null || true)
    [ -n "$ip" ] && break
    sleep 0.05
  done

  local ms
  ms=$(wait_for_http "$ip" "$start_ns")
  echo "$ms"
}

ensure_warmpool() {
  local runtime=$1
  local pool_name="wp-${runtime}"
  local tmpl="bench-${runtime}"

  if ! $KUBECTL get sandboxwarmpool "$pool_name" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "Creating warmpool ${pool_name}..."
    $KUBECTL apply -f - >/dev/null 2>&1 <<YAML
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxWarmPool
metadata:
  name: ${pool_name}
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  sandboxTemplateRef:
    name: ${tmpl}
YAML
  fi

  # Wait for at least 1 ready
  log "Waiting for warmpool ${pool_name} to have 1 ready slot..."
  while true; do
    local ready
    ready=$($KUBECTL get sandboxwarmpool "$pool_name" -n "$NAMESPACE" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    [ "${ready:-0}" -ge 1 ] && break
    sleep 2
  done
  log "  warmpool ${pool_name} ready (readyReplicas=$(
    $KUBECTL get sandboxwarmpool "$pool_name" -n "$NAMESPACE" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null
  ))"
}

print_stats() {
  local label=$1; shift
  local -a arr=("$@")
  local n=${#arr[@]}
  if [ $n -eq 0 ]; then echo "$label: no data"; return; fi

  local sorted
  sorted=$(printf '%s\n' "${arr[@]}" | sort -n)
  local sum=0
  for v in "${arr[@]}"; do sum=$((sum + v)); done
  local mean=$((sum / n))
  local median
  median=$(echo "$sorted" | awk "NR==$(( (n+1)/2 )){print}")
  local min
  min=$(echo "$sorted" | head -1)
  local max
  max=$(echo "$sorted" | tail -1)

  printf "%-20s  median=%5dms  mean=%5dms  [%d-%d]  n=%d\n" \
    "$label" "$median" "$mean" "$min" "$max" "$n"
}

run_scenario() {
  local scenario=$1
  log "=== Scenario: $scenario  trials=$TRIALS ==="

  for runtime in "${RUNTIMES[@]}"; do
    local label="${scenario}/${runtime}"
    log "  Runtime: $runtime"
    local -a results=()

    # Pre-warm the runtime (binary page-cache warm-up), skip for devmapper runtimes
    # because the pre-warm pod's deletion can leave transient devmapper state that
    # interferes with the first trial.
    local settle="${INTER_TRIAL_SLEEP[$runtime]:-0}"
    if [ "$settle" -eq 0 ]; then
      prewarm_runtime "$runtime"
    else
      log "  Skipping pre-warm for $runtime (devmapper runtime, first trial may be slower)"
    fi

    case "$scenario" in
      cold)
        for i in $(seq 1 "$TRIALS"); do
          ms=$(bench_cold "$runtime" "$i")
          results+=("$ms")
          log "    trial $i: ${ms}ms"
        done
        ;;
      sandbox)
        for i in $(seq 1 "$TRIALS"); do
          ms=$(bench_sandbox "$runtime" "$i")
          results+=("$ms")
          log "    trial $i: ${ms}ms"
        done
        ;;
      warmpool)
        ensure_warmpool "$runtime"
        for i in $(seq 1 "$TRIALS"); do
          ms=$(bench_warmpool "$runtime" "$i" "wp-${runtime}")
          results+=("$ms")
          log "    trial $i: ${ms}ms"
        done
        # Clean up last claim
        $KUBECTL delete sandboxclaim "wpc-${runtime}-${TRIALS}" \
          -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
        ;;
    esac

    printf '%s\n' "${results[@]}" > "$RESULTS_DIR/${scenario}-${runtime}.txt"
    print_stats "$label" "${results[@]}"
  done
}

# Main
echo "Time-to-First-Response Benchmark"
echo "Namespace: $NAMESPACE | Trials: $TRIALS | Scenario: $SCENARIO"
echo "Results: $RESULTS_DIR"
echo

if [[ "$SCENARIO" == "all" || "$SCENARIO" == "cold"     ]]; then run_scenario cold;     fi
if [[ "$SCENARIO" == "all" || "$SCENARIO" == "sandbox"  ]]; then run_scenario sandbox;  fi
if [[ "$SCENARIO" == "all" || "$SCENARIO" == "warmpool" ]]; then run_scenario warmpool; fi

echo
echo "=== Summary ==="
for f in "$RESULTS_DIR"/*.txt; do
  label=$(basename "$f" .txt)
  mapfile -t arr < "$f"
  print_stats "$label" "${arr[@]}"
done
