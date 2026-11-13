#!/usr/bin/env bash
#
# deploy_cluster-V3.1.6.sh
#
# Version: 3.1.6
# Author: Ioannis Belikaidis
# Email: ioannis.belikaidis@mitel.com
# Last Modified: 11/11/2026
#
# Loop-driven driver for the OpenScape UC cluster rollout. Run it on one SLES
# node of the cluster (normally control01, the "deploy host") that has root
# SSH keys to every node and can resolve their hostnames.
#
# VERSIONING: this driver is released together with
# k8s_cluster_multienv_setup-V<same version>.sh. When the setup script gets a
# new version, bump DEPLOY_VERSION below and rename this file to match. The
# driver refuses to run a setup script whose SCRIPT_VERSION differs.
#
# Phases (in default order):
#   prepare    mkdir -p $REMOTE_DIR on every node
#   airgapped  copy the airgapped tarball to every node (parallel)
#   scripts    copy setup script + config.env to every node
#   images     copy UC images to the image nodes + helm chart to controls (parallel)
#   firewall   stop, disable and mask firewalld (and SuSEfirewall2/ufw) on every node
#   uninstall  run --uninstall on every worker
#   install    run --airgapped workerN on every worker
#   import     run --import uc <version> on every worker (containerd import)
#
# Usage:
#   ./deploy_cluster-V3.1.6.sh                          # shows --help (no phase runs unattended)
#   ./deploy_cluster-V3.1.6.sh prepare airgapped scripts images
#   ./deploy_cluster-V3.1.6.sh --all                    # every phase incl. uninstall+install
#   ./deploy_cluster-V3.1.6.sh uninstall install
#   ./deploy_cluster-V3.1.6.sh --dry-run --all
#   ./deploy_cluster-V3.1.6.sh --only k8suc-worker03,k8suc-worker04 install
#
set -o pipefail

########################################################################
# Configuration
########################################################################

# Must equal SCRIPT_VERSION of the setup script it drives (see header).
DEPLOY_VERSION="3.1.6"

# Directory this driver lives in - the default source of every artifact,
# exactly like the setup script anchors its files to its own directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set explicitly (env SETUP_SCRIPT=... or --script) -> version mismatch only warns.
SETUP_SCRIPT_EXPLICIT=false
[[ -n "${SETUP_SCRIPT:-}" ]] && SETUP_SCRIPT_EXPLICIT=true
SETUP_SCRIPT="${SETUP_SCRIPT:-k8s_cluster_multienv_setup-V${DEPLOY_VERSION}.sh}"
CONFIG_FILE="${CONFIG_FILE:-config.env}"
AIRGAPPED_TARBALL="${AIRGAPPED_TARBALL:-k8s-airgapped-files.tar.gz}"
UC_IMAGES="${UC_IMAGES:-openscape_uc_images-V11R1.2.0-040200.tar.gz}"
UC_HELM_CHART="${UC_HELM_CHART:-uchelm-1.4.3.tgz}"

# Which nodes get the UC image tarball: all | workers | controls.
# The UC pods run on the workers, so the images have to be imported there;
# "all" keeps the controls supplied as well (default).
UC_IMAGES_NODES="${UC_IMAGES_NODES:-all}"
# The helm chart is only needed where `helm install` is run.
UC_HELM_NODES="${UC_HELM_NODES:-controls}"

# Version string passed to `--import uc <version>`; derived from the tarball
# name (openscape_uc_images-<version>.tar.gz) unless set explicitly.
UC_VERSION="${UC_VERSION:-}"
# Which nodes import the UC images into containerd (all | workers | controls).
UC_IMPORT_NODES="${UC_IMPORT_NODES:-workers}"

# Where the artifacts live on the deploy host (default: next to this driver,
# normally /var/OpenScapeUC), and where they go on the nodes.
SRC_DIR="${SRC_DIR:-$SCRIPT_DIR}"
REMOTE_DIR="${REMOTE_DIR:-/var/OpenScapeUC}"
REMOTE_USER="${REMOTE_USER:-root}"

CONTROL_NODES=(
    test-k8s-m1
    test-k8s-m2
    test-k8s-m3
)

# "hostname worker-label" - the label is the argument passed to --airgapped.
WORKER_NODES=(
    "test-k8s-w1 worker1"
)

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
SCP_OPTS=("${SSH_OPTS[@]}")

