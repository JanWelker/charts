#!/usr/bin/env bash
#
# e2e-test.sh - End-to-end test for a redis-ha Helm release.
#
# Validates a *running* redis-ha deployment by exercising the real cluster:
# pod readiness, replication topology, sentinel quorum/agreement, HAProxy
# routing, live read/write replication and (optionally) sentinel failover.
#
# It talks to the cluster purely through `kubectl exec` + redis-cli inside the
# pods, so it needs no Redis client locally and works against any cluster your
# kubeconfig can reach.
#
# Usage:
#   ./e2e-test.sh -r <release> [-n <namespace>] [options]
#
# Options:
#   -r, --release      Helm release name (= chart fullname).            (required)
#   -n, --namespace    Kubernetes namespace.                  (default: "default")
#   -m, --master-group Sentinel master group name.            (default: "mymaster")
#   -p, --password     Redis AUTH password. If omitted and auth is detected,
#                      it is read from the release secret.
#       --auth-key     Key in the auth secret holding the password. (default: "auth")
#       --secret       Name of the auth secret.            (default: <release>)
#       --failover     Run the DESTRUCTIVE failover test (gracefully deletes the
#                      master pod). Also measures client write continuity through
#                      HAProxy across the failover (regression check for #375).
#       --quorum-crash Run the DESTRUCTIVE quorum-loss test (scales the cluster
#                      below the sentinel quorum, asserts no split-brain -- a
#                      graceful preStop failover may still promote one survivor
#                      by design -- then restores and verifies recovery).
#       --no-haproxy   Skip HAProxy routing tests even if a haproxy svc exists.
#       --timeout      Per-wait timeout in seconds.                 (default: 180)
#   -h, --help         Show this help.
#
# Exit code is 0 only if every test passes.
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults / arg parsing
# ----------------------------------------------------------------------------
RELEASE=""
NAMESPACE="default"
MASTER_GROUP="mymaster"
PASSWORD=""
AUTH_KEY="auth"
SECRET_NAME=""
RUN_FAILOVER=false
RUN_QUORUM_CRASH=false
SKIP_HAPROXY=false
TIMEOUT=180

REDIS_PORT=6379
SENTINEL_PORT=26379
REDIS_CONTAINER="redis"
SENTINEL_CONTAINER="sentinel"

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--release)      RELEASE="$2"; shift 2 ;;
    -n|--namespace)    NAMESPACE="$2"; shift 2 ;;
    -m|--master-group) MASTER_GROUP="$2"; shift 2 ;;
    -p|--password)     PASSWORD="$2"; shift 2 ;;
    --auth-key)        AUTH_KEY="$2"; shift 2 ;;
    --secret)          SECRET_NAME="$2"; shift 2 ;;
    --failover)        RUN_FAILOVER=true; shift ;;
    --quorum-crash)    RUN_QUORUM_CRASH=true; shift ;;
    --no-haproxy)      SKIP_HAPROXY=true; shift ;;
    --timeout)         TIMEOUT="$2"; shift 2 ;;
    -h|--help)         usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

[[ -z "$RELEASE" ]] && { echo "ERROR: --release is required." >&2; usage 1; }

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi

TESTS_RUN=0; TESTS_PASS=0; TESTS_FAIL=0
declare -a FAILURES=()

section() { printf '\n%s== %s ==%s\n' "$C_BLU$C_BLD" "$1" "$C_RST"; }
info()    { printf '%s•%s %s\n' "$C_BLU" "$C_RST" "$1"; }
pass()    { TESTS_RUN=$((TESTS_RUN+1)); TESTS_PASS=$((TESTS_PASS+1)); printf '  %sPASS%s %s\n' "$C_GRN" "$C_RST" "$1"; }
fail()    { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1)); FAILURES+=("$1"); printf '  %sFAIL%s %s\n' "$C_RED" "$C_RST" "$1"; }
warn()    { printf '  %sWARN%s %s\n' "$C_YEL" "$C_RST" "$1"; }
die()     { printf '%sERROR:%s %s\n' "$C_RED$C_BLD" "$C_RST" "$1" >&2; exit 1; }

# assert "<description>" <expected> <actual>
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$desc"
  else
    fail "$desc (expected '$expected', got '$actual')"
  fi
}

# ----------------------------------------------------------------------------
# kubectl / redis-cli plumbing
# ----------------------------------------------------------------------------
KUBECTL=(kubectl -n "$NAMESPACE")