# Workers join the cluster one at a time by default; set to true to fan out.
PARALLEL_INSTALL="${PARALLEL_INSTALL:-false}"

# Image import is node-local (containerd) and touches no cluster state, so it
# fans out by default.
PARALLEL_IMPORT="${PARALLEL_IMPORT:-true}"

LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/deploy-logs}"

########################################################################
# Helpers
########################################################################

DRY_RUN=false
ONLY_FILTER=""
declare -a FAILED=()

c_info=$'\033[0;36m'; c_ok=$'\033[0;32m'; c_warn=$'\033[0;33m'
c_err=$'\033[0;31m'; c_hdr=$'\033[1;35m'; c_off=$'\033[0m'
if [[ ! -t 1 ]]; then c_info=""; c_ok=""; c_warn=""; c_err=""; c_hdr=""; c_off=""; fi

log()   { printf '%s[%s]%s %s\n' "$c_info" "$(date +%H:%M:%S)" "$c_off" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n' "$c_ok" "$c_off" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$c_warn" "$c_off" "$*"; }
err()   { printf '%s[FAIL]%s %s\n' "$c_err" "$c_off" "$*" >&2; }
phase_header() {
    printf '\n%s========== %s ==========%s\n' "$c_hdr" "$*" "$c_off"
}

# All node hostnames, controls first.
all_nodes() {
    local entry
    printf '%s\n' "${CONTROL_NODES[@]}"
    for entry in "${WORKER_NODES[@]}"; do
        printf '%s\n' "${entry%%[[:space:]]*}"
    done
}

# Honour --only <host,host,...>
node_selected() {
    local node="$1"
    [[ -z "$ONLY_FILTER" ]] && return 0
    [[ ",$ONLY_FILTER," == *",$node,"* ]]
}

selected_nodes() {
    local node
    while read -r node; do
        node_selected "$node" && printf '%s\n' "$node"
    done < <(all_nodes)
}

selected_controls() {
    local node
    for node in "${CONTROL_NODES[@]}"; do
        node_selected "$node" && printf '%s\n' "$node"
    done
}

# Hostnames only, for the selected workers.
selected_worker_hosts() {
    selected_workers | awk '{print $1}'
}

# nodes_for all|workers|controls -> hostnames honouring --only
nodes_for() {
    case "$1" in
        all)      selected_nodes ;;
        workers)  selected_worker_hosts ;;
        controls) selected_controls ;;
        *)        err "invalid node scope: $1"; return 1 ;;
    esac
}

# Emits "host label" lines for the selected workers.
selected_workers() {
    local entry host label
    for entry in "${WORKER_NODES[@]}"; do
        read -r host label <<<"$entry"
        node_selected "$host" && printf '%s %s\n' "$host" "$label"
    done
}

run_ssh() {
    local node="$1"; shift
    if $DRY_RUN; then
        echo "  DRY-RUN: ssh ${REMOTE_USER}@${node} $*"
        return 0
    fi
    # -n is load-bearing: the phase loops read their node list from a process
    # substitution on stdin, and ssh without -n drains that fd while the remote
    # command runs. The loop then hits EOF and stops after the first node.
    ssh -n "${SSH_OPTS[@]}" "${REMOTE_USER}@${node}" "$@"
}

# True if <node> is the host this driver runs on (by short/full hostname or by
# any of its resolved addresses matching a local interface address).
_LOCAL_ADDRS=""
is_local_node() {
    local node="$1" a
    [[ "$node" == "$(hostname -s 2>/dev/null)" || "$node" == "$(hostname -f 2>/dev/null)" \
        || "$node" == "$(hostname 2>/dev/null)" ]] && return 0
    [[ -z "$_LOCAL_ADDRS" ]] && _LOCAL_ADDRS=" $(hostname -I 2>/dev/null) 127.0.0.1 ::1 "
    for a in $(getent ahosts "$node" 2>/dev/null | awk '{print $1}' | sort -u); do
        [[ "$_LOCAL_ADDRS" == *" $a "* ]] && return 0
    done
    return 1
}

run_scp() {
    local file="$1" node="$2"
    # scp onto the very same file truncates the target before reading the
    # source - i.e. it destroys the artifact. On the deploy host the source
    # usually IS $REMOTE_DIR, so skip instead of copying a file onto itself.
    if is_local_node "$node" && [[ -e "$REMOTE_DIR/$(basename "$file")" \
            && "$file" -ef "$REMOTE_DIR/$(basename "$file")" ]]; then
        echo "  skip: $(basename "$file") already in place on $node (deploy host)"
        return 0
    fi
    if $DRY_RUN; then
        echo "  DRY-RUN: scp $file ${REMOTE_USER}@${node}:${REMOTE_DIR}/"
        return 0
    fi
    scp "${SCP_OPTS[@]}" "$file" "${REMOTE_USER}@${node}:${REMOTE_DIR}/"
}

require_file() {
    local f="$1"
    if [[ ! -f "$f" ]]; then
        err "missing artifact: $f"
        return 1
    fi
    return 0
}

# Waits for every PID in the given array, collecting failures.
# Usage: wait_all pids labels
wait_all() {
    local -n _pids="$1" _labels="$2"
    local i rc overall=0
    for i in "${!_pids[@]}"; do
        if wait "${_pids[$i]}"; then
            ok "${_labels[$i]}"
        else
            rc=$?
            err "${_labels[$i]} (exit $rc)"
            FAILED+=("${_labels[$i]}")
            overall=1
        fi
    done
    return $overall
}

########################################################################
# Phases
########################################################################

phase_prepare() {
    phase_header "prepare: mkdir -p ${REMOTE_DIR}"
    local node rc=0
    while read -r node; do
        log "$node"
        if run_ssh "$node" mkdir -p "$REMOTE_DIR"; then
            ok "$node: $REMOTE_DIR ready"
        else
            err "$node: mkdir failed"
            FAILED+=("prepare:$node")
            rc=1
        fi
    done < <(selected_nodes)
    return $rc
}

# copy_parallel <file> <node...>  - one background scp per node.
copy_parallel() {
    local file="$1"; shift
    local nodes=("$@")
    local -a pids=() labels=()
    local node base
    base="$(basename "$file")"

    require_file "$file" || { FAILED+=("copy:$base (missing)"); return 1; }
    mkdir -p "$LOG_DIR"

    for node in "${nodes[@]}"; do
        log "scp $base -> $node (background)"
        if $DRY_RUN; then
            run_scp "$file" "$node"
            continue
        fi
        run_scp "$file" "$node" >"$LOG_DIR/scp-${base}-${node}.log" 2>&1 &
        pids+=($!)
        labels+=("scp $base -> $node")
    done

    $DRY_RUN && return 0
    wait_all pids labels
}

# copy_serial <file> <node...>  - small files, sequential, fail-soft.
copy_serial() {
    local file="$1"; shift
    local nodes=("$@")
    local node base rc=0
    base="$(basename "$file")"

    require_file "$file" || { FAILED+=("copy:$base (missing)"); return 1; }

    for node in "${nodes[@]}"; do
        if run_scp "$file" "$node"; then
            ok "$base -> $node"
        else
            err "$base -> $node"
            FAILED+=("scp $base -> $node")
            rc=1
        fi
    done
    return $rc
}