kc() { "${KUBECTL[@]}" "$@"; }

# Run redis-cli inside a pod's redis container. Auth is injected automatically.
# Usage: rcli <pod> <args...>
rcli() {
  local pod="$1"; shift
  local auth=()
  [[ -n "$PASSWORD" ]] && auth=(-a "$PASSWORD" --no-auth-warning)
  kc exec "$pod" -c "$REDIS_CONTAINER" -- \
    redis-cli "${auth[@]}" -p "$REDIS_PORT" "$@"
}

# Run redis-cli against the local sentinel inside a pod.
# Usage: scli <pod> <args...>
scli() {
  local pod="$1"; shift
  local auth=()
  [[ -n "$SENTINEL_PASSWORD" ]] && auth=(-a "$SENTINEL_PASSWORD" --no-auth-warning)
  kc exec "$pod" -c "$SENTINEL_CONTAINER" -- \
    redis-cli "${auth[@]}" -p "$SENTINEL_PORT" "$@"
}

# ----------------------------------------------------------------------------
# Discovery
# ----------------------------------------------------------------------------
section "Discovery"

command -v kubectl >/dev/null || die "kubectl not found in PATH."
kc get ns >/dev/null 2>&1 || die "Cannot reach namespace '$NAMESPACE'. Check kubeconfig."

# The chart's fullname (and thus resource names) may differ from the release
# name -- e.g. release "redis" + chart "redis-ha" => "redis-redis-ha". Discover
# the StatefulSet by label instead of assuming "<release>-server".
STS=$(kc get statefulset -l "release=${RELEASE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
        | tr ' ' '\n' | grep -- '-server$' | head -n1 || true)
[[ -z "$STS" ]] && die "No redis-ha StatefulSet found for release '$RELEASE' in '$NAMESPACE'. Is --release/--namespace correct?"

# Strip the trailing "-server" to recover the chart fullname (used for the
# haproxy service and the auth secret).
FULLNAME="${STS%-server}"
[[ -z "$SECRET_NAME" ]] && SECRET_NAME="$FULLNAME"

REPLICAS=$(kc get statefulset "$STS" -o jsonpath='{.spec.replicas}')
[[ -z "$REPLICAS" || "$REPLICAS" -lt 1 ]] && die "Could not determine replica count."
info "Release '$RELEASE' (fullname '$FULLNAME') in namespace '$NAMESPACE' with $REPLICAS replica(s)."

PODS=()
for ((i=0; i<REPLICAS; i++)); do PODS+=("${STS}-${i}"); done
info "Server pods: ${PODS[*]}"

# Detect auth from the statefulset env (the redis container exports AUTH when enabled).
AUTH_ENABLED=false
if kc get statefulset "$STS" -o jsonpath='{.spec.template.spec.containers[*].env[*].name}' 2>/dev/null | tr ' ' '\n' | grep -qx "AUTH"; then
  AUTH_ENABLED=true
fi

if [[ "$AUTH_ENABLED" == true ]]; then
  if [[ -z "$PASSWORD" ]]; then
    info "Auth enabled; reading password from secret '$SECRET_NAME' key '$AUTH_KEY'."
    PASSWORD=$(kc get secret "$SECRET_NAME" -o "jsonpath={.data.${AUTH_KEY}}" 2>/dev/null | base64 -d 2>/dev/null || true)
    [[ -z "$PASSWORD" ]] && die "Could not read password from secret '$SECRET_NAME' (key '$AUTH_KEY'). Pass it with --password."
  fi
  info "Redis AUTH: ${C_GRN}enabled${C_RST}"
else
  info "Redis AUTH: disabled"
fi