phase_airgapped() {
    phase_header "airgapped: distribute $AIRGAPPED_TARBALL"
    mapfile -t nodes < <(selected_nodes)
    [[ ${#nodes[@]} -eq 0 ]] && { warn "no nodes selected"; return 0; }
    copy_parallel "$SRC_DIR/$AIRGAPPED_TARBALL" "${nodes[@]}"
}

phase_scripts() {
    phase_header "scripts: distribute $SETUP_SCRIPT + $CONFIG_FILE"
    mapfile -t nodes < <(selected_nodes)
    [[ ${#nodes[@]} -eq 0 ]] && { warn "no nodes selected"; return 0; }
    local rc=0
    copy_serial "$SRC_DIR/$SETUP_SCRIPT" "${nodes[@]}" || rc=1
    copy_serial "$SRC_DIR/$CONFIG_FILE"  "${nodes[@]}" || rc=1
    return $rc
}

phase_images() {
    phase_header "images: UC images -> $UC_IMAGES_NODES, helm chart -> $UC_HELM_NODES"
    local rc=0
    local -a image_nodes=() helm_nodes=()

    mapfile -t image_nodes < <(nodes_for "$UC_IMAGES_NODES") || return 1
    mapfile -t helm_nodes  < <(nodes_for "$UC_HELM_NODES")   || return 1

    if [[ ${#image_nodes[@]} -eq 0 ]]; then
        warn "no nodes selected for $UC_IMAGES"
    else
        copy_parallel "$SRC_DIR/$UC_IMAGES" "${image_nodes[@]}" || rc=1
    fi

    if [[ ${#helm_nodes[@]} -eq 0 ]]; then
        warn "no nodes selected for $UC_HELM_CHART"
    else
        copy_parallel "$SRC_DIR/$UC_HELM_CHART" "${helm_nodes[@]}" || rc=1
    fi
    return $rc
}

# Done by the setup script's check_firewall too, but before 3.1.6 that left a
# stopped-but-enabled firewalld alone and it came back on the next reboot.
# This phase is idempotent and can be run on its own to fix deployed nodes.
FIREWALL_CMD='rc=0; for s in firewalld SuSEfirewall2 ufw; do
  systemctl list-unit-files "$s.service" --no-legend 2>/dev/null | grep -q . || continue
  systemctl disable --now "$s" >/dev/null 2>&1; systemctl mask "$s" >/dev/null 2>&1
  a=$(systemctl is-active "$s" 2>/dev/null); e=$(systemctl is-enabled "$s" 2>/dev/null)
  echo "$s: active=$a enabled=$e"
  if [ "$a" = active ] || [ "$e" = enabled ]; then rc=1; fi
done; exit $rc'

phase_firewall() {
    phase_header "firewall: stop, disable and mask the host firewall"
    local node out rc=0
    while read -r node; do
        if $DRY_RUN; then
            run_ssh "$node" "<disable --now + mask firewalld/SuSEfirewall2/ufw>"
            continue
        fi
        if out="$(run_ssh "$node" "$FIREWALL_CMD" 2>&1)"; then
            ok "$node: ${out:-no firewall service installed}"
        else
            err "$node: firewall still on: ${out//$'\n'/; }"
            FAILED+=("firewall:$node")
            rc=1
        fi
    done < <(selected_nodes)
    return $rc
}

phase_uninstall() {
    phase_header "uninstall: $SETUP_SCRIPT --uninstall on workers"
    local host label rc=0
    mkdir -p "$LOG_DIR"
    while read -r host label; do
        log "$host: uninstall"
        if $DRY_RUN; then
            run_ssh "$host" bash "$REMOTE_DIR/$SETUP_SCRIPT" --uninstall
            continue
        fi
        if run_ssh "$host" bash "$REMOTE_DIR/$SETUP_SCRIPT" --uninstall \
                2>&1 | tee "$LOG_DIR/uninstall-${host}.log"; then
            ok "$host: uninstalled"
        else
            err "$host: uninstall failed (see $LOG_DIR/uninstall-${host}.log)"
            FAILED+=("uninstall:$host")
            rc=1
        fi
    done < <(selected_workers)
    return $rc
}

phase_install() {
    phase_header "install: $SETUP_SCRIPT --airgapped <worker> on workers"
    local host label rc=0
    local -a pids=() labels=()
    mkdir -p "$LOG_DIR"

    while read -r host label; do
        log "$host: install as $label"
        if $DRY_RUN; then
            run_ssh "$host" bash "$REMOTE_DIR/$SETUP_SCRIPT" --airgapped "$label"
            continue
        fi
        if [[ "$PARALLEL_INSTALL" == "true" ]]; then
            run_ssh "$host" bash "$REMOTE_DIR/$SETUP_SCRIPT" --airgapped "$label" \
                >"$LOG_DIR/install-${host}.log" 2>&1 &
            pids+=($!)
            labels+=("install:$host ($label)")
        else
            if run_ssh "$host" bash "$REMOTE_DIR/$SETUP_SCRIPT" --airgapped "$label" \
                    2>&1 | tee "$LOG_DIR/install-${host}.log"; then
                ok "$host: joined as $label"
            else
                err "$host: install failed (see $LOG_DIR/install-${host}.log)"
                FAILED+=("install:$host")
                rc=1
            fi
        fi
    done < <(selected_workers)

    if [[ "$PARALLEL_INSTALL" == "true" ]] && ! $DRY_RUN; then
        wait_all pids labels || rc=1
    fi
    return $rc
}

phase_import() {
    phase_header "import: $SETUP_SCRIPT --import uc $UC_VERSION on $UC_IMPORT_NODES"
    local host rc=0
    local -a pids=() labels=() nodes=()
    mkdir -p "$LOG_DIR"

    mapfile -t nodes < <(nodes_for "$UC_IMPORT_NODES")
    [[ ${#nodes[@]} -eq 0 ]] && { warn "no nodes selected for import"; return 0; }

    for host in "${nodes[@]}"; do
        log "$host: import uc $UC_VERSION"
        if $DRY_RUN; then
            run_ssh "$host" bash "$REMOTE_DIR/$SETUP_SCRIPT" --import uc "$UC_VERSION"
            continue
        fi
        if [[ "$PARALLEL_IMPORT" == "true" ]]; then
            run_ssh "$host" bash "$REMOTE_DIR/$SETUP_SCRIPT" --import uc "$UC_VERSION" \
                >"$LOG_DIR/import-${host}.log" 2>&1 &
            pids+=($!)
            labels+=("import:$host")
        else
            if run_ssh "$host" bash "$REMOTE_DIR/$SETUP_SCRIPT" --import uc "$UC_VERSION" \
                    2>&1 | tee "$LOG_DIR/import-${host}.log"; then
                ok "$host: images imported"
            else
                err "$host: import failed (see $LOG_DIR/import-${host}.log)"
                FAILED+=("import:$host")
                rc=1
            fi
        fi
    done

    if [[ "$PARALLEL_IMPORT" == "true" ]] && ! $DRY_RUN; then
        wait_all pids labels || rc=1
    fi
    return $rc
}

########################################################################
# CLI
########################################################################

usage() {
    cat <<EOF
deploy_cluster v$DEPLOY_VERSION  (pairs with k8s_cluster_multienv_setup-V$DEPLOY_VERSION.sh)

Usage: $(basename "$0") [options] [phase ...]

Phases:
  prepare     mkdir -p $REMOTE_DIR on all nodes
  airgapped   copy $AIRGAPPED_TARBALL to all nodes (parallel)
  scripts     copy $SETUP_SCRIPT and $CONFIG_FILE to all nodes
  images      copy $UC_IMAGES to the $UC_IMAGES_NODES nodes and
              $UC_HELM_CHART to the $UC_HELM_NODES nodes (parallel)
  firewall    stop, disable and mask firewalld on all nodes (idempotent)
  uninstall   run --uninstall on all workers
  install     run --airgapped <workerN> on all workers
  import      run --import uc <version> on the $UC_IMPORT_NODES nodes

  With no arguments at all: shows this help (nothing runs)
  With options but no phase: prepare airgapped scripts images
  (uninstall/install must be requested explicitly or via --all)

Options:
  --all                 run every phase, in order
  --only host1,host2    restrict to these hostnames
  --workers-only        restrict to worker nodes
  --controls-only       restrict to control nodes
  --parallel-install    join workers concurrently (default: one at a time)
  --images-to SCOPE     where the UC image tarball goes: all|workers|controls
                        (default: $UC_IMAGES_NODES)
  --helm-to SCOPE       where the helm chart goes: all|workers|controls
                        (default: $UC_HELM_NODES)
  --import-to SCOPE     which nodes import the UC images: all|workers|controls
                        (default: $UC_IMPORT_NODES)
  --uc-version VER      version for --import uc (default: derived from
                        $UC_IMAGES)
  --serial-import       import one node at a time (default: all at once)
  --src-dir DIR         artifact directory on the deploy host (default: $SRC_DIR)
  --script NAME         setup script filename (default: $SETUP_SCRIPT)
                        its version must be $DEPLOY_VERSION unless --script is given
  -n, --dry-run         print the ssh/scp commands without running them
  -h, --help            this text

Examples:
  $(basename "$0") --dry-run --all
  $(basename "$0") scripts
  $(basename "$0") --only k8suc-worker05-bm uninstall install
  $(basename "$0") --workers-only firewall
EOF
}

ARGC=$#
PHASES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)              PHASES=(prepare airgapped scripts images firewall uninstall install import); shift ;;
        --only)             ONLY_FILTER="${2//[[:space:]]/}"; shift 2 ;;
        --workers-only)     ONLY_FILTER="$(selected_workers | awk '{print $1}' | paste -sd,)"; shift ;;
        --controls-only)    ONLY_FILTER="$(printf '%s\n' "${CONTROL_NODES[@]}" | paste -sd,)"; shift ;;
        --parallel-install) PARALLEL_INSTALL=true; shift ;;
        --images-to)        UC_IMAGES_NODES="$2"; shift 2 ;;
        --helm-to)          UC_HELM_NODES="$2"; shift 2 ;;
        --import-to)        UC_IMPORT_NODES="$2"; shift 2 ;;
        --uc-version)       UC_VERSION="$2"; shift 2 ;;
        --serial-import)    PARALLEL_IMPORT=false; shift ;;
        --src-dir)          SRC_DIR="$2"; shift 2 ;;
        --script)           SETUP_SCRIPT="$2"; SETUP_SCRIPT_EXPLICIT=true; shift 2 ;;
        -n|--dry-run)       DRY_RUN=true; shift ;;
        -h|--help)          usage; exit 0 ;;
        prepare|airgapped|scripts|images|firewall|uninstall|install|import)
                            PHASES+=("$1"); shift ;;
        *)                  err "unknown argument: $1"; usage; exit 2 ;;
    esac
done

# Bare invocation (no arguments at all) shows help instead of silently
# running against every real node - it must be an explicit choice.
if [[ ${#PHASES[@]} -eq 0 ]]; then
    if [[ $ARGC -eq 0 ]]; then
        usage
        exit 0
    fi
    PHASES=(prepare airgapped scripts images)
fi

# openscape_uc_images-V11R1.2.0-040200.tar.gz -> V11R1.2.0-040200
if [[ -z "$UC_VERSION" ]]; then
    _v="$(basename "$UC_IMAGES")"
    _v="${_v%.tar.gz}"; _v="${_v%.tgz}"
    UC_VERSION="${_v##*images-}"
fi
if [[ " ${PHASES[*]} " == *" import "* && ! "$UC_VERSION" =~ ^V[0-9] ]]; then
    err "cannot derive a UC version from '$UC_IMAGES' (got '$UC_VERSION')"
    err "pass it explicitly: --uc-version V11R1.2.0-040200"
    exit 2
fi

# Version lock: the driver and the setup script are released as a pair.
_setup_path="$SRC_DIR/$SETUP_SCRIPT"
if [[ -f "$_setup_path" ]]; then
    _setup_ver="$(grep -m1 '^export SCRIPT_VERSION=' "$_setup_path" | cut -d'"' -f2)"
    if [[ "$_setup_ver" != "$DEPLOY_VERSION" ]]; then
        if $SETUP_SCRIPT_EXPLICIT; then
            warn "setup script $SETUP_SCRIPT is v${_setup_ver:-?}, this driver is v$DEPLOY_VERSION (--script given, continuing)"
        else
            err "version mismatch: $SETUP_SCRIPT is v${_setup_ver:-?}, this driver is v$DEPLOY_VERSION"
            err "use deploy_cluster-V${_setup_ver}.sh, or pass --script to override"
            exit 2
        fi
    fi
elif [[ " ${PHASES[*]} " == *" scripts "* ]]; then
    err "setup script not found: $_setup_path"
    exit 2
else
    warn "setup script not found locally ($_setup_path) - remote phases use the copy already on the nodes"
fi

for scope in "$UC_IMAGES_NODES" "$UC_HELM_NODES" "$UC_IMPORT_NODES"; do
    case "$scope" in
        all|workers|controls) ;;
        *) err "invalid node scope '$scope' (expected all|workers|controls)"; exit 2 ;;
    esac
done

log "deploy_cluster v$DEPLOY_VERSION on $(hostname -s 2>/dev/null)"
log "source dir : $SRC_DIR"
log "remote dir : ${REMOTE_USER}@<node>:$REMOTE_DIR"
log "setup script: $SETUP_SCRIPT"
log "uc images  : -> $UC_IMAGES_NODES   helm chart -> $UC_HELM_NODES"
log "uc import  : $UC_VERSION -> $UC_IMPORT_NODES"
log "phases     : ${PHASES[*]}"
[[ -n "$ONLY_FILTER" ]] && log "restricted to: $ONLY_FILTER"
$DRY_RUN && warn "dry-run: nothing will be executed"

overall=0
for p in "${PHASES[@]}"; do
    "phase_$p" || overall=1
done

phase_header "summary"
if [[ ${#FAILED[@]} -eq 0 ]]; then
    ok "all phases completed: ${PHASES[*]}"
else
    err "${#FAILED[@]} step(s) failed:"
    printf '       - %s\n' "${FAILED[@]}" >&2
fi
$DRY_RUN || log "logs in $LOG_DIR"
exit $overall