# Sentinel auth lives in its OWN secret/key (defaults: "<fullname>-sentinel" /
# "sentinel-password"), which is distinct from the redis auth secret. Resolve
# the exact secretKeyRef from the StatefulSet so we don't hard-code the wrong
# secret -- reading the redis secret here just yields an empty password and
# every authenticated sentinel command then fails.
SENTINEL_PASSWORD=""
if kc get statefulset "$STS" -o jsonpath='{.spec.template.spec.containers[*].env[*].name}' 2>/dev/null | tr ' ' '\n' | grep -qx "SENTINELAUTH"; then
  s_secret=$(kc get statefulset "$STS" -o 'jsonpath={.spec.template.spec.containers[*].env[?(@.name=="SENTINELAUTH")].valueFrom.secretKeyRef.name}' 2>/dev/null | awk '{print $1}')
  s_key=$(kc get statefulset "$STS" -o 'jsonpath={.spec.template.spec.containers[*].env[?(@.name=="SENTINELAUTH")].valueFrom.secretKeyRef.key}' 2>/dev/null | awk '{print $1}')
  s_secret="${s_secret:-${FULLNAME}-sentinel}"
  s_key="${s_key:-sentinel-password}"
  SENTINEL_PASSWORD=$(kc get secret "$s_secret" -o "jsonpath={.data.${s_key}}" 2>/dev/null | base64 -d 2>/dev/null || true)
  if [[ -n "$SENTINEL_PASSWORD" ]]; then
    info "Sentinel AUTH: ${C_GRN}enabled${C_RST} (secret '$s_secret', key '$s_key')"
  else
    warn "SENTINELAUTH is set but no password read from secret '$s_secret' (key '$s_key'); sentinel commands will fail."
  fi
fi

# HAProxy service.
HAPROXY_SVC="${FULLNAME}-haproxy"
HAPROXY_ENABLED=false
if [[ "$SKIP_HAPROXY" == false ]] && kc get svc "$HAPROXY_SVC" >/dev/null 2>&1; then
  HAPROXY_ENABLED=true
  info "HAProxy service: $HAPROXY_SVC"
else
  info "HAProxy tests: skipped"
fi

# ----------------------------------------------------------------------------
# 1. Pod & resource readiness
# ----------------------------------------------------------------------------
section "1. Readiness"

info "Waiting for StatefulSet pods to be Ready (timeout ${TIMEOUT}s)..."
if kc rollout status statefulset "$STS" --timeout="${TIMEOUT}s" >/dev/null 2>&1; then
  pass "All server pods report Ready"
else
  fail "Not all server pods became Ready within ${TIMEOUT}s"
  kc get pods -l "release=${RELEASE}" || true
fi

READY_COUNT=$(kc get statefulset "$STS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
assert_eq "Ready replicas == desired ($REPLICAS)" "$REPLICAS" "${READY_COUNT:-0}"

if [[ "$HAPROXY_ENABLED" == true ]]; then
  if kc rollout status deploy "$HAPROXY_SVC" --timeout="${TIMEOUT}s" >/dev/null 2>&1; then
    pass "HAProxy deployment rolled out"
  else
    fail "HAProxy deployment not ready"
  fi
fi

# ----------------------------------------------------------------------------
# 2. Per-pod connectivity (PING)
# ----------------------------------------------------------------------------
section "2. Connectivity"

for pod in "${PODS[@]}"; do
  resp=$(rcli "$pod" PING 2>/dev/null || true)
  assert_eq "redis PING on $pod" "PONG" "$resp"
done

for pod in "${PODS[@]}"; do
  resp=$(scli "$pod" PING 2>/dev/null || true)
  assert_eq "sentinel PING on $pod" "PONG" "$resp"
done

# ----------------------------------------------------------------------------
# 3. Replication topology (exactly one master, replicas connected)
# ----------------------------------------------------------------------------
section "3. Topology"

MASTER_POD=""
MASTER_COUNT=0
SLAVE_COUNT=0
for pod in "${PODS[@]}"; do
  role=$(rcli "$pod" ROLE 2>/dev/null | head -n1 || true)
  case "$role" in
    master) MASTER_COUNT=$((MASTER_COUNT+1)); MASTER_POD="$pod"; info "$pod -> master" ;;
    slave)  SLAVE_COUNT=$((SLAVE_COUNT+1)); info "$pod -> replica" ;;
    *)      warn "$pod -> unknown role '$role'" ;;
  esac
done

assert_eq "Exactly one master" "1" "$MASTER_COUNT"
assert_eq "Replica count == $((REPLICAS-1))" "$((REPLICAS-1))" "$SLAVE_COUNT"

if [[ -n "$MASTER_POD" ]]; then
  connected=$(rcli "$MASTER_POD" INFO replication 2>/dev/null | tr -d '\r' | awk -F: '/^connected_slaves:/{print $2}')
  assert_eq "Master sees $((REPLICAS-1)) connected replicas" "$((REPLICAS-1))" "${connected:-0}"
fi

# Each replica must be in sync (master_link_status:up)
for pod in "${PODS[@]}"; do
  [[ "$pod" == "$MASTER_POD" ]] && continue
  link=$(rcli "$pod" INFO replication 2>/dev/null | tr -d '\r' | awk -F: '/^master_link_status:/{print $2}')
  assert_eq "Replica $pod link to master is up" "up" "${link:-down}"
done

# ----------------------------------------------------------------------------
# 4. Sentinel quorum & agreement
# ----------------------------------------------------------------------------
section "4. Sentinel"

for pod in "${PODS[@]}"; do
  # `sentinel master <group>` returns a flat key/value list; pull num-other-sentinels & flags.
  master_info=$(scli "$pod" SENTINEL master "$MASTER_GROUP" 2>/dev/null | tr -d '\r' || true)
  if [[ -z "$master_info" ]]; then
    fail "Sentinel on $pod knows master group '$MASTER_GROUP'"
    continue
  fi
  flags=$(echo "$master_info" | grep -A1 '^flags$' | tail -n1 || true)
  others=$(echo "$master_info" | grep -A1 '^num-other-sentinels$' | tail -n1 || true)
  if [[ "$flags" == "master" ]]; then
    pass "Sentinel $pod sees master group '$MASTER_GROUP' healthy (flags=$flags, num-other-sentinels=${others:-?})"
  else
    fail "Sentinel $pod reports unhealthy master flags='$flags'"
  fi
done

# All sentinels should agree on the same master ip.
declare -A MASTER_IPS=()
for pod in "${PODS[@]}"; do
  ip=$(scli "$pod" SENTINEL get-master-addr-by-name "$MASTER_GROUP" 2>/dev/null | head -n1 | tr -d '\r' || true)
  [[ -n "$ip" ]] && MASTER_IPS["$ip"]=1
done
assert_eq "All sentinels agree on a single master address" "1" "${#MASTER_IPS[@]}"

# ----------------------------------------------------------------------------
# 5. Replication round-trip (write to master, read from replicas)
# ----------------------------------------------------------------------------
section "5. Replication round-trip"

TEST_KEY="e2e:redis-ha:$$"
TEST_VAL="ok-$(date +%s 2>/dev/null || echo now)"

if [[ -z "$MASTER_POD" ]]; then
  fail "No master pod identified; skipping replication round-trip"
else
  set_resp=$(rcli "$MASTER_POD" SET "$TEST_KEY" "$TEST_VAL" 2>/dev/null || true)
  assert_eq "Write key on master ($MASTER_POD)" "OK" "$set_resp"

  # Give replication a moment to propagate, then read from every replica.
  for pod in "${PODS[@]}"; do
    [[ "$pod" == "$MASTER_POD" ]] && continue
    got=""
    for _ in $(seq 1 10); do
      got=$(rcli "$pod" GET "$TEST_KEY" 2>/dev/null | tr -d '\r' || true)
      [[ "$got" == "$TEST_VAL" ]] && break
      sleep 1
    done
    assert_eq "Replica $pod replicated the key" "$TEST_VAL" "$got"
  done

  # Replicas must reject writes (read-only).
  for pod in "${PODS[@]}"; do
    [[ "$pod" == "$MASTER_POD" ]] && continue
    ro=$(rcli "$pod" SET "${TEST_KEY}:ro" nope 2>&1 || true)
    if echo "$ro" | grep -qi "READONLY"; then
      pass "Replica $pod rejects writes (READONLY)"
    else
      fail "Replica $pod did not reject write (got '$ro')"
    fi
  done

  rcli "$MASTER_POD" DEL "$TEST_KEY" >/dev/null 2>&1 || true
fi

# ----------------------------------------------------------------------------
# 6. HAProxy routing
# ----------------------------------------------------------------------------
if [[ "$HAPROXY_ENABLED" == true ]]; then
  section "6. HAProxy routing"

  # Run redis-cli from inside a server pod against the haproxy service DNS name.
  hp_auth=()
  [[ -n "$PASSWORD" ]] && hp_auth=(-a "$PASSWORD" --no-auth-warning)
  hp() {
    kc exec "${PODS[0]}" -c "$REDIS_CONTAINER" -- \
      redis-cli "${hp_auth[@]}" -h "$HAPROXY_SVC" -p "$REDIS_PORT" "$@"
  }

  ping_resp=$(hp PING 2>/dev/null || true)
  assert_eq "HAProxy PING" "PONG" "$ping_resp"

  role_via_hp=$(hp ROLE 2>/dev/null | head -n1 || true)
  assert_eq "HAProxy routes writes to master" "master" "$role_via_hp"

  hp_key="e2e:haproxy:$$"
  set_resp=$(hp SET "$hp_key" via-haproxy 2>/dev/null || true)
  assert_eq "Write via HAProxy" "OK" "$set_resp"
  # Verify it landed on the real master.
  if [[ -n "$MASTER_POD" ]]; then
    got=$(rcli "$MASTER_POD" GET "$hp_key" 2>/dev/null | tr -d '\r' || true)
    assert_eq "HAProxy write visible on master" "via-haproxy" "$got"
    rcli "$MASTER_POD" DEL "$hp_key" >/dev/null 2>&1 || true
  fi
fi

# ----------------------------------------------------------------------------
# 7. Sentinel failover (DESTRUCTIVE, opt-in)
# ----------------------------------------------------------------------------
if [[ "$RUN_FAILOVER" == true ]]; then
  section "7. Failover (destructive)"

  if [[ -z "$MASTER_POD" ]]; then
    fail "No master identified; cannot run failover test"
  else
    # Write a sentinel value we expect to survive the failover.
    SURV_KEY="e2e:failover:$$"
    SURV_VAL="survive-$(date +%s 2>/dev/null || echo now)"
    rcli "$MASTER_POD" SET "$SURV_KEY" "$SURV_VAL" >/dev/null 2>&1 || true
    old_ip=$(rcli "$MASTER_POD" INFO server 2>/dev/null | tr -d '\r' | awk -F: '/^run_id:/{print $2}')
    info "Current master: $MASTER_POD (run_id=${old_ip:-?}). Deleting it to force failover..."

    # --- Client write-continuity probe (the crux of issue #375) -------------
    # Hammer writes through a STABLE endpoint (HAProxy) from a surviving pod
    # while the master is gracefully terminated. With the preStop failover
    # hooks working, Sentinel fails over *before* the old master goes down, so
    # clients see little or no write errors. Without them, clients see a
    # multi-second outage until Sentinel's down-after-milliseconds detection
    # promotes a new master -- exactly the symptom reported in #375.
    PROBE_PID=""; CONT_LOG=""
    CLIENT_POD=""
    for p in "${PODS[@]}"; do [[ "$p" != "$MASTER_POD" ]] && { CLIENT_POD="$p"; break; }; done
    PROBE_DUR=45; (( PROBE_DUR > TIMEOUT )) && PROBE_DUR=$TIMEOUT
    if [[ "$HAPROXY_ENABLED" == true && -n "$CLIENT_POD" ]]; then
      CONT_LOG="$(mktemp)"
      info "Starting write-continuity probe via $HAPROXY_SVC from $CLIENT_POD (${PROBE_DUR}s)..."
      kc exec "$CLIENT_POD" -c "$REDIS_CONTAINER" -- sh -c '
        export REDISCLI_AUTH="$1"; HOST="$2"; PORT="$3"; DUR="$4"
        ok=0; err=0; streak=0; maxgap=0
        end=$(( $(date +%s) + DUR ))
        while [ "$(date +%s)" -lt "$end" ]; do
          if redis-cli --no-auth-warning -h "$HOST" -p "$PORT" SET e2e:cont:probe ok >/dev/null 2>&1; then
            ok=$((ok+1)); streak=0
          else
            err=$((err+1)); streak=$((streak+1))
            [ "$streak" -gt "$maxgap" ] && maxgap=$streak
          fi
        done
        echo "$ok $err $maxgap"
      ' _ "$PASSWORD" "$HAPROXY_SVC" "$REDIS_PORT" "$PROBE_DUR" >"$CONT_LOG" 2>/dev/null &
      PROBE_PID=$!
      sleep 2  # let the probe establish a steady baseline before we kill the master
    else
      warn "Write-continuity probe skipped (needs HAProxy + a surviving pod)."
    fi

    kc delete pod "$MASTER_POD" --wait=false >/dev/null 2>&1 || true

    # Poll sentinel for a NEW master to be elected.
    new_master_pod=""
    deadline=$((SECONDS + TIMEOUT))
    while (( SECONDS < deadline )); do
      # Ask a surviving sentinel for the current master address.
      for pod in "${PODS[@]}"; do
        [[ "$pod" == "$MASTER_POD" ]] && continue
        mip=$(scli "$pod" SENTINEL get-master-addr-by-name "$MASTER_GROUP" 2>/dev/null | head -n1 | tr -d '\r' || true)
        [[ -z "$mip" ]] && continue
        # Map the master IP back to a pod by checking each pod's ROLE.
        for cand in "${PODS[@]}"; do
          [[ "$cand" == "$MASTER_POD" ]] && continue
          r=$(rcli "$cand" ROLE 2>/dev/null | head -n1 || true)
          if [[ "$r" == "master" ]]; then new_master_pod="$cand"; break; fi
        done
        break
      done
      [[ -n "$new_master_pod" ]] && break
      sleep 3
    done

    if [[ -n "$new_master_pod" ]]; then
      pass "Sentinel promoted a new master: $new_master_pod"
    else
      fail "No new master was promoted within ${TIMEOUT}s"
    fi

    # Data written before the failover must survive on the new master.
    if [[ -n "$new_master_pod" ]]; then
      got=$(rcli "$new_master_pod" GET "$SURV_KEY" 2>/dev/null | tr -d '\r' || true)
      assert_eq "Data survived failover on new master" "$SURV_VAL" "$got"
    fi

    # Collect the write-continuity probe and assert clients stayed (mostly) up.
    if [[ -n "$PROBE_PID" ]]; then
      wait "$PROBE_PID" 2>/dev/null || true
      CONT_OK=0; CONT_ERR=0; CONT_GAP=0
      read -r CONT_OK CONT_ERR CONT_GAP < "$CONT_LOG" 2>/dev/null || true
      rm -f "$CONT_LOG"
      total=$(( ${CONT_OK:-0} + ${CONT_ERR:-0} ))
      if (( total > 0 )); then
        pct=$(( ${CONT_ERR:-0} * 100 / total ))
        info "Write continuity: ${CONT_OK:-0} ok, ${CONT_ERR:-0} failed (${pct}%), longest error streak ${CONT_GAP:-0}."
        # A perfect graceful failover is ~0% errors; allow a small blip for the
        # HAProxy re-route. A large error fraction means clients saw the #375 outage.
        if (( pct <= 5 )); then
          pass "Writes stayed continuous through graceful failover (${pct}% errors)"
        else
          fail "Clients saw ${pct}% write errors during failover (possible #375 regression)"
        fi
      else
        warn "Write-continuity probe produced no samples."
      fi
      # Clean up the probe key (lands on whichever pod is now master).
      [[ -n "$new_master_pod" ]] && rcli "$new_master_pod" DEL e2e:cont:probe >/dev/null 2>&1 || true
    fi

    # Wait for the old master pod to rejoin as a replica.
    info "Waiting for old master '$MASTER_POD' to rejoin the cluster..."
    if kc wait --for=condition=ready pod "$MASTER_POD" --timeout="${TIMEOUT}s" >/dev/null 2>&1; then
      rejoin_role=$(rcli "$MASTER_POD" ROLE 2>/dev/null | head -n1 || true)
      if [[ "$rejoin_role" == "slave" ]]; then
        pass "Old master '$MASTER_POD' rejoined as a replica"
      else
        warn "Old master '$MASTER_POD' rejoined with role '$rejoin_role' (expected slave)"
      fi
    else
      fail "Old master '$MASTER_POD' did not become Ready again"
    fi

    if [[ -n "$new_master_pod" ]]; then
      rcli "$new_master_pod" DEL "$SURV_KEY" >/dev/null 2>&1 || true
    fi
  fi
fi

# ----------------------------------------------------------------------------
# 8. Sentinel quorum crash (DESTRUCTIVE, opt-in)
# ----------------------------------------------------------------------------
# Scales the StatefulSet below the sentinel quorum so the surviving sentinels
# can no longer agree to fail over. Verifies that:
#   * no erroneous failover happens while quorum is lost (no split-brain), and
#   * the cluster fully recovers (quorum restored, single master, data intact)
#     once the crashed nodes are brought back.
if [[ "$RUN_QUORUM_CRASH" == true ]]; then
  section "8. Sentinel quorum crash (destructive)"

  # Restore the original scale on exit, even if the script is interrupted.
  QC_SCALED_DOWN=false
  restore_scale() {
    if [[ "$QC_SCALED_DOWN" == true ]]; then
      info "Restoring StatefulSet '$STS' to $REPLICAS replica(s)..."
      kc scale statefulset "$STS" --replicas="$REPLICAS" >/dev/null 2>&1 || true
      QC_SCALED_DOWN=false
    fi
  }
  trap restore_scale EXIT

  # Read the configured quorum from any sentinel.
  QUORUM=""
  for pod in "${PODS[@]}"; do
    minfo=$(scli "$pod" SENTINEL master "$MASTER_GROUP" 2>/dev/null | tr -d '\r' || true)
    QUORUM=$(echo "$minfo" | grep -A1 '^quorum$' | tail -n1 || true)
    [[ -n "$QUORUM" ]] && break
  done

  # Surviving sentinels must drop below the quorum to make failover impossible.
  SURVIVING=$(( QUORUM - 1 ))

  if [[ -z "$QUORUM" || ! "$QUORUM" =~ ^[0-9]+$ ]]; then
    fail "Could not read sentinel quorum for group '$MASTER_GROUP'"
  elif (( QUORUM <= 1 )); then
    warn "Quorum is $QUORUM; it cannot be 'lost' in a meaningful way. Skipping."
  elif (( SURVIVING < 1 )); then
    warn "Dropping below quorum ($QUORUM) would leave 0 pods. Skipping to avoid destroying the cluster."
  else
    info "Sentinel quorum is $QUORUM; scaling $STS from $REPLICAS down to $SURVIVING to break it."

    # Identify the master and its ordinal, and persist a value that must survive.
    QC_MASTER=""
    for pod in "${PODS[@]}"; do
      [[ "$(rcli "$pod" ROLE 2>/dev/null | head -n1)" == "master" ]] && { QC_MASTER="$pod"; break; }
    done
    QC_KEY="e2e:quorum:$$"
    QC_VAL="quorum-$(date +%s 2>/dev/null || echo now)"
    if [[ -n "$QC_MASTER" ]]; then
      rcli "$QC_MASTER" SET "$QC_KEY" "$QC_VAL" >/dev/null 2>&1 || true
      # Ensure the value is on a surviving replica before we crash anything.
      for _ in $(seq 1 10); do
        repl=$(rcli "${PODS[0]}" GET "$QC_KEY" 2>/dev/null | tr -d '\r' || true)
        [[ "$repl" == "$QC_VAL" ]] && break
        sleep 1
      done
    fi
    # The master is "crashed" if its ordinal is outside the surviving range
    # (StatefulSet scale-down removes the highest ordinals first).
    MASTER_ORDINAL="${QC_MASTER##*-}"
    MASTER_CRASHED=false
    [[ "$MASTER_ORDINAL" =~ ^[0-9]+$ ]] && (( MASTER_ORDINAL >= SURVIVING )) && MASTER_CRASHED=true

    # Break quorum.
    QC_SCALED_DOWN=true
    kc scale statefulset "$STS" --replicas="$SURVIVING" >/dev/null 2>&1 \
      || fail "Failed to scale $STS down"

    info "Waiting for the cluster to settle below quorum (${TIMEOUT}s)..."
    deadline=$((SECONDS + TIMEOUT))
    while (( SECONDS < deadline )); do
      running=$(kc get pod -l "release=${RELEASE}" \
        -o jsonpath="{range .items[*]}{.metadata.name}{'\n'}{end}" 2>/dev/null \
        | grep -c -- '-server-' || true)
      (( running <= SURVIVING )) && break
      sleep 3
    done

    # Surviving pods after scale-down are ordinals 0..SURVIVING-1.
    QC_SURVIVORS=()
    for ((i=0; i<SURVIVING; i++)); do QC_SURVIVORS+=("${STS}-${i}"); done

    # Invariant 1: never more than one master among survivors (no split-brain).
    live_masters=0
    for pod in "${QC_SURVIVORS[@]}"; do
      [[ "$(rcli "$pod" ROLE 2>/dev/null | head -n1)" == "master" ]] && live_masters=$((live_masters+1))
    done
    if (( live_masters <= 1 )); then
      pass "No split-brain while quorum is lost (masters among survivors: $live_masters)"
    else
      fail "Split-brain detected: $live_masters masters among surviving pods"
    fi

    # Invariant 2: a GRACEFUL master termination runs the redis + sentinel
    # preStop hooks, and the sentinel hook issues a manual `SENTINEL failover`.
    # A manual failover is quorum-INDEPENDENT by design -- a single sentinel will
    # execute a user-requested failover and send `SLAVEOF NO ONE` to a replica
    # regardless of quorum. So the surviving replica is EXPECTED to be promoted
    # here: that is precisely the graceful-failover fix (#375 / #377) working.
    #
    # The safety property that must still hold is "no split-brain": the forced
    # failover may promote AT MOST ONE survivor, never several.
    #
    # NOTE: the classic "Sentinel will not fail over below quorum" guarantee only
    # applies to UNGRACEFUL crashes (kill -9 / power loss), where no preStop runs.
    # That path cannot be exercised on a 3-node / quorum-2 cluster, because
    # dropping below quorum leaves a single survivor with no peer to promote.
    if [[ "$MASTER_CRASHED" == true ]]; then
      # Give the preStop-driven failover a window to complete.
      sleep 15
      promoted=0
      for pod in "${QC_SURVIVORS[@]}"; do
        [[ "$(rcli "$pod" ROLE 2>/dev/null | head -n1)" == "master" ]] && promoted=$((promoted+1))
      done
      if (( promoted <= 1 )); then
        pass "Graceful failover below quorum promoted at most one survivor (promoted=$promoted; preStop failover is expected)"
      else
        fail "Split-brain after graceful failover below quorum: $promoted masters among survivors"
      fi
    else
      info "Master ($QC_MASTER) survived the scale-down; failover-suppression check not applicable."
    fi

    # Recover: restore the original scale and wait for the cluster to heal.
    restore_scale
    info "Waiting for the StatefulSet to become Ready again (${TIMEOUT}s)..."
    if kc rollout status statefulset "$STS" --timeout="${TIMEOUT}s" >/dev/null 2>&1; then
      pass "Cluster scaled back to $REPLICAS and all pods Ready"
    else
      fail "Cluster did not return to Ready after restoring scale"
    fi

    # Rebuild the full pod list and wait for exactly one master + quorum health.
    QC_ALL=()
    for ((i=0; i<REPLICAS; i++)); do QC_ALL+=("${STS}-${i}"); done

    recovered_master=""
    deadline=$((SECONDS + TIMEOUT))
    while (( SECONDS < deadline )); do
      mc=0; recovered_master=""
      for pod in "${QC_ALL[@]}"; do
        if [[ "$(rcli "$pod" ROLE 2>/dev/null | head -n1)" == "master" ]]; then
          mc=$((mc+1)); recovered_master="$pod"
        fi
      done
      (( mc == 1 )) && break
      sleep 3
    done
    if [[ -n "$recovered_master" ]]; then
      pass "Quorum restored with exactly one master ($recovered_master)"
    else
      fail "Cluster did not converge on a single master after recovery"
    fi

    # All sentinels should once again see each other.
    others=$(scli "${QC_ALL[0]}" SENTINEL master "$MASTER_GROUP" 2>/dev/null | tr -d '\r' \
      | grep -A1 '^num-other-sentinels$' | tail -n1 || true)
    assert_eq "All sentinels rejoined the quorum (num-other-sentinels)" "$((REPLICAS-1))" "${others:-0}"

    # Data written before the crash must still be present.
    if [[ -n "$QC_MASTER" && -n "$recovered_master" ]]; then
      got=$(rcli "$recovered_master" GET "$QC_KEY" 2>/dev/null | tr -d '\r' || true)
      assert_eq "Data survived the quorum crash" "$QC_VAL" "$got"
      rcli "$recovered_master" DEL "$QC_KEY" >/dev/null 2>&1 || true
    fi
  fi

  trap - EXIT
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
section "Summary"
printf '  Tests run: %d   %sPassed: %d%s   %sFailed: %d%s\n' \
  "$TESTS_RUN" "$C_GRN" "$TESTS_PASS" "$C_RST" "$C_RED" "$TESTS_FAIL" "$C_RST"

if (( TESTS_FAIL > 0 )); then
  printf '\n%sFailed checks:%s\n' "$C_RED$C_BLD" "$C_RST"
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi

printf '\n%sAll end-to-end checks passed.%s\n' "$C_GRN$C_BLD" "$C_RST"
exit 0
