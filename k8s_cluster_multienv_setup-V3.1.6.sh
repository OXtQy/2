#!/bin/bash
#################################################################################
# Copyright (c) 2026 Unify Software & Solutions GmbH & Co. KG, a Mitel company  #
#################################################################################

#================================================================================#
# K8s Cluster MultiSetup Script
#
# Script Name: k8s_cluster_multienv_setup-VX.X.X.sh
# Description: Script to automate a single or 3 node K8s cluster setup
#              with RKE2, Helm, Calico, MetalLB, Longhorn, Kube-Vip etc.
#              from a new fresh installed VM with SLES 15 SP7.
#              Supports install, upgrade, rollback, check, and diagnostics.
#
# Version: 3.1.6
# Author: Ioannis Belikaidis
# Email: ioannis.belikaidis@mitel.com
# Last Modified: 11/11/2026
#
# Usage:
#   chmod +x k8s_cluster_multienv_setup-VX.X.X.sh
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --<mode> <operand>
#
#   Options are GNU-style long form only (--airgapped, --upgrade, --help).
#   Single-dash spellings are not accepted.
#
#   The script runs UNATTENDED by default — it never prompts, and takes every
#   answer from config.env / the built-in defaults. Add --interactive (any
#   position) to get the configuration questions and confirmations back.
#
# Examples:
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --import uc V11R1.0.0-040000
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --airgapped single
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --airgapped node1
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --airgapped node2
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --airgapped node3
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --airgapped worker1
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --airgapped worker2   (up to worker99)
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --airgapped stack     (3 masters + workers: on node3, after the LAST worker)
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --scale-airgapped node2
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --scale-airgapped node3
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --scale-airgapped worker1
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --export-worker-kubeconfig
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --info
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --check
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --help
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --upgrade all
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --upgrade all --airgapped
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --upgrade longhorn
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --rollback
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --rollback 20260428-143000
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --uninstall
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --collect
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --dry-run --airgapped single
#   ./k8s_cluster_multienv_setup-VX.X.X.sh --dry-run --upgrade all
# --------------------------------------------------------------------------------------------------------
#
#
# Notes:
#   For airgapped installations, the script will automatically extract the archives:
#   - Supports both k8s-airgapped-files.tar and k8s-airgapped-files.tar.gz
#   - Container images (container-images.tar or container-images.tar.gz) will also be auto-extracted
#   - If using combined UC images tar, it will be auto-extracted during import
#   - If the k8s-airgapped-files directory already exists, extraction is skipped
#
#   Performance Optimizations:
#   - UC images staged into RKE2's airgap image dir and imported/pinned directly via ctr
#   - Diagnostics collected in parallel (default: 8 concurrent tasks, configurable via MAX_PARALLEL_DIAGNOSTICS)
#   - Version checks parallelized (default: 6 concurrent, configurable via MAX_PARALLEL_VERSION_CHECKS)
#
# Dependencies:
#   1)For Airgapped installations, please place the k8s-airgapped-files.tar.gz or
#   k8s-airgapped-files.tar file in the same folder as this script under /var/OpenScapeUC. The script
#   will automatically extract it.
#   2)You need to create/configure the config.env file and place it at the same
#   folder as this script.
#   3)For importing UC, you need to have the UC images tar file
#   (e.g. uc-images-V11R1.0.0-071900.tar.gz) in the same folder as this script.
#
# This script is intended for SLES systems only.
#================================================================================#
set -o pipefail

# Define ANSI color codes.
#
# Colors are only meaningful to a human sitting at a terminal. Whenever stdout
# is not a TTY — the script piped into `tee`, driven over ssh by
# deploy_cluster.sh, captured by Ansible or a CI job — the escapes end up in the
# captured log as literal "ESC[0;32m" noise that breaks grep and makes the file
# painful to read. So: emit escapes only for a real terminal, and honour the
# NO_COLOR convention (https://no-color.org) for anyone who wants them off.
# IS_TTY is reused further down to drop the spinner animation for the same
# reason (it writes hundreds of \r frames that a log file cannot render).
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    IS_TTY=true
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    NC=$'\033[0m'  # No Color
else
    IS_TTY=false
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

# Script version — defined here, before anything can print it. The startup
# banner runs well before the config.env section further down, so this must
# not live there or the banner renders as "Script v" with no number.
export SCRIPT_VERSION="3.1.6"

# Directory this script lives in. Everything the script reads (the airgapped
# bundle, config.env, the UC image tarballs) is documented as living next to
# it, so this — not the caller's working directory — is the anchor for those
# paths. main() cd's here before doing any work.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Log file variable — absolute, so the log stays in one file regardless of
# where the script was invoked from or that main() changes directory.
LOG_FILE="${SCRIPT_DIR}/node_setup.log"

# Base directory — script must be run from under this path
UC_BASE_DIR="/var/OpenScapeUC"
# All temporary files go here instead of /tmp or /var/tmp
UC_TMP_DIR="${UC_BASE_DIR}/tmp"

# Track installation start time
START_TIME=$(date +%s)

# Component versions tracker for summary
declare -A INSTALLED_COMPONENTS

# Dry-run mode flag (set by -dry-run argument)
DRY_RUN=false

# Interactive mode flag (set by the --interactive argument).
# Default false: the script runs unattended. Every question is answered from
# config.env / the built-in defaults instead of blocking on a prompt, so the
# script can be driven from Ansible, cron, a pipeline or a plain ssh command.
# Pass --interactive to get the original question-and-answer flow back.
INTERACTIVE=false

# Config file path and minimum version — defined here, before anything can read config.env.
export CONFIG_FILE_PATH="$(dirname "$0")/config.env"
export MIN_CONFIG_VERSION="2.1.6"

# Ensure rke2/kubectl are resolvable regardless of the invoking shell's PATH.
# Install-flow functions append these to ~/.bashrc for future interactive
# logins, but that does nothing for a script invocation (e.g. -upgrade,
# -check) whose parent shell hasn't re-sourced .bashrc since RKE2 was set up.
# /opt/rke2/bin is where SUSE's RKE2 RPM package installs the rke2 binary on
# SLES/openSUSE (this script's target OS); /usr/local/bin and
# /var/lib/rancher/rke2/bin cover the get.rke2.io tarball install method.
for _rke2_bin_dir in /opt/rke2/bin /usr/local/bin /var/lib/rancher/rke2/bin; do
    case ":$PATH:" in
        *":${_rke2_bin_dir}:"*) ;;
        *) export PATH="$PATH:${_rke2_bin_dir}" ;;
    esac
done
unset _rke2_bin_dir

# ==================== LOCKFILE (prevent concurrent runs) ====================
LOCK_FILE="/var/run/k8s-setup.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo -e "${RED}[ERROR] Another instance of this script is already running.${NC}"
    echo -e "${RED}[ERROR] If you are sure no other instance is running, remove $LOCK_FILE and retry.${NC}"
    exit 1
fi

# ==================== SECRET MASKING ====================
# Sanitize sensitive data (tokens, passwords) from log output
sanitize_log() {
    local msg="$1"
    # Mask RKE2 tokens (format: K10...<long string>)
    msg=$(echo "$msg" | sed -E 's/K10[a-zA-Z0-9:]{10,}/K10****REDACTED****/g')
    # Mask TOKEN= values (quoted or unquoted)
    msg=$(echo "$msg" | sed -E 's/(Token:|TOKEN="|TOKEN=)[[:space:]]*("?)([^"[:space:]]{8,})/\1 ****REDACTED****/g')
    # Strip ANSI escapes and carriage returns that came in with the message
    # itself — captured helm/kubectl/curl output is frequently colored, and
    # those escapes would land in $LOG_FILE regardless of IS_TTY. The wrapper's
    # own color is applied outside this function, so nothing intended is lost.
    msg=$(echo "$msg" | sed -E $'s/\033\\[[0-9;?]*[a-zA-Z]//g; s/\r//g')
    echo "$msg"
}

# ==================== LOG FUNCTIONS ====================
# Emit one timestamped line: colored on the console, plain in $LOG_FILE.
#
# The old form was `echo -e "${GREEN}...${NC}" | tee -a "$LOG_FILE"`, which sent
# the identical colored bytes to both destinations — so node_setup.log filled up
# with ESC[0;32m sequences. Writing the two destinations separately keeps the
# terminal colored while the file stays plain text, greppable and diffable.
log_line() {
    local color="$1" line
    line="$(date +"%Y-%m-%d %T") - $(sanitize_log "$2")"
    printf '%s%s%s\n' "$color" "$line" "${color:+$NC}"
    printf '%s\n' "$line" >> "$LOG_FILE"
}

log() {
    log_line "" "$1"
}
log_success() {
    log_line "$GREEN" "$1"
}
log_error() {
    log_line "$RED" "$1"
}
log_warning() {
    log_line "$YELLOW" "$1"
}

# Log only to file (not console) - for verbose output
log_only() {
    local sanitized
    sanitized=$(sanitize_log "$1")
    echo -e "$(date +"%Y-%m-%d %T") - $sanitized" >> "$LOG_FILE"
}

# Console only message (not logged to file) - for clean console output
log_console() {
    echo -e "$1"
}

# ==================== PROMPTING (INTERACTIVE / UNATTENDED) ====================
# The script is unattended by default; --interactive restores the prompts.
# Every question in the script goes through one of the three helpers below so
# there is exactly one place that decides what an unattended run answers.

# ask_value <VARNAME> <prompt text>
#   Interactive : ask, offering the current value as the default (empty = keep).
#   Unattended  : keep the current value (config.env or built-in default).
ask_value() {
    local __var="$1" __prompt="$2" __input=""
    if [[ "$INTERACTIVE" == true ]]; then
        read -r -p "${__prompt} [${!__var}]: " __input
        [[ -n "$__input" ]] && printf -v "$__var" '%s' "$__input"
    else
        log_only "[INFO] ${__var}=${!__var} (unattended default)"
    fi
    return 0
}

# ask_yes_no <VARNAME> <prompt text> <default Y|N>
#   Interactive : ask; an empty answer selects <default>.
#   Unattended  : keep VARNAME if it is already a Y/N value, else use <default>.
ask_yes_no() {
    local __var="$1" __prompt="$2" __default="$3" __input=""
    # Note: the indirect read must not share the `local` line above — bash
    # declares all the names there before assigning them, so ${!__var} would
    # fail with "invalid indirect expansion".
    local __current="${!__var}"
    if [[ "$INTERACTIVE" == true ]]; then
        read -r -p "${__prompt} (Y/N) [${__default}]: " __input
        printf -v "$__var" '%s' "${__input:-$__default}"
    else
        if [[ "$__current" =~ ^[YyNn]$ ]]; then
            printf -v "$__var" '%s' "$__current"
        else
            printf -v "$__var" '%s' "$__default"
        fi
        log_only "[INFO] ${__var}=${!__var} (unattended default)"
    fi
    return 0
}

# confirm_action <message>
#   "Do you want to go ahead with the operation you asked for?"
#   Interactive : ask, default No.
#   Unattended  : yes — the operation was already requested on the command line.
#   Returns 0 to proceed, 1 to abort.
confirm_action() {
    local __message="$1" __confirm=""
    if [[ "$INTERACTIVE" == true ]]; then
        read -r -p "${__message} (y/N): " __confirm
        [[ "$__confirm" =~ ^[Yy]$ ]] && return 0
        return 1
    fi
    log "[INFO] Unattended run — auto-confirmed: ${__message}"
    return 0
}

# confirm_override <message>
#   "A check failed / a risk was detected — continue anyway?"
#   Interactive : ask, default No.
#   Unattended  : no. An unattended run must not push past a failed safety
#                 check; fix the cause or re-run with --interactive.
#   Returns 0 to proceed, 1 to abort.
confirm_override() {
    local __message="$1" __confirm=""
    if [[ "$INTERACTIVE" == true ]]; then
        read -r -p "${__message} (y/N): " __confirm
        [[ "$__confirm" =~ ^[Yy]$ ]] && return 0
        return 1
    fi
    log_error "[ERROR] Unattended run — not continuing past a failed check."
    log_error "[ERROR] Fix the reported problem, or re-run with --interactive to override."
    return 1
}

# confirm_destructive <message>
#   "This deletes data that cannot be recreated from this script."
#   Interactive : ask, default No.
#   Unattended  : no, and say so loudly. Wiping persistent data is never
#                 something an unattended run should decide on its own, even
#                 when the operation itself was requested on the command line.
#   Returns 0 to proceed, 1 to skip.
confirm_destructive() {
    local __message="$1" __confirm=""
    if [[ "$INTERACTIVE" == true ]]; then
        log_warning "[WARNING] This step destroys data and cannot be undone."
        read -r -p "${__message} (y/N): " __confirm
        [[ "$__confirm" =~ ^[Yy]$ ]] && return 0
        log "Skipped: ${__message}"
        return 1
    fi
    log_warning "[WARNING] SKIPPED (unattended): ${__message}"
    log_warning "[WARNING] Re-run with --interactive to include this step."
    return 1
}

# ==================== SIGNAL HANDLING & CLEANUP ====================
# Global temp files to clean up on exit
CLEANUP_FILES=()

# Register a file/directory for cleanup on exit
register_cleanup() {
    CLEANUP_FILES+=("$1")
}

# Cleanup function for normal exit
cleanup_on_exit() {
    # Remove registered temp files
    for f in "${CLEANUP_FILES[@]}"; do
        [[ -n "$f" && "$f" != "/" && "$f" != "." ]] && rm -rf "$f" 2>/dev/null
    done
    # Remove spinner temp log if exists
    rm -f "${UC_TMP_DIR}/spinner_cmd_$$.log" 2>/dev/null
    # Release lockfile (fd 200 closes automatically)
}

# Signal handler for INT/TERM/HUP
cleanup_and_exit() {
    local signal="$1"
    local exit_code="${2:-1}"

    echo ""
    log_warning "[WARNING] Signal $signal received — cleaning up..."

    # Kill any background jobs still running (spinners, parallel imports/checks/diagnostics).
    # `jobs -p` only lists jobs this shell still considers active, so it naturally
    # excludes anything already wait()'d on — no stale-PID/PID-reuse risk.
    local job_pids
    job_pids=$(jobs -p)
    if [[ -n "$job_pids" ]]; then
        kill $job_pids 2>/dev/null || true
    fi

    # Run normal cleanup
    cleanup_on_exit

    log_warning "[WARNING] Script interrupted. System may be in partial state."
    log_warning "[WARNING] Review $LOG_FILE and re-run the script to resume."

    exit "$exit_code"
}

# Set traps
trap cleanup_on_exit EXIT
trap 'cleanup_and_exit SIGINT 130'  INT
trap 'cleanup_and_exit SIGTERM 143' TERM
trap 'cleanup_and_exit SIGHUP 129'  HUP

# Dry-run guard — call at top of mutating functions
# Usage: dry_run_guard "description of what would happen" && return 0
dry_run_guard() {
    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] Would: $1"
        return 0
    fi
    return 1
}

# Check if running inside tmux/screen (for upgrade/rollback safety)
check_persistent_session() {
    if [[ -n "$TMUX" ]]; then
        log_success "[OK] Running inside tmux session"
        return 0
    fi
    if [[ -n "$STY" ]]; then
        log_success "[OK] Running inside screen session"
        return 0
    fi
    # Check if parent is sshd (remote session without tmux/screen)
    local parent_cmd
    parent_cmd=$(ps -o comm= -p "$PPID" 2>/dev/null)
    if [[ "$parent_cmd" == "sshd" || "$parent_cmd" == "ssh" ]]; then
        log_warning "╔══════════════════════════════════════════════════════════════╗"
        log_warning "║  WARNING: Running over SSH without tmux or screen!           ║"
        log_warning "║                                                              ║"
        log_warning "║  If your SSH session drops during upgrade, the cluster       ║"
        log_warning "║  may be left in a partially upgraded state.                  ║"
        log_warning "║                                                              ║"
        log_warning "║  Recommended: tmux new -s k8s-upgrade                        ║"
        log_warning "║  Then re-run this script inside the tmux session.            ║"
        log_warning "╚══════════════════════════════════════════════════════════════╝"
        echo ""
        # Advisory only — an unattended run is expected to be detached already
        # (nohup/systemd/Ansible), so this warns and continues instead of
        # blocking. Interactively it still asks.
        if [[ "$INTERACTIVE" == true ]]; then
            read -r -p "Continue anyway? (y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                log "Aborted. Start a tmux session and re-run."
                exit 0
            fi
        fi
        log_warning "Proceeding without persistent session."
    fi
}

# Print section header
print_section_header() {
    local title="$1"
    local phase="$2"
    log_console ""
    log_console "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    if [[ -n "$phase" ]]; then
        log_console "${GREEN}  $phase: $title${NC}"
    else
        log_console "${GREEN}  $title${NC}"
    fi
    log_console "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    log_only "========== $phase: $title =========="
}

# Function to capture stdout and stderr into the log file
capture_output() {
    "$@" >> "$LOG_FILE" 2>&1
}

sleep_for() {
    log_only "Sleeping for $1 seconds..."
    sleep $1
}

# Calculate and format duration
format_duration() {
    local seconds=$1
    local minutes=$((seconds / 60))
    local remaining_seconds=$((seconds % 60))
    if [[ $minutes -gt 0 ]]; then
        echo "${minutes}m ${remaining_seconds}s"
    else
        echo "${seconds}s"
    fi
}

# Parallel execution helper function
# Usage: run_parallel MAX_JOBS task_array[@] command_array[@]
# Returns: 0 if all tasks succeeded, 1 if any failed
run_parallel() {
    local max_jobs="$1"
    shift
    local -n tasks_ref="$1"
    shift
    local -n commands_ref="$1"

    declare -a pids=()
    declare -a temp_files=()
    local parallel_jobs=0
    local failed_count=0

    mkdir -p "${UC_TMP_DIR}" 2>/dev/null

    # Phase 1: Launch tasks in parallel batches
    for idx in "${!tasks_ref[@]}"; do
        local task="${tasks_ref[$idx]}"
        local cmd="${commands_ref[$idx]}"
        local temp_log="${UC_TMP_DIR}/parallel_${task}_$$.log"
        temp_files+=("$temp_log")

        # Launch task in background
        (
            eval "$cmd" > "$temp_log" 2>&1
            local exit_code=$?
            if [[ $exit_code -eq 0 ]]; then
                echo "SUCCESS" >> "$temp_log"
            else
                echo "FAILED" >> "$temp_log"
            fi
            exit $exit_code
        ) &
        pids+=($!)
        ((parallel_jobs++))

        # Wait if we've reached max parallel limit
        if [[ $parallel_jobs -ge $max_jobs ]]; then
            wait "${pids[0]}" 2>/dev/null || ((failed_count++))
            unset 'pids[0]'
            pids=("${pids[@]}")  # Re-index array
            ((parallel_jobs--))
        fi
    done

    # Phase 2: Wait for all remaining jobs
    for pid in "${pids[@]}"; do
        if [[ -n "$pid" ]]; then
            wait "$pid" 2>/dev/null || ((failed_count++))
        fi
    done

    # Cleanup temp files
    rm -f "${temp_files[@]}" 2>/dev/null

    return $failed_count
}

# Spinner animation for background processes
# Usage: run_with_spinner "message" command args...
run_with_spinner() {
    local message="$1"
    shift
    local spinner_chars='|/-\\'
    mkdir -p "${UC_TMP_DIR}" 2>/dev/null
    local temp_log="${UC_TMP_DIR}/spinner_cmd_$$.log"

    # Run command in background
    "$@" > "$temp_log" 2>&1 &
    local pid=$!

    # Show spinner while process runs — but only on a real terminal. Redrawing
    # the same line with \r is meaningless in a captured log: it produced
    # hundreds of "^MESC[0;33mExtracting UC images archive... |" frames in every
    # tee'd/ssh log. Non-interactive runs get one plain line instead.
    if [[ "$IS_TTY" == true ]]; then
        local i=0
        printf "\r${YELLOW}%s %s${NC}" "$message" "|"
        while kill -0 $pid 2>/dev/null; do
            local char="${spinner_chars:i++%4:1}"
            printf "\r${YELLOW}%s %s${NC}" "$message" "$char"
            sleep 0.2
        done
    else
        printf '%s\n' "$message"
    fi

    # Wait for process to complete and get exit code
    wait $pid
    local exit_code=$?

    # Clear spinner line (nothing to clear when no spinner was drawn)
    [[ "$IS_TTY" == true ]] && printf "\r%*s\r" "$((${#message} + 2))" ""

    # Append temp log to main log, stripped of the command's own ANSI escapes
    # and \r progress redraws (curl and the RKE2 installer both emit them).
    sed -E $'s/\033\\[[0-9;?]*[a-zA-Z]//g; s/\r/\\\n/g' "$temp_log" >> "$LOG_FILE" 2>&1
    rm -f "$temp_log"

    return $exit_code
}

# Capture RKE2 service diagnostics and abort. Call whenever `systemctl start <unit>`
# fails or the readiness-wait loop times out, so the operator sees the real root
# cause on the very next attempt instead of a generic systemd one-liner or a
# 20-minute silent retry cascade.
diagnose_rke2_service_failure() {
    local unit="$1"          # e.g. rke2-server.service / rke2-agent.service
    local journal_unit="$2"  # e.g. rke2-server / rke2-agent
    local since="${3:-}"     # optional: timestamp this start attempt began ('%Y-%m-%d %H:%M:%S')

    local since_args=()
    [[ -n "$since" ]] && since_args=(--since "$since")

    log_error "[ERROR] $unit failed to start. Capturing diagnostics..."
    log_only "===== systemctl status $unit ====="
    capture_output sudo systemctl status "$unit" --no-pager -l
    log_only "===== journalctl -xeu $journal_unit (full history since this attempt started) ====="
    capture_output sudo journalctl -xeu "$journal_unit" --no-pager "${since_args[@]}"

    # Show the START of this attempt, not the tail — a rapidly-repeating
    # crash loop (e.g. every few seconds) can push the actual root-cause
    # message out of a tail-only view within minutes; the first occurrence
    # is almost always what carries the real reason, with later ones just
    # repeating the same generic supervisor-level message.
    log_error "[ERROR] First 40 journal lines for $journal_unit since this attempt started:"
    sudo journalctl -xeu "$journal_unit" --no-pager "${since_args[@]}" | head -40 | tee -a "$LOG_FILE"

    log_error "[ERROR] Full diagnostics written to $LOG_FILE"
    log_error "[ERROR] Common causes: wrong/stale TOKEN in config.env, VIP:9345 unreachable (kube-vip not up/leader on node1), clock skew (check: timedatectl status), leftover state from a prior failed install (/var/lib/rancher/rke2/server)."
}

# ==================== INPUT VALIDATION FUNCTIONS ====================

# Validate IP address format
validate_ip() {
    local ip=$1
    local name=$2
    if [[ ! $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_error "[ERROR] Invalid IP address format for $name: $ip"
        return 1
    fi
    # Check each octet
    local IFS='.'
    local -a octets=($ip)
    for octet in "${octets[@]}"; do
        if ((octet > 255)); then
            log_error "[ERROR] Invalid IP address for $name: $ip (octet > 255)"
            return 1
        fi
    done
    return 0
}

# Validate IP range format for MetalLB
validate_ip_range() {
    local range=$1
    if [[ ! $range =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}-([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        log_error "[ERROR] Invalid IP range format: $range"
        log_error "[ERROR] Expected format: 10.11.248.170-10.11.248.190"
        return 1
    fi
    local start_ip=$(echo "$range" | cut -d'-' -f1)
    local end_ip=$(echo "$range" | cut -d'-' -f2)
    validate_ip "$start_ip" "Range Start" || return 1
    validate_ip "$end_ip" "Range End" || return 1
    return 0
}

# Validate CIDR format for Calico
validate_cidr() {
    local cidr=$1
    if [[ ! $cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        log_error "[ERROR] Invalid CIDR format: $cidr"
        log_error "[ERROR] Expected format: 10.11.248.128/25"
        return 1
    fi
    local ip=$(echo "$cidr" | cut -d'/' -f1)
    local mask=$(echo "$cidr" | cut -d'/' -f2)
    validate_ip "$ip" "CIDR" || return 1
    if ((mask < 1 || mask > 32)); then
        log_error "[ERROR] Invalid subnet mask: /$mask (must be /1 to /32)"
        return 1
    fi
    return 0
}

# Validate network interface exists
validate_interface() {
    local iface=$1
    if ! ip link show "$iface" &>/dev/null; then
        log_error "[ERROR] Network interface '$iface' does not exist"
        log_error "[ERROR] Available interfaces: $(ip -br link | awk '{print $1}' | tr '\n' ' ')"
        return 1
    fi
    log_success "[OK] Network interface '$iface' exists"
    return 0
}

# Validate version format
validate_version() {
    local version=$1
    local name=$2
    if [[ -z "$version" ]]; then
        log_error "[ERROR] $name version is empty"
        return 1
    fi
    # Basic semantic version check
    if [[ ! $version =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?(\+.*)?$ ]]; then
        log_warning "[WARNING] $name version format may be invalid: $version"
    fi
    return 0
}

# Validate proxy URL format
validate_proxy_url() {
    local url=$1
    local name=$2
    if [[ ! $url =~ ^https?://[^/]+:[0-9]+/$ ]]; then
        log_error "[ERROR] Invalid proxy URL format for $name: $url"
        log_error "[ERROR] Expected format: http://172.29.38.124:8080/"
        return 1
    fi
    return 0
}

# Check network connectivity (for online mode)
check_connectivity() {
    if [[ "$ARGUMENT_TYPE" == "--airgapped" ]]; then
        log "Airgapped mode - skipping connectivity checks"
        return 0
    fi

    log "Checking network connectivity..."
    local test_urls=(
        "github.com"
        "download.opensuse.org"
        "get.helm.sh"
    )

    local failed=0
    for url in "${test_urls[@]}"; do
        if ! timeout 5 ping -c 1 "$url" &>/dev/null; then
            log_warning "[WARNING] Cannot reach $url"
            failed=$((failed + 1))
        else
            log_success "[OK] Can reach $url"
        fi
    done

    if ((failed == ${#test_urls[@]})); then
        log_error "[ERROR] No network connectivity detected"
        confirm_override "Continue anyway?" || exit 1
    fi
    return 0
}

# Validate all configuration before starting
validate_all_config() {
    log "Validating configuration..."
    local errors=0

    # Validate IPs
    if [[ -n "$NODE1" ]]; then
        validate_ip "$NODE1" "NODE1" || errors=$((errors + 1))
    fi
    if [[ -n "$NODE2" && $NODES_NUMBER -ge 2 ]]; then
        validate_ip "$NODE2" "NODE2" || errors=$((errors + 1))
    fi
    if [[ -n "$NODE3" && $NODES_NUMBER -ge 3 ]]; then
        validate_ip "$NODE3" "NODE3" || errors=$((errors + 1))
    fi
    if [[ -n "$VIP" ]]; then
        validate_ip "$VIP" "VIP" || errors=$((errors + 1))
    fi

    # Validate ranges and CIDRs
    if [[ -n "$SERVICE_POOL_RANGE" ]]; then
        validate_ip_range "$SERVICE_POOL_RANGE" || errors=$((errors + 1))
    fi
    if [[ -n "$CALICO_IP_POOL" ]]; then
        validate_cidr "$CALICO_IP_POOL" || errors=$((errors + 1))
    fi

    # Validate interface
    if [[ -n "$INTERFACE" ]]; then
        validate_interface "$INTERFACE" || errors=$((errors + 1))
    fi

    # Validate versions
    validate_version "$RKE2_VERSION" "RKE2" || errors=$((errors + 1))
    validate_version "$HELM_VERSION" "Helm" || errors=$((errors + 1))
    validate_version "$METALLB_VERSION" "MetalLB" || errors=$((errors + 1))
    validate_version "$LONGHORN_VERSION" "Longhorn" || errors=$((errors + 1))

    # Validate proxy URLs if proxy is enabled
    if [[ "$USE_PROXY" == "true" ]]; then
        validate_proxy_url "$PROXY" "HTTP_PROXY" || errors=$((errors + 1))
        validate_proxy_url "$HTTPS_PROXY" "HTTPS_PROXY" || errors=$((errors + 1))
    fi

    # Check VIP is in same subnet as nodes
    if [[ $NODES_NUMBER -gt 1 && -n "$VIP" && -n "$NODE1" ]]; then
        local vip_subnet=$(echo "$VIP" | cut -d'.' -f1-3)
        local node1_subnet=$(echo "$NODE1" | cut -d'.' -f1-3)
        if [[ "$vip_subnet" != "$node1_subnet" ]]; then
            log_warning "[WARNING] VIP ($VIP) may not be in same subnet as NODE1 ($NODE1)"
        fi
    fi

    # Check for duplicate IPs (NODE1/NODE2/NODE3/VIP must all be unique)
    if [[ $NODES_NUMBER -ge 3 ]]; then
        if [[ -n "$NODE1" && -n "$NODE2" && "$NODE1" == "$NODE2" ]]; then
            log_error "[ERROR] NODE1 and NODE2 have the same IP: $NODE1"
            errors=$((errors + 1))
        fi
        if [[ -n "$NODE1" && -n "$NODE3" && "$NODE1" == "$NODE3" ]]; then
            log_error "[ERROR] NODE1 and NODE3 have the same IP: $NODE1"
            errors=$((errors + 1))
        fi
        if [[ -n "$NODE2" && -n "$NODE3" && "$NODE2" == "$NODE3" ]]; then
            log_error "[ERROR] NODE2 and NODE3 have the same IP: $NODE2"
            errors=$((errors + 1))
        fi
    fi
    if [[ -n "$VIP" ]]; then
        for node_var in NODE1 NODE2 NODE3; do
            local node_val="${!node_var}"
            if [[ -n "$node_val" && "$VIP" == "$node_val" ]]; then
                log_error "[ERROR] VIP ($VIP) is the same as $node_var ($node_val)"
                errors=$((errors + 1))
            fi
        done
    fi

    if [[ $errors -gt 0 ]]; then
        log_error "[ERROR] Configuration validation failed with $errors error(s)"
        log_error "[ERROR] Please fix the errors in config.env or your inputs"
        exit 1
    fi

    log_success "[OK] All configuration validation passed!"
    return 0
}

# ==================== END INPUT VALIDATION FUNCTIONS ====================

# Print final installation summary
print_final_summary() {
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local formatted_duration=$(format_duration $duration)

    log_console ""
    log_console "${GREEN}================================================${NC}"
    log_console "${GREEN}  INSTALLATION COMPLETED SUCCESSFULLY! ✓${NC}"
    log_console "${GREEN}================================================${NC}"
    log_console ""
    log_console "${GREEN}Cluster Configuration:${NC}"
    if [[ "$NODE_TYPE" == "single" ]]; then
        log_console "  • Type: Single Node Cluster"
    else
        log_console "  • Type: Multi-Node Cluster (Node: $NODE_TYPE)"
    fi
    log_console "  • Node IP: $NODE1"
    if [[ $NODES_NUMBER -gt 1 ]]; then
        log_console "  • Node 2 IP: $NODE2"
        log_console "  • Node 3 IP: $NODE3"
    fi
    log_console "  • VIP: $VIP ($INTERFACE)"
    log_console "  • MetalLB Range: $SERVICE_POOL_RANGE"
    log_console "  • Calico Subnet: $CALICO_IP_POOL"
    log_console ""
    log_console "${GREEN}Installed Components:${NC}"
    log_console "  ✓ RKE2 $RKE2_VERSION"
    log_console "  ✓ Helm $HELM_VERSION"
    log_console "  ✓ Calico $CALICOCTL_VERSION"
    log_console "  ✓ MetalLB $METALLB_VERSION"
    log_console "  ✓ Longhorn $LONGHORN_VERSION"
    log_console "  ✓ Kube-VIP $KUBEVIP_VERSION"
    log_console ""
    log_console "${GREEN}Installation Details:${NC}"
    log_console "  • Total Time: $formatted_duration"
    log_console "  • Log File: $LOG_FILE"
    log_console "  • Mode: $ARGUMENT_TYPE"
    log_console ""
    log_console "${YELLOW}Next Steps:${NC}"
    log_console "  1. Log out and log back in to apply environment settings"
    log_console "  2. Verify cluster: ${GREEN}kubectl get nodes${NC}"
    log_console "  3. Check all pods: ${GREEN}kubectl get pods -A${NC}"
    if [[ "$NODE_TYPE" == "node1" || "$NODE_TYPE" == "node2" ]]; then
        log_console "  4. Continue installation on the next node"
    fi
    log_console "${GREEN}================================================${NC}"
    log_console ""

    # Log summary to file as well
    log_only "========== INSTALLATION SUMMARY =========="
    log_only "Cluster Type: $NODE_TYPE"
    log_only "Total Duration: $formatted_duration"
    log_only "RKE2: $RKE2_VERSION | Helm: $HELM_VERSION | MetalLB: $METALLB_VERSION"
    log_only "Longhorn: $LONGHORN_VERSION | Calico: $CALICOCTL_VERSION | Kube-VIP: $KUBEVIP_VERSION"
    log_only "========================================="
}

# ==================== ARGUMENT PARSING (supports new modes) ====================
# --- CLI spelling ---------------------------------------------------------
# Options are GNU-style long form only: --airgapped, --upgrade, --help, …
# Single-dash spellings are not accepted, so a mistyped "-upgrade" fails
# loudly with the usage hint instead of being silently reinterpreted.
#
# This first pass pulls the global flags out of the argument list, from any
# position, so the positional mode parsing below only ever sees the mode and
# its operand.
_parsed_args=()
for _arg in "$@"; do
    case "$_arg" in
        --dry-run)     DRY_RUN=true ;;
        --interactive) INTERACTIVE=true ;;
        *)             _parsed_args+=("$_arg") ;;
    esac
done
set -- "${_parsed_args[@]}"
unset _parsed_args _arg

# Handle single-argument modes first
if [[ $# -eq 1 ]]; then
    case "$1" in
        --info)            ARGUMENT_TYPE="--info" ;;
        --check)           ARGUMENT_TYPE="--check" ;;
        --help)            ARGUMENT_TYPE="--help" ;;
        --collect)         ARGUMENT_TYPE="--collect" ;;
        --uninstall)       ARGUMENT_TYPE="--uninstall" ;;
        --export-worker-kubeconfig) ARGUMENT_TYPE="--export-worker-kubeconfig" ;;
        --rollback)        ARGUMENT_TYPE="--rollback"; ROLLBACK_TIMESTAMP="latest" ;;
        *)
            log_error "[ERROR] Invalid argument: $1"
            log "[INFO] Usage: $0 --help"
            exit 1
            ;;
    esac
elif [[ $# -eq 2 ]]; then
    case "$1" in
        --airgapped)       ARGUMENT_TYPE="--airgapped"; NODE_TYPE="$2" ;;
        --scale-airgapped) ARGUMENT_TYPE="--scale-airgapped"; NODE_TYPE="$2" ;;
        --import)          ARGUMENT_TYPE="--import"; NODE_TYPE="$2" ;;
        --upgrade)
            ARGUMENT_TYPE="--upgrade"
            UPGRADE_COMPONENT="$2"
            UPGRADE_AIRGAPPED=false
            ;;
        --rollback)
            ARGUMENT_TYPE="--rollback"
            ROLLBACK_TIMESTAMP="$2"
            ;;
        *)
            log_error "[ERROR] Invalid arguments: $1 $2"
            log "[INFO] Usage: $0 --help"
            exit 1
            ;;
    esac
elif [[ $# -eq 3 ]]; then
    case "$1" in
        --import)
            ARGUMENT_TYPE="--import"; NODE_TYPE="$2"; UC_VERSION="$3"
            ;;
        --upgrade)
            ARGUMENT_TYPE="--upgrade"
            UPGRADE_COMPONENT="$2"
            if [[ "$3" == "--airgapped" ]]; then
                UPGRADE_AIRGAPPED=true
            else
                log_error "[ERROR] Invalid third argument for --upgrade: $3 (expected --airgapped)"
                exit 1
            fi
            ;;
        *)
            log_error "[ERROR] Invalid arguments."
            log "[INFO] Usage: $0 --help"
            exit 1
            ;;
    esac
else
    log_error "[ERROR] Invalid number of arguments."
    log "[INFO] Usage: $0 --help"
    exit 1
fi

# Validate -upgrade component argument
if [[ "$ARGUMENT_TYPE" == "--upgrade" ]]; then
    case "$UPGRADE_COMPONENT" in
        rke2|helm|calico|metallb|longhorn|kubevip|all) ;;
        *)
            log_error "[ERROR] Invalid upgrade component: $UPGRADE_COMPONENT"
            log_error "[ERROR] Allowed: rke2, helm, calico, metallb, longhorn, kubevip, all"
            exit 1
            ;;
    esac
fi

# For read-only informational commands, skip system checks and jump to handlers
if [[ "$ARGUMENT_TYPE" == "--help" || "$ARGUMENT_TYPE" == "--check" || "$ARGUMENT_TYPE" == "--info" || "$ARGUMENT_TYPE" == "--collect" || "$ARGUMENT_TYPE" == "--export-worker-kubeconfig" ]]; then
    # These handlers are defined after functions, so we jump there
    # (see "EARLY-EXIT MODE HANDLERS" section near end of script)
    SKIP_SYSTEM_CHECKS=true
else
    SKIP_SYSTEM_CHECKS=false
fi

# Check if the OS is SLES (skip for read-only modes)
if [[ "$SKIP_SYSTEM_CHECKS" != true ]]; then
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "sles" ]]; then
        log_error "[ERROR] This script is intended for SLES systems only. Detected OS: $ID"
        exit 1
    else
        if [[ "$ID" == "sles" ]]; then
            sudo zypper modifyrepo --all --enable 2>/dev/null
        fi
        log "[INFO] SLES OS Detected!"
    fi
else
    log_error "[ERROR] /etc/os-release not found. Unable to determine OS. Exiting."
    exit 1
fi
fi

# Check if the script is run as root or sudoer (skip for read-only modes)
if [[ "$SKIP_SYSTEM_CHECKS" != true ]]; then
if [ "$EUID" -ne 0 ]; then
    log_error "[ERROR] This script must be run as root or with sudo. Exiting."
    exit 1
else
    log "[INFO] Running as root or sudo."
fi
fi

if [[ "$ARGUMENT_TYPE" != "--import" && "$ARGUMENT_TYPE" != "--info" && "$ARGUMENT_TYPE" != "--check" && "$ARGUMENT_TYPE" != "--help" && "$ARGUMENT_TYPE" != "--collect" && "$ARGUMENT_TYPE" != "--export-worker-kubeconfig" && "$ARGUMENT_TYPE" != "--upgrade" && "$ARGUMENT_TYPE" != "--rollback" && "$ARGUMENT_TYPE" != "--uninstall" ]]; then
    # Check if SLES VM has the swap memory disabled and disable it if not
    if [ -f /etc/fstab ]; then
        if grep -q "swap" /etc/fstab; then
            log "[INFO] Swap memory is enabled. Disabling it..."

            # Comment out relevant swap entry in /etc/fstab
            echo "Removing swap entry in /etc/fstab"
            sudo sed -i '/^[^#].*\s\+swap\s\+/ s/^/#/' /etc/fstab

            # Get all swap devices
            swap_devs=$(awk 'NR>1 {print $1}' /proc/swaps)
            swapoff -a

            # Wipe each one of them
            for dev in $swap_devs; do
                if [[ -b $dev || -f $dev ]]; then
                    echo "Wiping swap signature on $dev"
                    sudo wipefs -a "$dev"
                else
                    echo "Skipping invalid device: $dev"
                fi
            done

            log "[INFO] Swap memory disabled."
        else
            log "[INFO] Swap memory is already disabled."
        fi
    else
        log_error "[ERROR] /etc/fstab not found. Unable to check swap memory. Exiting."
    fi

    if [ -f ~/.bashrc ]; then
        . ~/.bashrc
    fi
fi


# Maximum number of worker-only nodes supported by this script.
# Script constant (not read from config.env — argument validation below runs
# before config.env is sourced). Raise it here to support more workers; every
# worker check in the script derives its bounds from this value.
MAX_WORKERS=99

# Returns 0 if $1 is a valid worker node type (worker1..worker$MAX_WORKERS)
is_valid_worker_type() {
    local node_type="$1"
    [[ "$node_type" =~ ^worker([1-9][0-9]*)$ ]] || return 1
    (( BASH_REMATCH[1] >= 1 && BASH_REMATCH[1] <= MAX_WORKERS )) || return 1
    return 0
}

# Deployment profile: single | triple | ha-workers (3 control-plane + N workers).
# Only ha-workers changes behaviour (role-based minimums, master taint, Longhorn
# disks on workers only); single and triple keep their existing settings.
# Evaluated at call time, so NODES_NUMBER/WORKERS_NUMBER come from config.env.
get_deployment_profile() {
    if is_valid_worker_type "$NODE_TYPE"; then
        echo "ha-workers"
    elif [[ "$NODE_TYPE" == "single" || "${NODES_NUMBER:-1}" -lt 3 ]]; then
        echo "single"
    elif [[ "${WORKERS_NUMBER:-0}" =~ ^[0-9]+$ ]] && (( WORKERS_NUMBER >= 1 )); then
        echo "ha-workers"
    else
        echo "triple"
    fi
}

# Node role for the current NODE_TYPE: master | worker
get_node_role() {
    if is_valid_worker_type "$NODE_TYPE"; then echo "worker"; else echo "master"; fi
}

# Validate second argument for install modes (arguments already parsed above)
if [[ "$ARGUMENT_TYPE" == "--airgapped" ]]; then
    if [[ "$NODE_TYPE" != "node1" && "$NODE_TYPE" != "node2" && "$NODE_TYPE" != "node3" && "$NODE_TYPE" != "single" && "$NODE_TYPE" != "stack" ]] && ! is_valid_worker_type "$NODE_TYPE"; then
        log_error "[ERROR] Invalid node type for --airgapped. Allowed: node1, node2, node3, single, worker1-worker${MAX_WORKERS}, stack."
        exit 1
    fi
elif [[ "$ARGUMENT_TYPE" == "--scale-airgapped" ]]; then
    if [[ "$NODE_TYPE" != "node1" && "$NODE_TYPE" != "node2" && "$NODE_TYPE" != "node3" ]] && ! is_valid_worker_type "$NODE_TYPE"; then
        log_error "[ERROR] Invalid node type for --scale-airgapped. Allowed: node1, node2, node3, worker1-worker${MAX_WORKERS}."
        exit 1
    fi
elif [[ "$ARGUMENT_TYPE" == "--import" ]]; then
    if [[ "$NODE_TYPE" != "uc" ]]; then
        log_error "[ERROR] Invalid node type for --import. Only 'uc' is allowed."
        exit 1
    fi
    UC_VERSION="${UC_VERSION:-V11R0.19.0-071900}"
fi

# All validations passed (skip logging for single-arg modes)
if [[ "$ARGUMENT_TYPE" != "--info" && "$ARGUMENT_TYPE" != "--help" && "$ARGUMENT_TYPE" != "--check" && "$ARGUMENT_TYPE" != "--collect" && "$ARGUMENT_TYPE" != "--export-worker-kubeconfig" ]]; then
    log "[INFO] Mode: $ARGUMENT_TYPE"
    [[ -n "$NODE_TYPE" ]] && log "[INFO] Node/App: $NODE_TYPE"
    [[ -n "$UPGRADE_COMPONENT" ]] && log "[INFO] Upgrade Component: $UPGRADE_COMPONENT"
    [[ "$DRY_RUN" == true ]] && log_warning "[INFO] DRY-RUN mode enabled — no changes will be made"
    if [[ "$INTERACTIVE" == true ]]; then
        log "[INFO] Interactive mode enabled — you will be prompted for configuration and confirmations"
    else
        log "[INFO] Unattended mode (default) — no prompts; values come from config.env. Use --interactive to be asked."
    fi
fi

# Print startup banner (skip for info-style, import and uninstall modes)
if [[ "$ARGUMENT_TYPE" != "--import" && "$ARGUMENT_TYPE" != "--info" && "$ARGUMENT_TYPE" != "--help" && "$ARGUMENT_TYPE" != "--check" && "$ARGUMENT_TYPE" != "--collect" && "$ARGUMENT_TYPE" != "--export-worker-kubeconfig" && "$ARGUMENT_TYPE" != "--uninstall" ]]; then
    log_console ""
    log_console "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    log_console "${GREEN}║                                                               ║${NC}"
    log_console "${GREEN}║       Kubernetes Multi-Environment Setup Script v$SCRIPT_VERSION        ║${NC}"
    log_console "${GREEN}║                                                               ║${NC}"
    log_console "${GREEN}║  Automated RKE2, Helm, Calico, MetalLB, Longhorn Deployment   ║${NC}"
    log_console "${GREEN}║                                                               ║${NC}"
    log_console "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    log_console ""
fi

# Log installation start (skip for -info mode)
if [[ "$ARGUMENT_TYPE" != "--info" ]]; then
    log_only "========== INSTALLATION STARTED =========="
    log_only "Mode: $ARGUMENT_TYPE | Node/App: $NODE_TYPE"
    log_only "Start Time: $(date '+%Y-%m-%d %H:%M:%S')"
    log_only "========================================="
fi


# Check if the config.env file exists and source it

# Function to check and convert config.env from DOS to Unix format
check_and_convert_config() {
    local config_file="$CONFIG_FILE_PATH"

    if [ -f "$config_file" ]; then
        [[ "$ARGUMENT_TYPE" != "--info" ]] && log "Checking $config_file for DOS line endings..."

        # Check if the file has DOS line endings (CRLF)
        if file "$config_file" | grep -q "CRLF"; then
            [[ "$ARGUMENT_TYPE" != "--info" ]] && log "DOS line endings detected in $config_file. Converting to Unix format..."

            # Check if dos2unix is installed
            if ! command -v dos2unix >> "$LOG_FILE" 2>&1; then
                log_error "[ERROR] dos2unix is not installed. Exiting."
                exit 1
            fi

            # Convert the file
            capture_output dos2unix "$config_file"
            [[ "$ARGUMENT_TYPE" != "--info" ]] && log "Successfully converted $config_file to Unix format."
        else
            [[ "$ARGUMENT_TYPE" != "--info" ]] && log "$config_file already has Unix line endings. No conversion needed."
        fi
    else
        [[ "$ARGUMENT_TYPE" != "--info" ]] && log_warning "[WARNING] $config_file not found. Will use hardcoded defaults."
    fi
}

# Convert config to unix format (skip for -help which doesn't need config)
if [[ "$ARGUMENT_TYPE" != "--help" ]]; then
    check_and_convert_config 2>/dev/null
fi

# Load config (skip for -help which doesn't need config)
if [[ "$ARGUMENT_TYPE" != "--help" ]]; then
if [ -f "$CONFIG_FILE_PATH" ]; then
    source "$CONFIG_FILE_PATH"
    # Only log for non-read-only modes
    if [[ "$SKIP_SYSTEM_CHECKS" != true ]]; then
        log "[INFO] Loaded configuration from $CONFIG_FILE_PATH"
    fi
else
    if [[ "$SKIP_SYSTEM_CHECKS" != true ]]; then
        log_error "[ERROR] $CONFIG_FILE_PATH not found. Using hardcoded defaults."
    fi
fi
fi

# Function to compare semantic versions (returns 0 if v1 >= v2, 1 otherwise)
version_gte() {
    local v1="${1#v}"  # Remove 'v' prefix if present
    local v2="${2#v}"

    # Strip build metadata (e.g. +rke2r1) before comparison
    v1="${v1%%+*}"
    v2="${v2%%+*}"

    # Split versions into components
    local IFS='.'
    read -ra V1_PARTS <<< "$v1"
    read -ra V2_PARTS <<< "$v2"

    # Compare each component
    for i in 0 1 2; do
        local part1="${V1_PARTS[$i]:-0}"
        local part2="${V2_PARTS[$i]:-0}"

        if (( part1 > part2 )); then
            return 0
        elif (( part1 < part2 )); then
            return 1
        fi
    done
    return 0  # Equal versions
}

# Check config.env version compatibility (skip for -help)
if [[ "$ARGUMENT_TYPE" != "--help" ]]; then
    if [ -z "$VERSION" ]; then
        log_error "[ERROR] config.env is missing VERSION field."
        log_error "[ERROR] Please update your config.env to version $MIN_CONFIG_VERSION or higher."
        log_error "[ERROR] Add 'VERSION=\"v$MIN_CONFIG_VERSION\"' at the top of your config.env file."
        exit 1
    fi

    CONFIG_VERSION="${VERSION#v}"  # Remove 'v' prefix for comparison

    if ! version_gte "$CONFIG_VERSION" "$MIN_CONFIG_VERSION"; then
        log_error "[ERROR] config.env version ($VERSION) is incompatible with this script (v$SCRIPT_VERSION)."
        log_error "[ERROR] Minimum required config.env version: v$MIN_CONFIG_VERSION"
        log_error "[ERROR] Please update your config.env file to version $MIN_CONFIG_VERSION or higher."
        exit 1
    fi

    # Only log version compatibility for non-read-only modes
    if [[ "$SKIP_SYSTEM_CHECKS" != true ]]; then
        log "[INFO] config.env version ($VERSION) is compatible with script v$SCRIPT_VERSION"
    fi
fi

# (SCRIPT_DIR is defined at the top of the script, before LOG_FILE needs it.)

# Resolve the containerd socket path (RKE2/k3s embedded containerd, or standalone containerd).
get_ctr_socket() {
    local sock="/run/k3s/containerd/containerd.sock"
    if [[ ! -S "$sock" ]]; then
        sock="/run/containerd/containerd.sock"
        if [[ ! -S "$sock" ]]; then
            log_error "[ERROR] Containerd socket not found. Is containerd/k3s running?"
            return 1
        fi
    fi
    echo "$sock"
}

# Stage image tar(s) into /var/lib/rancher/rke2/agent/images/<subfolder> and import
# them directly into containerd. We used to copy the tars there and then poll,
# waiting for RKE2's own airgap importer to notice and load them — but that importer
# only scans this directory once, at rke2-server/agent startup. On a node whose RKE2
# has been running for a while (e.g. an --import-only run), it never rescans, so the
# poll just timed out. We still copy into the directory (harmless — a real RKE2
# restart will re-import, no-op, the same content), but import ourselves via
# `ctr images import` so it happens immediately regardless of RKE2's uptime. Since a
# direct `ctr images import` does NOT set the io.cri-containerd.pinned=pinned label
# RKE2's own importer applies automatically, we apply it by hand afterward to protect
# the image from containerd's image GC.
#
# Usage: stage_and_wait_for_import <subfolder> <tar1> [tar2 ...] [-- <ref1> [ref2 ...]]
# If the expected image refs are already known (e.g. UC images: "${target_image}:${VERSION}"),
# pass them after `--` so each imported image can be verified/pinned by that exact ref.
# Otherwise each tar's own manifest.json is read to determine its ref.
stage_and_wait_for_import() {
    local subfolder="$1"; shift
    local dest_dir="/var/lib/rancher/rke2/agent/images/${subfolder}"

    local tars=() refs=() in_refs=0 arg
    for arg in "$@"; do
        if [[ "$arg" == "--" ]]; then
            in_refs=1
            continue
        fi
        if [[ $in_refs -eq 0 ]]; then
            tars+=("$arg")
        else
            refs+=("$arg")
        fi
    done

    if [[ ${#tars[@]} -eq 0 ]]; then
        log "[INFO] No archives to stage for ${subfolder} — nothing to do."
        return 0
    fi

    sudo mkdir -p "$dest_dir"

    log "[INFO] Staging ${#tars[@]} archive(s) into ${dest_dir}..."
    if ! sudo cp "${tars[@]}" "$dest_dir/" >> "$LOG_FILE" 2>&1; then
        log_error "[ERROR] Failed to copy archive(s) into ${dest_dir}"
        return 1
    fi

    local sock
    sock=$(get_ctr_socket) || return 1

    # If the caller didn't already know the refs, read each tar's own manifest.json.
    if [[ ${#refs[@]} -eq 0 ]]; then
        local tar ref
        for tar in "${tars[@]}"; do
            ref=$(tar -xOf "$tar" manifest.json 2>/dev/null | jq -r '.[0].RepoTags[0] // empty' 2>/dev/null)
            [[ -n "$ref" ]] && refs+=("$ref")
        done
    fi

    local tar
    for tar in "${tars[@]}"; do
        log "[INFO] Importing ${tar##*/} into containerd..."
        if ! ctr -n k8s.io --address "$sock" images import "$tar" >> "$LOG_FILE" 2>&1; then
            log_error "[ERROR] Failed to import ${tar##*/} into containerd."
            return 1
        fi
    done

    if [[ ${#refs[@]} -eq 0 ]]; then
        log_warning "[WARN] Could not determine expected image ref(s) for ${subfolder} — imported but not individually verified/pinned."
        return 0
    fi

    # Verify each image landed and pin it against containerd's image GC.
    local ref missing=()
    for ref in "${refs[@]}"; do
        if ! ctr -n k8s.io --address "$sock" images ls "name==${ref}" 2>/dev/null | grep -q "$ref"; then
            missing+=("$ref")
            continue
        fi
        ctr -n k8s.io --address "$sock" images label "$ref" io.cri-containerd.pinned=pinned >> "$LOG_FILE" 2>&1
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warning "[WARN] Import completed but could not verify presence of: ${missing[*]}"
        return 1
    fi

    log_success "[OK] Import confirmed and pinned for ${#refs[@]} image(s) in ${subfolder}"
    return 0
}

# Function to import UC images
import_uc_images() {
    local VERSION="${UC_VERSION:-V11R0.19.0-071900}"

    log "Starting UC images import with version: $VERSION"

    # Check for containerd/ctr availability
    if ! command -v ctr &>/dev/null; then
        log_error "[ERROR] ctr command not found. Please install containerd/k3s first"
        exit 1
    fi

    # Determine containerd socket
    local CTR_SOCKET
    CTR_SOCKET=$(get_ctr_socket) || exit 1

    local ms_count="${MS_COUNT_IMPORT:-1}"
    local TARGET_IMAGES=(
        "docker-airgapped-img.mitel.com/openscape_uc/lwfe"
        "docker-airgapped-img.mitel.com/openscape_uc/mysql"
        "docker-airgapped-img.mitel.com/openscape_uc/of"
        "docker-airgapped-img.mitel.com/openscape_uc/ofmysql"
        "docker-airgapped-img.mitel.com/openscape_uc/uckeycloak"
        "docker-airgapped-img.mitel.com/openscape_uc/be"
    )
    for ((ms_idx=1; ms_idx<=ms_count; ms_idx++)); do
        TARGET_IMAGES+=("docker-airgapped-img.mitel.com/openscape_uc/ms${ms_idx}")
    done

    local combined_tar="k8s-airgapped-files/openscape_uc_images-${VERSION}.tar"
    local combined_tar_gz="k8s-airgapped-files/openscape_uc_images-${VERSION}.tar.gz"
    local combined_tar_alt="k8s-airgapped-files/uc_images_export/openscape_uc_images-${VERSION}.tar"
    local combined_tar_gz_alt="k8s-airgapped-files/uc_images_export/openscape_uc_images-${VERSION}.tar.gz"
    local combined_tar_cwd="openscape_uc_images-${VERSION}.tar"
    local combined_tar_gz_cwd="openscape_uc_images-${VERSION}.tar.gz"
    # RKE2's own image staging directory — images placed here get picked up
    # by RKE2 automatically on service start. Support it as a manual drop-off
    # location too, so a combined archive (or individual tars) copied there
    # by hand is found and imported the same way as the other locations.
    local rke2_images_dir="/var/lib/rancher/rke2/agent/images"
    local combined_tar_rke2="${rke2_images_dir}/openscape_uc_images-${VERSION}.tar"
    local combined_tar_gz_rke2="${rke2_images_dir}/openscape_uc_images-${VERSION}.tar.gz"
    local use_individual_tars=0
    local individual_tar_dir="k8s-airgapped-files/uc_images_export"
    local temp_dir=""

    # Ensure ${UC_TMP_DIR} exists (extraction target on the large /var partition)
    mkdir -p "${UC_TMP_DIR}"
    # Register the potential temp dir for cleanup via global handler (avoids overwriting global traps)
    register_cleanup "${UC_TMP_DIR}/uc_import_${VERSION}"

    # Check if combined tar or tar.gz exists (CWD root, k8s-airgapped-files dir, or uc_images_export subdir)
    if [[ -f "$combined_tar_gz_cwd" ]]; then
        log "Found combined tar.gz file in working directory: $combined_tar_gz_cwd"
        temp_dir="${UC_TMP_DIR}/uc_import_${VERSION}"; mkdir -p "$temp_dir"
        log "Extracting $combined_tar_gz_cwd to $temp_dir (on /var)..."
        if ! run_with_spinner "Extracting UC images archive (this may take several minutes)" tar -xzf "$combined_tar_gz_cwd" -C "$temp_dir"; then
            log_error "[ERROR] Failed to extract $combined_tar_gz_cwd"; exit 1
        fi
        log_success "[OK] Extraction complete: $combined_tar_gz_cwd → $temp_dir"
    elif [[ -f "$combined_tar_cwd" ]]; then
        log "Found combined tar file in working directory: $combined_tar_cwd"
        temp_dir="${UC_TMP_DIR}/uc_import_${VERSION}"; mkdir -p "$temp_dir"
        log "Extracting $combined_tar_cwd to $temp_dir (on /var)..."
        if ! run_with_spinner "Extracting UC images archive (this may take several minutes)" tar -xf "$combined_tar_cwd" -C "$temp_dir"; then
            log_error "[ERROR] Failed to extract $combined_tar_cwd"; exit 1
        fi
        log_success "[OK] Extraction complete: $combined_tar_cwd → $temp_dir"
    elif [[ -f "$combined_tar_gz" ]]; then
        log "Found combined tar.gz file: $combined_tar_gz"
        temp_dir="${UC_TMP_DIR}/uc_import_${VERSION}"; mkdir -p "$temp_dir"
        log "Extracting $combined_tar_gz to $temp_dir (on /var)..."
        if ! run_with_spinner "Extracting UC images archive (this may take several minutes)" tar -xzf "$combined_tar_gz" -C "$temp_dir"; then
            log_error "[ERROR] Failed to extract $combined_tar_gz"; exit 1
        fi
        log_success "[OK] Extraction complete: $combined_tar_gz → $temp_dir"
    elif [[ -f "$combined_tar" ]]; then
        log "Found combined tar file: $combined_tar"
        temp_dir="${UC_TMP_DIR}/uc_import_${VERSION}"; mkdir -p "$temp_dir"
        log "Extracting $combined_tar to $temp_dir (on /var)..."
        if ! run_with_spinner "Extracting UC images archive (this may take several minutes)" tar -xf "$combined_tar" -C "$temp_dir"; then
            log_error "[ERROR] Failed to extract $combined_tar"; exit 1
        fi
        log_success "[OK] Extraction complete: $combined_tar → $temp_dir"
    elif [[ -f "$combined_tar_gz_alt" ]]; then
        log "Found combined tar.gz file: $combined_tar_gz_alt"
        temp_dir="${UC_TMP_DIR}/uc_import_${VERSION}"; mkdir -p "$temp_dir"
        log "Extracting $combined_tar_gz_alt to $temp_dir (on /var)..."
        if ! run_with_spinner "Extracting UC images archive (this may take several minutes)" tar -xzf "$combined_tar_gz_alt" -C "$temp_dir"; then
            log_error "[ERROR] Failed to extract $combined_tar_gz_alt"; exit 1
        fi
        log_success "[OK] Extraction complete: $combined_tar_gz_alt → $temp_dir"
    elif [[ -f "$combined_tar_alt" ]]; then
        log "Found combined tar file: $combined_tar_alt"
        temp_dir="${UC_TMP_DIR}/uc_import_${VERSION}"; mkdir -p "$temp_dir"
        log "Extracting $combined_tar_alt to $temp_dir (on /var)..."
        if ! run_with_spinner "Extracting UC images archive (this may take several minutes)" tar -xf "$combined_tar_alt" -C "$temp_dir"; then
            log_error "[ERROR] Failed to extract $combined_tar_alt"; exit 1
        fi
        log_success "[OK] Extraction complete: $combined_tar_alt → $temp_dir"
    elif [[ -f "$combined_tar_gz_rke2" ]]; then
        log "Found combined tar.gz file manually staged in RKE2 images dir: $combined_tar_gz_rke2"
        temp_dir="${UC_TMP_DIR}/uc_import_${VERSION}"; mkdir -p "$temp_dir"
        log "Extracting $combined_tar_gz_rke2 to $temp_dir (on /var)..."
        if ! run_with_spinner "Extracting UC images archive (this may take several minutes)" tar -xzf "$combined_tar_gz_rke2" -C "$temp_dir"; then
            log_error "[ERROR] Failed to extract $combined_tar_gz_rke2"; exit 1
        fi
        log_success "[OK] Extraction complete: $combined_tar_gz_rke2 → $temp_dir"
    elif [[ -f "$combined_tar_rke2" ]]; then
        log "Found combined tar file manually staged in RKE2 images dir: $combined_tar_rke2"
        temp_dir="${UC_TMP_DIR}/uc_import_${VERSION}"; mkdir -p "$temp_dir"
        log "Extracting $combined_tar_rke2 to $temp_dir (on /var)..."
        if ! run_with_spinner "Extracting UC images archive (this may take several minutes)" tar -xf "$combined_tar_rke2" -C "$temp_dir"; then
            log_error "[ERROR] Failed to extract $combined_tar_rke2"; exit 1
        fi
        log_success "[OK] Extraction complete: $combined_tar_rke2 → $temp_dir"
    elif [[ -d "k8s-airgapped-files/uc_images_export" ]]; then
        log "Combined tar not found, checking for individual tar files in k8s-airgapped-files/uc_images_export/"
        use_individual_tars=1
        individual_tar_dir="k8s-airgapped-files/uc_images_export"
        temp_dir="."

        # Verify at least some individual tar files exist
        local found_count=0
        for i in "${!TARGET_IMAGES[@]}"; do
            local target_image="${TARGET_IMAGES[$i]}"
            local safe_name=$(echo "$target_image" | tr '/:' '_')
            local imgtar="${individual_tar_dir}/${safe_name}-${VERSION}.tar"
            if [[ -f "$imgtar" ]]; then
                ((found_count++))
            fi
        done

        if [[ $found_count -eq 0 ]]; then
            log_error "[ERROR] No individual tar files found in k8s-airgapped-files/uc_images_export/"
            log_error "[ERROR] Please provide either:"
            log_error "        - Combined tar.gz: $combined_tar_gz"
            log_error "        - Combined tar: $combined_tar"
            log_error "        - Individual tars in: k8s-airgapped-files/uc_images_export/"
            exit 1
        fi
        log_success "Found $found_count individual tar file(s)"
    elif compgen -G "${rke2_images_dir}/*-${VERSION}.tar" >/dev/null 2>&1; then
        log "Combined tar not found, checking for individual tar files manually staged in $rke2_images_dir"
        use_individual_tars=1
        individual_tar_dir="$rke2_images_dir"
        temp_dir="."

        # Verify at least some individual tar files exist
        local found_count=0
        for i in "${!TARGET_IMAGES[@]}"; do
            local target_image="${TARGET_IMAGES[$i]}"
            local safe_name=$(echo "$target_image" | tr '/:' '_')
            local imgtar="${individual_tar_dir}/${safe_name}-${VERSION}.tar"
            if [[ -f "$imgtar" ]]; then
                ((found_count++))
            fi
        done

        if [[ $found_count -eq 0 ]]; then
            log_error "[ERROR] No individual tar files found in $rke2_images_dir"
            log_error "[ERROR] Please provide either:"
            log_error "        - Combined tar.gz: $combined_tar_gz_rke2"
            log_error "        - Combined tar: $combined_tar_rke2"
            log_error "        - Individual tars in: $rke2_images_dir"
            exit 1
        fi
        log_success "Found $found_count individual tar file(s)"
    else
        log_error "[ERROR] No UC image files found!"
        log_error "[ERROR] Expected one of:"
        log_error "        - CWD tar.gz: $combined_tar_gz_cwd"
        log_error "        - CWD tar: $combined_tar_cwd"
        log_error "        - Combined tar.gz: $combined_tar_gz"
        log_error "        - Combined tar: $combined_tar"
        log_error "        - Combined tar.gz alt: $combined_tar_gz_alt"
        log_error "        - Combined tar alt: $combined_tar_alt"
        log_error "        - Combined tar.gz in RKE2 images dir: $combined_tar_gz_rke2"
        log_error "        - Combined tar in RKE2 images dir: $combined_tar_rke2"
        log_error "        - Individual tars in: k8s-airgapped-files/uc_images_export/"
        log_error "        - Individual tars in: $rke2_images_dir"
        log_error "[ERROR] Please run the airgapped downloader script first to export UC images"
        exit 1
    fi

    # If we extracted a combined tar, organize the files if needed
    if [[ $use_individual_tars -eq 0 && -n "$temp_dir" ]]; then
        # Check if extraction created uc_images_export subdirectory or extracted directly
        if [[ -d "$temp_dir/uc_images_export" ]]; then
            log "Found uc_images_export directory in extracted content"
        elif ls "$temp_dir"/*.tar >/dev/null 2>&1; then
            # Individual tars extracted directly to temp_dir, move them to uc_images_export structure
            log "Individual tar files extracted directly, organizing..."
            local tar_count=$(ls "$temp_dir"/*.tar 2>/dev/null | wc -l)
            log "Found $tar_count individual tar files"
            mkdir -p "$temp_dir/uc_images_export"
            mv "$temp_dir"/*.tar "$temp_dir/uc_images_export/" 2>/dev/null || true
            log_success "Organized $tar_count tar files into $temp_dir/uc_images_export/"
        else
            log_error "[ERROR] Unexpected structure after extracting combined tar"
            log_error "[ERROR] Expected either uc_images_export/ directory or individual .tar files"
            log_error "[ERROR] Found: $(ls -la "$temp_dir")"
            rm -rf "$temp_dir"
            exit 1
        fi
    fi

    local imported_count=0
    local skipped_count=0
    local missing_count=0

    # Track which images still need to be staged for import
    declare -a import_images=()
    declare -a import_tars=()

    # Phase 1: Check existing images and prepare import jobs
    for i in "${!TARGET_IMAGES[@]}"; do
        local target_image="${TARGET_IMAGES[$i]}"
        local safe_name=$(echo "$target_image" | tr '/:' '_')

        # Set path based on whether using combined or individual tars
        if [[ $use_individual_tars -eq 1 ]]; then
            local imgtar="${individual_tar_dir}/${safe_name}-${VERSION}.tar"
        else
            local imgtar="$temp_dir/uc_images_export/${safe_name}-${VERSION}.tar"
        fi

        # Check if image already exists locally
        if ctr -n k8s.io --address "$CTR_SOCKET" images list | grep -q "$target_image:$VERSION"; then
            log_success "[INFO] Image already exists locally: $target_image:$VERSION - skipping import"
            ((skipped_count++))
            continue
        fi

        if [[ -f "$imgtar" ]]; then
            # Queue for parallel import
            import_images+=("$target_image")
            import_tars+=("$imgtar")
        else
            log_warning "[WARN] Not found: $imgtar - skipping"
            ((missing_count++))
        fi
    done

    # Phase 2: Stage the missing images into RKE2's airgap image directory and wait
    # for RKE2 to import them. RKE2 applies the io.cri-containerd.pinned label itself
    # when it does the import — a direct `ctr images import` never does, which is why
    # UC images previously ended up unprotected from containerd GC.
    if [[ ${#import_images[@]} -gt 0 ]]; then
        log "Found ${#import_images[@]} image(s) to import..."

        local stage_refs=()
        for target_image in "${import_images[@]}"; do
            stage_refs+=("${target_image}:${VERSION}")
        done

        # On an upgrade, drop any previously-staged UC tars for a different
        # version so the images dir only ever holds the current version.
        local uc_stage_dir="/var/lib/rancher/rke2/agent/images/openscape_uc"
        if [[ -d "$uc_stage_dir" ]]; then
            sudo find "$uc_stage_dir" -maxdepth 1 -name '*.tar' ! -name "*-${VERSION}.tar" -print -delete >> "$LOG_FILE" 2>&1
        fi

        if stage_and_wait_for_import "openscape_uc" "${import_tars[@]}" -- "${stage_refs[@]}"; then
            imported_count=$(( imported_count + ${#import_images[@]} ))
        else
            log_error "[ERROR] Failed to import one or more UC images into containerd."
            if [[ $use_individual_tars -eq 0 ]]; then
                rm -rf "$temp_dir"
            fi
            exit 1
        fi
    fi

    # Cleanup temp directory only if we extracted a combined tar
    if [[ $use_individual_tars -eq 0 && -n "$temp_dir" ]]; then
        rm -rf "$temp_dir"
        temp_dir=""
    fi
    # temp dir cleanup handled by global EXIT trap via register_cleanup

    log "UC images import completed: $imported_count imported, $skipped_count already present, $missing_count missing"

    # Check if import was successful
    if [[ $imported_count -eq 0 && $skipped_count -eq 0 && $missing_count -gt 0 ]]; then
        log_error "[ERROR] UC images import FAILED! No images were imported and $missing_count images are missing."
        log_error "[ERROR] Please verify that the UC images were exported correctly."
        log_error "[ERROR] Expected tar files in: k8s-airgapped-files/uc_images_export/"
        exit 1
    elif [[ $missing_count -gt 0 && $imported_count -gt 0 ]]; then
        log_warning "[WARN] UC images import completed with warnings: $missing_count images could not be found."
    elif [[ $imported_count -gt 0 || $skipped_count -gt 0 ]]; then
        log_success "UC images import completed successfully!"

        # Label images (new and pre-existing) for Spegel P2P image distribution
        label_images_for_spegel "$CTR_SOCKET"

        # --- POST-IMPORT: verify images and offer to delete source archive ---
        local verified_count
        verified_count=$(crictl images 2>/dev/null | grep -c "$VERSION" || echo "0")
        local expected_count=$(( imported_count + skipped_count ))

        log "[INFO] Verifying UC images in containerd: expected=$expected_count found=$verified_count (version: $VERSION)"

        if [[ "$verified_count" -ge "$expected_count" && "$expected_count" -gt 0 ]]; then
            log_success "[OK] All $verified_count UC images (version: $VERSION) confirmed in containerd."

            # Verify RKE2 actually pinned every present UC image (defense-in-depth —
            # the stage-and-wait import above relies on RKE2 applying this itself).
            local unpinned_refs=()
            local pin_check_image pin_check_ref pin_check_info
            for pin_check_image in "${TARGET_IMAGES[@]}"; do
                pin_check_ref="${pin_check_image}:${VERSION}"
                pin_check_info=$(ctr -n k8s.io --address "$CTR_SOCKET" images ls "name==${pin_check_ref}" 2>/dev/null)
                [[ -z "$pin_check_info" ]] && continue
                echo "$pin_check_info" | grep -q "io.cri-containerd.pinned=pinned" || unpinned_refs+=("$pin_check_ref")
            done
            if [[ ${#unpinned_refs[@]} -gt 0 ]]; then
                log_warning "[WARN] Present but NOT pinned against containerd GC: ${unpinned_refs[*]}"
            else
                log_success "[OK] All present UC images are pinned against containerd GC."
            fi

            # Find which source file was used (same search order as import)
            local source_file=""
            local source_size=""
            for candidate in "$combined_tar_gz_cwd" "$combined_tar_cwd" "$combined_tar_gz" "$combined_tar" "$combined_tar_gz_alt" "$combined_tar_alt" "$combined_tar_gz_rke2" "$combined_tar_rke2"; do
                if [[ -f "$candidate" ]]; then
                    source_file="$candidate"
                    source_size=$(du -sh "$candidate" 2>/dev/null | awk '{print $1}')
                    break
                fi
            done

            if [[ -n "$source_file" ]]; then
                local answer=""
                if [[ "$INTERACTIVE" == true && -t 0 ]]; then
                    echo ""
                    echo "┌──────────────────────────────────────────────────────────────────────────┐"
                    echo "│  CLEANUP: Delete source UC image archive?                                │"
                    echo "│                                                                          │"
                    printf "│  File : %-65s│\n" "$source_file"
                    printf "│  Size : %-65s│\n" "$source_size"
                    echo "│                                                                          │"
                    echo "│  All UC images are confirmed imported into containerd.                   │"
                    echo "│  The source archive is no longer needed and can be safely removed.       │"
                    echo "│                                                                          │"
                    printf "│  To delete manually later, run:                                          │\n"
                    printf "│    rm -f %-64s│\n" "$source_file"
                    echo "│                                                                          │"
                    echo "│  Auto-No (keep file) in 30 seconds.                                      │"
                    echo "└──────────────────────────────────────────────────────────────────────────┘"
                    read -r -t 30 -p "  Delete source archive to free ${source_size}? [y/N]: " answer || answer="N"
                    echo ""
                else
                    answer="N"
                    log "[INFO] Non-interactive run — keeping source archive (default: No)."
                fi

                case "${answer,,}" in
                    y|yes)
                        log "[INFO] Deleting source archive: $source_file..."
                        if rm -f "$source_file"; then
                            log_success "[OK] Deleted $source_file — ${source_size} freed."
                        else
                            log_error "[ERROR] Failed to delete $source_file — please remove manually."
                        fi
                        ;;
                    *)
                        log "[INFO] Keeping source archive: $source_file — no changes made."
                        ;;
                esac
            else
                log "[INFO] Source archive not found in any expected location — nothing to clean up."
            fi
        else
            log_warning "[WARN] Image count mismatch — expected=$expected_count found=$verified_count."
            log_warning "[WARN] Keeping source archive until all images are confirmed."
        fi
        # --- END POST-IMPORT CLEANUP ---
    fi
}

# Function to label images in the containerd content store with
# containerd.io/distribution.source.<host>=<repo> labels so Spegel
# (P2P image mirroring) can identify and share them between nodes.
# Safe to call repeatedly: already-labeled content is skipped.
label_images_for_spegel() {
    local ctr_socket="$1"
    local ns="k8s.io"

    if ! command -v jq &>/dev/null; then
        log "[INFO] jq not found — installing before labeling images for Spegel..."
        if ! install_jq_airgapped; then
            log_warning "[WARN] Could not install jq — skipping Spegel image labeling."
            return 0
        fi
    fi

    log "Labeling imported images for Spegel P2P distribution..."

    label_one() {
        ctr -n "$ns" --address "$ctr_socket" content label "$1" "containerd.io/distribution.source.${2}=${3}" >/dev/null
    }

    is_labeled() {
        ctr -n "$ns" --address "$ctr_socket" content ls | awk -v d="$1" '$1==d' | grep -q "distribution.source"
    }

    digest_of() {
        ctr -n "$ns" --address "$ctr_socket" images ls "name==${1}" | grep -oE 'sha256:[0-9a-f]{64}' | head -1
    }

    split_ref() {
        local name="$1"
        local first="${name%%/*}"
        if [[ "$name" != */* ]]; then
            echo "docker.io library/${name}"
        elif [[ "$first" == *.* || "$first" == *:* || "$first" == "localhost" ]]; then
            echo "$first ${name#*/}"
        else
            echo "docker.io ${name}"
        fi
    }

    walk_and_label() {
        local digest="$1" host="$2" repo="$3"
        label_one "$digest" "$host" "$repo"
        local media
        media=$(ctr -n "$ns" --address "$ctr_socket" content get "$digest" | jq -r '.mediaType // empty')
        case "$media" in
            *manifest.list*|*image.index*)
                for child in $(ctr -n "$ns" --address "$ctr_socket" content get "$digest" | jq -r '.manifests[].digest'); do
                    walk_and_label "$child" "$host" "$repo"
                done
                ;;
            *manifest*)
                ctr -n "$ns" --address "$ctr_socket" content get "$digest" | jq -r '.config.digest, (.layers[].digest)' \
                    | while read -r d; do label_one "$d" "$host" "$repo"; done
                ;;
        esac
    }

    local fixed=0 already_ok=0 ref
    for ref in $(ctr -n "$ns" --address "$ctr_socket" images ls -q); do
        [[ "$ref" == *"@sha256:"* ]] && continue

        local manifest_digest
        manifest_digest=$(digest_of "$ref")
        [[ -z "$manifest_digest" ]] && continue

        if is_labeled "$manifest_digest"; then
            ((already_ok++))
            continue
        fi

        local prefix="${ref%/*}" last="${ref##*/}"
        local last_name="${last%%:*}"
        local name_no_tag
        if [[ "$ref" == */* ]]; then name_no_tag="${prefix}/${last_name}"; else name_no_tag="${last_name}"; fi

        local host repo
        read -r host repo <<< "$(split_ref "$name_no_tag")"

        log "[INFO] Labeling for Spegel: $ref (host=$host repo=$repo)"
        ctr -n "$ns" --address "$ctr_socket" images tag --force "$ref" "${name_no_tag}@${manifest_digest}" >/dev/null
        walk_and_label "$manifest_digest" "$host" "$repo"
        ((fixed++))
    done

    log_success "[OK] Spegel labeling done — labeled: $fixed, already labeled: $already_ok"
}

# Function to offer cleanup of extracted airgapped installer files after successful installation
offer_airgapped_cleanup() {
    local base_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    local container_images_dir="${base_dir}/k8s-airgapped-files/container-images"
    local airgapped_dir="${base_dir}/k8s-airgapped-files"

    # Collect what actually exists
    local candidates=()
    [[ -d "$container_images_dir" ]] && candidates+=("$container_images_dir")
    [[ -d "$airgapped_dir" ]]        && candidates+=("$airgapped_dir")

    if [[ ${#candidates[@]} -eq 0 ]]; then
        log "[INFO] No extracted airgapped directories found — nothing to clean up."
        return 0
    fi

    # Non-interactive: skip silently
    if [[ "$INTERACTIVE" != true || ! -t 0 ]]; then
        log "[INFO] Non-interactive run — keeping extracted airgapped files (default: No)."
        return 0
    fi

    # Calculate combined size
    local total_size
    total_size=$(du -sh "${candidates[@]}" 2>/dev/null | awk '{s=$1} END{print s}')

    echo ""
    echo "┌──────────────────────────────────────────────────────────────────────────┐"
    echo "│  CLEANUP: Delete extracted airgapped installer files?                    │"
    echo "│                                                                          │"
    echo "│  The following extracted directories are no longer needed after          │"
    echo "│  a successful installation. Source archives (.tar/.tar.gz) are kept      │"
    echo "│  intact for use on other nodes.                                          │"
    echo "│                                                                          │"
    for d in "${candidates[@]}"; do
        local d_size
        d_size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        printf "│  %-68s│\n" "${d}  (${d_size})"
    done
    echo "│                                                                          │"
    printf "│  Combined size to free : %-48s│\n" "${total_size}"
    echo "│                                                                          │"
    echo "│  To delete manually later, run:                                          │"
    for d in "${candidates[@]}"; do
        printf "│    rm -rf %-60s│\n" "${d}"
    done
    echo "│                                                                          │"
    echo "│  Auto-No (keep files) in 30 seconds.                                     │"
    echo "└──────────────────────────────────────────────────────────────────────────┘"
    local answer
    read -r -t 30 -p "  Delete extracted airgapped directories to free ${total_size}? [y/N]: " answer || answer="N"
    echo ""

    case "${answer,,}" in
        y|yes)
            for d in "${candidates[@]}"; do
                local d_size
                d_size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
                log "[INFO] Deleting: $d ..."
                if rm -rf "$d"; then
                    log_success "[OK] Deleted ${d} — ${d_size} freed."
                else
                    log_error "[ERROR] Failed to delete ${d} — please remove manually."
                fi
            done
            ;;
        *)
            log "[INFO] Keeping extracted airgapped directories — no changes made."
            ;;
    esac
}

# Set config file path variable
CONFIG_FILE_PATH="$(dirname "$0")/config.env"
PROXY="${PROXY:-http://172.29.38.124:8080/}"
HTTPS_PROXY="${HTTPS_PROXY:-http://172.29.38.124:8080/}"
FTP_PROXY="${HTTPS_PROXY:-http://172.29.38.124:8080/}"
NO_PROXY="${NO_PROXY:-127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local,.ngtc-test.uccinnovations.net,10.42.0.0/16,10.43.0.0/16}"
USE_PROXY="${USE_PROXY:-false}"

RKE2_VERSION="${RKE2_VERSION:-1.30.8+rke2r1}"
HELM_VERSION="${HELM_VERSION:-3.16.1}"
CALICOCTL_VERSION="${CALICOCTL_VERSION:-3.29.1}"
METALLB_VERSION="${METALLB_VERSION:-0.14.8}"
LONGHORN_VERSION="${LONGHORN_VERSION:-1.7.2}"
KUBEVIP_VERSION="${KUBEVIP_VERSION:-0.8.10}"

# Calico and MetalLB configurations
SERVICE_POOL_RANGE="${SERVICE_POOL_RANGE:-10.11.248.170-10.11.248.190}"
CALICO_IP_POOL="${CALICO_IP_POOL:-10.11.248.128/25}"
VIP="${VIP:-10.11.248.169}"
INTERFACE="${INTERFACE:-eth0}"
NODES_NUMBER="${NODES_NUMBER:-1}"

# Worker node configuration (0 = no workers, 1-8 = number of worker-only nodes)
# The upper bound is MAX_WORKERS, defined near the top of this script.
WORKERS_NUMBER="${WORKERS_NUMBER:-0}"
WORKER1="${WORKER1:-}"
WORKER2="${WORKER2:-}"
WORKER3="${WORKER3:-}"
WORKER4="${WORKER4:-}"
WORKER5="${WORKER5:-}"
WORKER6="${WORKER6:-}"
WORKER7="${WORKER7:-}"
WORKER8="${WORKER8:-}"

# Performance Optimizations
# Set to true in config.env to apply noatime on all XFS partitions (reduces I/O overhead)
OPTIMIZE_FILESYSTEM="${OPTIMIZE_FILESYSTEM:-false}"

# Calico encapsulation mode: Always (default, full VXLAN), CrossSubnet (no encap on same L2), Never (native routing)
CALICO_ENCAP_MODE="${CALICO_ENCAP_MODE:-CrossSubnet}"
# Calico/pod MTU: physical MTU minus VXLAN overhead (50 bytes). Set to 0 for auto-detect.
CALICO_MTU="${CALICO_MTU:-1450}"

# Longhorn guaranteed instance manager CPU percentage (single-node: 8, multi-node: 12)
LONGHORN_INSTANCE_MANAGER_CPU="${LONGHORN_INSTANCE_MANAGER_CPU:-}"

# Get current installed version of a component (defined early for -info mode)
get_current_version() {
    local component="$1"
    local version=""

    case "$component" in
        rke2)
            # Check the local node specifically — RKE2 is upgraded per-node, so in a
            # multi-node cluster mid-rollout the nodes can be at different versions.
            # kubectl get nodes' item order is not guaranteed to put the local node first.
            local node_name
            node_name=$(hostname 2>/dev/null)
            if command -v kubectl &>/dev/null; then
                version=$(kubectl get node "$node_name" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null)
            fi
            if [[ -z "$version" ]] && command -v rke2 &>/dev/null; then
                version=$(rke2 --version 2>/dev/null | head -1 | sed -n 's/.*\(v[0-9]*\.[0-9]*\.[0-9]*+rke2r[0-9]*\).*/\1/p')
            fi
            [[ -z "$version" ]] && version="unknown"
            ;;
        helm)
            if command -v helm &>/dev/null; then
                version=$(helm version --short 2>/dev/null | sed -n 's/.*\(v[0-9]*\.[0-9]*\.[0-9]*\).*/\1/p')
            fi
            [[ -z "$version" ]] && version="unknown"
            ;;
        metallb)
            version=$(kubectl get deployment -n metallb-system controller -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed -n 's/.*:\(v[0-9]*\.[0-9]*\.[0-9]*\).*/\1/p')
            [[ -z "$version" ]] && version="unknown"
            ;;
        longhorn)
            # Longhorn manager is a DaemonSet, not a Deployment
            version=$(kubectl get daemonset -n longhorn-system longhorn-manager -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed -n 's/.*:\(v[0-9]*\.[0-9]*\.[0-9]*\).*/\1/p')
            # Fallback: try getting from any longhorn-manager pod
            if [[ -z "$version" || "$version" == "unknown" ]]; then
                version=$(kubectl get pods -n longhorn-system -l app=longhorn-manager -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null | sed -n 's/.*:\(v[0-9]*\.[0-9]*\.[0-9]*\).*/\1/p')
            fi
            [[ -z "$version" ]] && version="unknown"
            ;;
        calico)
            if command -v calicoctl &>/dev/null; then
                version=$(calicoctl version 2>/dev/null | grep "Client Version" | awk '{print $3}')
            fi
            [[ -z "$version" ]] && version="unknown"
            ;;
        kubevip)
            # Kube-VIP runs as a DaemonSet with name kube-vip-ds
            version=$(kubectl get daemonset -n kube-system kube-vip-ds -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed -n 's/.*:\(v[0-9]*\.[0-9]*\.[0-9]*\).*/\1/p')
            # Fallback: try getting from any kube-vip pod
            if [[ -z "$version" || "$version" == "unknown" ]]; then
                version=$(kubectl get pods -n kube-system -l name=kube-vip -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null | sed -n 's/.*:\(v[0-9]*\.[0-9]*\.[0-9]*\).*/\1/p')
            fi
            # Another fallback: try pod name pattern
            if [[ -z "$version" || "$version" == "unknown" ]]; then
                version=$(kubectl get pods -n kube-system --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[0].image}{"\n"}{end}' 2>/dev/null | grep "kube-vip" | head -1 | awk '{print $2}' | sed -n 's/.*:\(v[0-9]*\.[0-9]*\.[0-9]*\).*/\1/p')
            fi
            [[ -z "$version" ]] && version="unknown"
            ;;
    esac

    echo "$version"
}

# Display cluster component version information (defined early for -info mode)
show_cluster_info() {
    log_console ""
    log_console "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    log_console "${GREEN}║                                                               ║${NC}"
    log_console "${GREEN}║              KUBERNETES CLUSTER INFORMATION                   ║${NC}"
    log_console "${GREEN}║                                                               ║${NC}"
    log_console "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    log_console ""

    # Check if kubectl is available
    if ! command -v kubectl &>/dev/null; then
        log_error "[ERROR] kubectl not found. Is Kubernetes installed?"
        exit 1
    fi

    # Check cluster connectivity
    if ! kubectl get nodes &>/dev/null 2>&1; then
        log_error "[ERROR] Cannot connect to Kubernetes cluster. Check kubeconfig."
        exit 1
    fi

    log_console "${YELLOW}Script Configuration:${NC}"
    log_console "  • Script Version:     ${GREEN}v$SCRIPT_VERSION${NC}"
    log_console "  • RKE2 Target:        ${GREEN}$RKE2_VERSION${NC}"
    log_console "  • Helm Target:        ${GREEN}$HELM_VERSION${NC}"
    log_console "  • MetalLB Target:     ${GREEN}$METALLB_VERSION${NC}"
    log_console "  • Longhorn Target:    ${GREEN}$LONGHORN_VERSION${NC}"
    log_console "  • Calico Target:      ${GREEN}$CALICOCTL_VERSION${NC}"
    log_console "  • Kube-VIP Target:    ${GREEN}$KUBEVIP_VERSION${NC}"
    log_console ""

    log_console "${YELLOW}Installed Versions:${NC}"

    # Get installed versions in parallel for faster response
    local max_parallel_checks="${MAX_PARALLEL_VERSION_CHECKS:-6}"
    declare -a version_tasks=("rke2" "helm" "metallb" "longhorn" "calico" "kubevip")
    declare -a version_files=()
    declare -a version_pids=()

    mkdir -p "${UC_TMP_DIR}" 2>/dev/null

    # Launch parallel version checks
    for comp in "${version_tasks[@]}"; do
        local temp_file="${UC_TMP_DIR}/version_${comp}_$$.txt"
        version_files+=("$temp_file")
        ( get_current_version "$comp" > "$temp_file" 2>&1 ) &
        version_pids+=($!)
    done

    # Wait for all version checks to complete
    for pid in "${version_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Read results from temp files
    local rke2_ver=$(cat "${version_files[0]}" 2>/dev/null || echo "unknown")
    local helm_ver=$(cat "${version_files[1]}" 2>/dev/null || echo "unknown")
    local metallb_ver=$(cat "${version_files[2]}" 2>/dev/null || echo "unknown")
    local longhorn_ver=$(cat "${version_files[3]}" 2>/dev/null || echo "unknown")
    local calico_ver=$(cat "${version_files[4]}" 2>/dev/null || echo "unknown")
    local kubevip_ver=$(cat "${version_files[5]}" 2>/dev/null || echo "unknown")

    # Cleanup temp files
    rm -f "${version_files[@]}" 2>/dev/null

    # Display with status indicators
    [[ -z "$rke2_ver" || "$rke2_ver" == "unknown" ]] && rke2_status="${RED}Not Installed${NC}" || rke2_status="${GREEN}$rke2_ver${NC}"
    [[ -z "$helm_ver" || "$helm_ver" == "unknown" ]] && helm_status="${RED}Not Installed${NC}" || helm_status="${GREEN}$helm_ver${NC}"
    [[ -z "$metallb_ver" || "$metallb_ver" == "unknown" ]] && metallb_status="${RED}Not Installed${NC}" || metallb_status="${GREEN}$metallb_ver${NC}"
    [[ -z "$longhorn_ver" || "$longhorn_ver" == "unknown" ]] && longhorn_status="${RED}Not Installed${NC}" || longhorn_status="${GREEN}$longhorn_ver${NC}"
    [[ -z "$calico_ver" || "$calico_ver" == "unknown" ]] && calico_status="${RED}Not Installed${NC}" || calico_status="${GREEN}$calico_ver${NC}"
    [[ -z "$kubevip_ver" || "$kubevip_ver" == "unknown" ]] && kubevip_status="${RED}Not Installed${NC}" || kubevip_status="${GREEN}$kubevip_ver${NC}"

    log_console "  • RKE2:               $rke2_status"
    log_console "  • Helm:               $helm_status"
    log_console "  • MetalLB:            $metallb_status"
    log_console "  • Longhorn:           $longhorn_status"
    log_console "  • Calico (calicoctl): $calico_status"
    log_console "  • Kube-VIP:           $kubevip_status"
    log_console ""

    log_console "${YELLOW}Cluster Nodes:${NC}"
    kubectl get nodes -o wide 2>/dev/null | while read -r line; do
        log_console "  $line"
    done
    log_console ""

    log_console "${YELLOW}System Namespaces:${NC}"
    local namespaces=("kube-system" "metallb-system" "longhorn-system" "calico-system")
    for ns in "${namespaces[@]}"; do
        local pod_count=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
        local running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        if [[ $pod_count -gt 0 ]]; then
            log_console "  • $ns: ${GREEN}$running/$pod_count pods running${NC}"
        else
            log_console "  • $ns: ${RED}No pods found${NC}"
        fi
    done
    log_console ""

    log_console "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    log_console ""
}

# Handle -info mode early (skip all prompts and go directly to info display)
if [[ "$ARGUMENT_TYPE" == "--info" ]]; then
    show_cluster_info
    exit 0
fi

# NOTE: -help, -check, -collect, -upgrade, -rollback, -export-worker-kubeconfig
# are handled after all functions are defined (just before main). Skip user
# prompts for these modes.

# Skip user prompts and configuration for information/utility modes
if [[ "$ARGUMENT_TYPE" != "--help" && "$ARGUMENT_TYPE" != "--check" \
   && "$ARGUMENT_TYPE" != "--collect" && "$ARGUMENT_TYPE" != "--upgrade" \
   && "$ARGUMENT_TYPE" != "--export-worker-kubeconfig" \
   && "$ARGUMENT_TYPE" != "--rollback" && "$ARGUMENT_TYPE" != "--uninstall" ]]; then

# User prompts for confirmation
log "[INFO] You are about to set up $NODE_TYPE with RKE2, Calico CNI, MetalLB, and Longhorn! Please confirm."

if [[ "$ARGUMENT_TYPE" == "--import" && "$NODE_TYPE" == "uc" ]]; then
    UC_VERSION="${UC_VERSION:-V11R0.19.0-071900}"
    log "[INFO] UC Version: $UC_VERSION"
fi

# If airgapped mode is selected, skip the proxy setup
if [[ "$ARGUMENT_TYPE" != "--import" ]]; then
    if [[ "$ARGUMENT_TYPE" == "--airgapped" ]]; then
        log "Airgapped mode selected. Skipping proxy setup."
    else
        log "Configuring Proxy Settings..."
        if [[ "$INTERACTIVE" == true ]]; then
            read -r -p "Do you have a proxy in your environment? (Y/N) [Y]: " USE_PROXY_INPUT
            USE_PROXY_INPUT=${USE_PROXY_INPUT:-Y}
        else
            # Unattended: USE_PROXY from config.env decides. There is no safe
            # way to guess this, so the configured value wins outright.
            if [[ "$USE_PROXY" == true ]]; then USE_PROXY_INPUT="Y"; else USE_PROXY_INPUT="N"; fi
            log "[INFO] Unattended run — using USE_PROXY=$USE_PROXY from config.env."
        fi
    fi
fi

# Check if user chose "Y" for proxy
if [[ "$ARGUMENT_TYPE" != "--import" ]]; then
    if [[ "$USE_PROXY_INPUT" =~ ^[Yy]$ ]]; then
        USE_PROXY=true
        [[ "$INTERACTIVE" == true ]] && log "Note: Press enter if the default value is correct!"
        ask_value PROXY       "Enter HTTP Proxy"
        ask_value HTTPS_PROXY "Enter HTTPS Proxy"
        ask_value FTP_PROXY   "Enter FTP Proxy"
        ask_value NO_PROXY    "Enter NO Proxy (Comma seperated)"
        log "Proxy settings configured."
    else
        USE_PROXY=false
        log "No proxy selected. Skipping proxy configuration."
    fi
fi

if [[ "$ARGUMENT_TYPE" != "--import" ]]; then
    ask_value SERVICE_POOL_RANGE "Enter IP Pool Range for MetalLB"
    ask_value CALICO_IP_POOL     "Enter Subnet for Calico"

    ask_value VIP          "Enter the VIP"
    ask_value INTERFACE    "Enter the Network Interface to bind the VIP"
    ask_value NODES_NUMBER "Enter the Number of CONTROL-PLANE Nodes (1=single, 3=HA cluster — workers are configured separately via WORKERS_NUMBER)"

    if [[ "$NODE_TYPE" == "single" && $NODES_NUMBER -gt 1 ]]; then
        log_error "[ERROR] The number of nodes should be 1 for a single node setup."
        exit 1
    fi
    if [[ ("$NODE_TYPE" == "node1" || "$NODE_TYPE" == "node2" || "$NODE_TYPE" == "node3") && $NODES_NUMBER -lt 3 ]]; then
        log_error "[ERROR] The number of nodes should be 3 for a three-node setup."
        exit 1
    fi

    # Validate worker node configuration
    if [[ ! "$WORKERS_NUMBER" =~ ^[0-9]+$ ]]; then
        log_error "[ERROR] WORKERS_NUMBER ('$WORKERS_NUMBER') must be a number between 0 and $MAX_WORKERS."
        exit 1
    fi
    if [[ $WORKERS_NUMBER -gt $MAX_WORKERS ]]; then
        log_error "[ERROR] WORKERS_NUMBER ($WORKERS_NUMBER) exceeds the maximum supported workers ($MAX_WORKERS)."
        log_error "[ERROR] Lower WORKERS_NUMBER in config.env, or raise MAX_WORKERS at the top of this script."
        exit 1
    fi
    if is_valid_worker_type "$NODE_TYPE"; then
        worker_num="${NODE_TYPE//worker/}"
        if [[ $WORKERS_NUMBER -lt $worker_num ]]; then
            log_error "[ERROR] WORKERS_NUMBER ($WORKERS_NUMBER) is less than requested worker$worker_num. Set WORKERS_NUMBER >= $worker_num in config.env."
            exit 1
        fi
        worker_var="WORKER${worker_num}"
        if [[ -z "${!worker_var}" ]]; then
            log_error "[ERROR] $worker_var IP address is not set in config.env."
            exit 1
        fi
    fi
    # "--airgapped stack" is the final step of a 3 masters + workers install only;
    # single and triple installs keep installing the stack on node3/single.
    if [[ "$NODE_TYPE" == "stack" ]] && (( NODES_NUMBER < 3 || WORKERS_NUMBER < 1 )); then
        log_error "[ERROR] '--airgapped stack' is only for 3 masters + workers (NODES_NUMBER=3, WORKERS_NUMBER>=1)."
        log_error "[ERROR] Single-node and 3-node installs already install the stack (on 'single' / 'node3')."
        exit 1
    fi

    # Prompt for Node IPs based on cluster size
    if [[ $NODES_NUMBER -eq 1 ]]; then
        ask_value NODE1 "Enter Node 1 IP address"
    elif [[ $NODES_NUMBER -ge 3 ]]; then
        ask_value NODE1 "Enter Node 1 IP address"
        ask_value NODE2 "Enter Node 2 IP address"
        ask_value NODE3 "Enter Node 3 IP address"
    fi

    # Prompt for Worker IPs if workers are configured
    if [[ $WORKERS_NUMBER -ge 1 ]]; then
        for ((w=1; w<=WORKERS_NUMBER; w++)); do
            ask_value "WORKER${w}" "Enter Worker $w IP address"
        done
    fi

    if [[ "$ARGUMENT_TYPE" == "--airgapped" ]]; then
        log "Airgapped mode selected. Skipping AWS CLI setup."
        INSTALL_AWS_CLI=${INSTALL_AWS_CLI:-N}
    else
        if [[ "$NODE_TYPE" == "node3" || "$NODE_TYPE" == "single" ]]; then
            ask_yes_no INSTALL_AWS_CLI "Do you really want to install AWS CLI?" "Y"
        fi
    fi

    if [[ "$NODE_TYPE" == "node3" || "$NODE_TYPE" == "single" ]]; then
        ask_yes_no INSTALL_COMPLETION "Do you want to install Kubectl Alias and Bash Completion ?" "Y"
    fi
fi

check_node_ip() {
    if [[ "$NODE_TYPE" == "node1" || "$NODE_TYPE" == "single" ]]; then
        CURRENT_IP=$(hostname -I | awk '{print $1}')
        if [[ "$CURRENT_IP" != "$NODE1"  ]]; then
            log_error "[ERROR] The current VM IP $CURRENT_IP is not in the NODE1 IP $NODE1. Please check your config.env file."
            exit 1
        fi
    fi

    if [[ "$NODE_TYPE" == "node2" ]]; then
        CURRENT_IP=$(hostname -I | awk '{print $1}')
        if [[ "$CURRENT_IP" != "$NODE2"  ]]; then
            log_error "[ERROR] The current VM IP $CURRENT_IP is not in the NODE2 IP $NODE2. Please check your config.env file."
            exit 1
        fi
        # Check if token is set
        if [[ -z "$TOKEN" ]]; then
            log_error "[ERROR] TOKEN must be set in config.env for node2."
            exit 1
        fi
    fi

    if [[ "$NODE_TYPE" == "node3" ]]; then
        CURRENT_IP=$(hostname -I | awk '{print $1}')
        if [[ "$CURRENT_IP" != "$NODE3"  ]]; then
            log_error "[ERROR] The current VM IP $CURRENT_IP is not in the NODE3 IP $NODE3. Please check your config.env file."
            exit 1
        fi
        # Check if token is set
        if [[ -z "$TOKEN" ]]; then
            log_error "[ERROR] TOKEN must be set in config.env for node3."
            exit 1
        fi
    fi

    # Validate worker node IP and prerequisites
    if is_valid_worker_type "$NODE_TYPE"; then
        local worker_num="${NODE_TYPE//worker/}"
        local worker_var="WORKER${worker_num}"
        local expected_ip="${!worker_var}"
        CURRENT_IP=$(hostname -I | awk '{print $1}')
        if [[ "$CURRENT_IP" != "$expected_ip" ]]; then
            log_error "[ERROR] The current VM IP $CURRENT_IP does not match $worker_var IP $expected_ip. Please check your config.env file."
            exit 1
        fi
        # Workers must have TOKEN and VIP to join the cluster
        if [[ -z "$TOKEN" ]]; then
            log_error "[ERROR] TOKEN must be set in config.env for $NODE_TYPE. Get it from the master node: cat /var/lib/rancher/rke2/server/node-token"
            exit 1
        fi
        if [[ -z "$VIP" ]]; then
            log_error "[ERROR] VIP must be set in config.env for $NODE_TYPE."
            exit 1
        fi
    fi
}

# Check NTP time synchronization
check_ntp_sync() {
    log "Checking NTP time synchronization..."
    local synced="unknown"
    # Try timedatectl first (systemd)
    if command -v timedatectl &>/dev/null; then
        synced=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "unknown")
    fi
    # Fallback to chronyc
    if [[ "$synced" == "unknown" ]] && command -v chronyc &>/dev/null; then
        if chronyc tracking 2>/dev/null | grep -q "Leap status.*Normal"; then
            synced="yes"
        else
            synced="no"
        fi
    fi
    case "$synced" in
        yes)
            log_success "[OK] NTP time is synchronized"
            ;;
        no)
            log_warning "[WARNING] NTP time is NOT synchronized."
            log_warning "[WARNING] Clock skew can break TLS certificates and etcd consensus."
            log_warning "[WARNING] Consider running: timedatectl set-ntp true"
            ;;
        *)
            log_warning "[WARNING] Could not determine NTP sync status (airgapped environment?)."
            ;;
    esac
}

# Check DNS resolution
check_dns_resolution() {
    log "Checking DNS resolution..."
    local warnings=0
    # Test localhost resolution
    if ! getent hosts localhost &>/dev/null; then
        log_warning "[WARNING] Cannot resolve 'localhost' — check /etc/hosts"
        warnings=$((warnings + 1))
    fi
    # Test hostname resolution
    local hostname_val
    hostname_val=$(hostname 2>/dev/null)
    if [[ -n "$hostname_val" ]] && ! getent hosts "$hostname_val" &>/dev/null; then
        log_warning "[WARNING] Cannot resolve hostname '$hostname_val' — add it to /etc/hosts"
        warnings=$((warnings + 1))
    fi
    # Test external DNS (online mode only)
    if [[ "$ARGUMENT_TYPE" != "--airgapped" && "$ARGUMENT_TYPE" != "--scale-airgapped" ]]; then
        if ! nslookup github.com &>/dev/null 2>&1; then
            log_warning "[WARNING] Cannot resolve external DNS (github.com) — check DNS settings"
            warnings=$((warnings + 1))
        fi
    fi
    if [[ $warnings -eq 0 ]]; then
        log_success "[OK] DNS resolution checks passed"
    fi
}

# Check for port conflicts on required K8s ports
check_required_ports() {
    log "Checking for port conflicts on required K8s ports..."
    local warnings=0
    # TCP ports: 6443 (API), 9345 (RKE2 join), 10250 (kubelet), 2379-2380 (etcd), 179 (BGP/Calico)
    local tcp_ports=(6443 9345 10250 2379 2380 179)
    for port in "${tcp_ports[@]}"; do
        local listener
        listener=$(ss -tlnp 2>/dev/null | awk -v p=":$port" '$4 ~ p {print $7}' | head -1)
        if [[ -n "$listener" ]]; then
            # Skip if it's already an rke2/kube process (expected on running clusters)
            if echo "$listener" | grep -qE 'rke2|kube|etcd|calico'; then
                continue
            fi
            log_warning "[WARNING] TCP port $port is in use by: $listener"
            warnings=$((warnings + 1))
        fi
    done
    # UDP ports: 4789 (VXLAN), 51820 (WireGuard)
    local udp_ports=(4789 51820)
    for port in "${udp_ports[@]}"; do
        local listener
        listener=$(ss -ulnp 2>/dev/null | awk -v p=":$port" '$4 ~ p {print $7}' | head -1)
        if [[ -n "$listener" ]]; then
            if echo "$listener" | grep -qE 'rke2|kube|calico|flannel'; then
                continue
            fi
            log_warning "[WARNING] UDP port $port is in use by: $listener"
            warnings=$((warnings + 1))
        fi
    done
    if [[ $warnings -eq 0 ]]; then
        log_success "[OK] No port conflicts detected on required K8s ports"
    else
        log_warning "[WARNING] $warnings port conflict(s) found — these may cause issues during installation"
    fi
}

# Check that the join endpoint (kube-vip VIP, RKE2 supervisor API on port 9345)
# is actually up and responding before attempting to install RKE2 as a joining
# node. Prevents node2/node3/workers from running a long doomed install
# against a VIP that isn't ready yet.
check_vip_join_endpoint() {
    if [[ ! "$NODE_TYPE" =~ ^(node2|node3|worker[0-9]+)$ ]]; then
        return 0
    fi
    if [[ -z "$VIP" ]]; then
        log_error "[ERROR] VIP is not set in config.env — cannot verify join endpoint reachability."
        return 1
    fi
    log "Checking join endpoint reachability ($VIP:9345/ping)..."
    local ping_code
    ping_code=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 "https://$VIP:9345/ping" 2>/dev/null)
    if [[ "$ping_code" == "200" ]]; then
        log_success "[OK] Join endpoint $VIP:9345 is reachable and responding."
        return 0
    else
        log_error "[ERROR] Cannot reach $VIP:9345 (RKE2 join port on the VIP) — got HTTP '${ping_code:-none}'."
        log_error "[ERROR] Verify: node1 completed installation, kube-vip has elected a leader, and firewall allows TCP 9345 to $VIP."
        return 1
    fi
}

# Validate this node's configured TOKEN against the live cluster BEFORE
# attempting a full RKE2 install. Catches a stale/incorrect TOKEN in this
# node's config.env — confirmed in the field as a real cause of RKE2 failing
# to start on a joining node, which otherwise only surfaces ~20 minutes later
# as an opaque "control process exited with error code".
check_join_token() {
    if [[ ! "$NODE_TYPE" =~ ^(node2|node3|worker[0-9]+)$ ]]; then
        return 0
    fi
    # Empty TOKEN/VIP are already caught as separate errors elsewhere
    # (check_node_ip / check_vip_join_endpoint) — nothing new to check here.
    [[ -z "$TOKEN" || -z "$VIP" ]] && return 0

    # RKE2/k3s tokens are formatted as K10<CA-hash>::<username>:<password> —
    # the credential portion after "::" is already a valid username:password
    # pair for HTTP Basic Auth and must be extracted, not used as a raw
    # password against an assumed username.
    local creds="${TOKEN#*::}"
    if [[ "$creds" == "$TOKEN" || -z "$creds" ]]; then
        log_warning "[WARNING] TOKEN does not match the expected K10<hash>::<user>:<pass> format — skipping automated validation."
        return 0
    fi

    log "Validating TOKEN against $VIP:9345..."
    local http_code
    http_code=$(curl -sk -u "$creds" -o /dev/null -w "%{http_code}" --connect-timeout 5 "https://$VIP:9345/v1-rke2/readyz" 2>/dev/null)

    if [[ "$http_code" == "401" ]]; then
        log_error "[ERROR] TOKEN rejected by the cluster at $VIP:9345 (HTTP 401 Unauthorized)."
        log_error "[ERROR] This node's TOKEN in config.env does not match the cluster's current token"
        log_error "[ERROR] (or was generated for a different cluster's CA). Get the correct value from"
        log_error "[ERROR] node1 and update config.env before retrying:"
        log_error "[ERROR]   On node1: cat /var/lib/rancher/rke2/server/node-token"
        return 1
    elif [[ "$http_code" =~ ^(200|204)$ ]]; then
        log_success "[OK] TOKEN validated against the cluster."
        return 0
    elif [[ "$http_code" == "403" ]]; then
        # 403 Forbidden is NOT a rejected token. The supervisor answers 401 when
        # it cannot authenticate the credentials at all; a 403 means the
        # username/password embedded in the TOKEN were accepted and the request
        # was then refused by authorization — /v1-rke2/readyz is restricted to
        # the agent role, and a server token authenticates as a different user.
        # So this outcome still proves the TOKEN matches the cluster.
        log_success "[OK] TOKEN accepted by the cluster (HTTP 403 on the readyz endpoint)."
        log "[INFO] 403 means authenticated-but-not-authorized for that endpoint, not a bad token."
        return 0
    else
        # Inconclusive (e.g. endpoint not reachable — already caught by
        # check_vip_join_endpoint, or server still bootstrapping) — don't
        # hard-block on anything less definitive than a confirmed 401.
        log_warning "[WARNING] Could not verify TOKEN (HTTP ${http_code:-none}). Proceeding — if the install fails, check the TOKEN manually."
        return 0
    fi
}

# Check that the kube-apiserver port (6443) on the VIP is reachable before
# attempting to join as node2/node3/worker. RKE2 requires BOTH 9345 (join
# handshake) and 6443 (kubelet/agent tunnel, used continuously after join) —
# see https://docs.rke2.io/install/requirements. A firewall/VLAN rule that
# opens 9345 but blocks 6443 lets the join handshake succeed and then hangs
# rke2-agent/rke2-server indefinitely with no error, since the join check
# alone can't see this.
check_apiserver_reachable() {
    if [[ ! "$NODE_TYPE" =~ ^(node2|node3|worker[0-9]+)$ ]]; then
        return 0
    fi
    if [[ -z "$VIP" ]]; then
        return 0   # already caught as a separate error by check_vip_join_endpoint
    fi
    log "Checking kube-apiserver reachability ($VIP:6443)..."
    local api_code
    api_code=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 "https://$VIP:6443/version" 2>/dev/null)
    if [[ -n "$api_code" ]]; then
        log_success "[OK] $VIP:6443 is reachable (HTTP $api_code)."
        return 0
    else
        log_error "[ERROR] Cannot reach $VIP:6443 (kube-apiserver port on the VIP)."
        log_error "[ERROR] RKE2 requires 6443 reachable in addition to 9345 — a firewall/VLAN rule"
        log_error "[ERROR] that allows 9345 but blocks 6443 will hang the join indefinitely with no error."
        log_error "[ERROR] Verify firewall/security-group rules allow TCP 6443 from this node to $VIP."
        return 1
    fi
}

# Check certificate expiry for RKE2 API server cert
check_certificates() {
    local cert_path="/var/lib/rancher/rke2/server/tls/serving-kube-apiserver.crt"
    if [[ ! -f "$cert_path" ]]; then
        log_warning "[WARNING] RKE2 API server certificate not found (cluster not yet installed?)"
        return 0
    fi
    if ! command -v openssl &>/dev/null; then
        log_warning "[WARNING] openssl not available — cannot check certificate expiry"
        return 0
    fi
    local expiry_date
    expiry_date=$(openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
    if [[ -z "$expiry_date" ]]; then
        log_warning "[WARNING] Could not read certificate expiry date"
        return 0
    fi
    local expiry_epoch
    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null)
    local now_epoch
    now_epoch=$(date +%s)
    local days_remaining=$(( (expiry_epoch - now_epoch) / 86400 ))
    if [[ $days_remaining -lt 0 ]]; then
        log_error "[ERROR] RKE2 API server certificate EXPIRED $((days_remaining * -1)) days ago!"
    elif [[ $days_remaining -lt 30 ]]; then
        log_error "[ERROR] RKE2 API server certificate expires in $days_remaining days ($expiry_date)"
    elif [[ $days_remaining -lt 90 ]]; then
        log_warning "[WARNING] RKE2 API server certificate expires in $days_remaining days ($expiry_date)"
    else
        log_success "[OK] RKE2 API server certificate valid for $days_remaining days (expires $expiry_date)"
    fi
}

# Pre-flight checks for system requirements
preflight_checks() {
    log "Running pre-flight checks..."
    local errors=0

    # Minimums depend on the deployment profile and this node's role.
    # single/triple keep the original 8 CPU / 24GB with no tolerance and no disk check.
    local profile role min_cpus min_ram_gb min_disk_gb=0 tol_pct=0
    profile=$(get_deployment_profile)
    role=$(get_node_role)
    case "$profile/$role" in
        ha-workers/master) min_cpus=4; min_ram_gb=8;  min_disk_gb=150 ;;
        ha-workers/worker) min_cpus=8; min_ram_gb=32; min_disk_gb=500 ;;
        *)                 min_cpus=8; min_ram_gb=24 ;;
    esac
    # An "8 GB" VM reports ~7.6GiB MemTotal (kernel/firmware reserve), so allow
    # MEM_TOLERANCE_PCT below nominal RAM and disk size in ha-workers mode.
    if [[ "$profile" == "ha-workers" ]]; then
        tol_pct="${MEM_TOLERANCE_PCT:-10}"
        if [[ ! "$tol_pct" =~ ^[0-9]+$ ]] || (( tol_pct > 50 )); then
            log_warning "[WARNING] MEM_TOLERANCE_PCT ('$tol_pct') must be 0-50. Using 10."
            tol_pct=10
        fi
    fi
    log "Pre-flight profile: $profile, role: $role (min ${min_cpus} CPU, ${min_ram_gb}GB RAM$( (( min_disk_gb > 0 )) && echo ", ${min_disk_gb}GB disk"), tolerance ${tol_pct}%)"

    # Check minimum RAM
    local min_ram_kb=$(( min_ram_gb * 1024 * 1024 * (100 - tol_pct) / 100 ))
    local total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_ram_gb=$(awk -v k="$total_ram_kb" 'BEGIN {printf "%.1f", k / 1048576}')

    if [[ $total_ram_kb -lt $min_ram_kb ]]; then
        log_error "[ERROR] Insufficient RAM for $role: ${total_ram_gb}GB detected. Minimum required: ${min_ram_gb}GB (tolerance ${tol_pct}%)"
        errors=$((errors + 1))
    else
        log_success "[OK] RAM check passed: ${total_ram_gb}GB available (minimum ${min_ram_gb}GB)"
    fi

    # Check minimum CPU cores
    local total_cpus=$(nproc)

    if [[ $total_cpus -lt $min_cpus ]]; then
        log_error "[ERROR] Insufficient CPU cores for $role: ${total_cpus} detected. Minimum required: ${min_cpus}"
        errors=$((errors + 1))
    else
        log_success "[OK] CPU check passed: ${total_cpus} cores available (minimum ${min_cpus})"
    fi

    # Check disk size (ha-workers only). Uses the size of the physical disk(s)
    # backing the path, not the filesystem size or free space: on a 150GB VM
    # the OS partitions (boot/swap/root/home) leave only ~100GB on /var, which
    # is expected. Free space is only a warning (< FREE_DISK_WARN_GB).
    # Longhorn data lives under /var/lib/longhorn (often a separate disk);
    # fall back to /var.
    if (( min_disk_gb > 0 )); then
        local disk_path="/var/lib/longhorn"
        [[ -d "$disk_path" ]] || disk_path="/var"
        local disk_src disk_gb="" disk_desc
        disk_src=$(df --output=source "$disk_path" 2>/dev/null | awk 'NR==2 {print $1}')
        # Walk device -> partition/LVM -> physical disk(s); sum unique disks
        # (an LVM volume can span several PVs).
        if [[ "$disk_src" == /dev/* ]] && command -v lsblk &>/dev/null; then
            disk_gb=$(lsblk -s -b -n -r -o NAME,TYPE,SIZE "$disk_src" 2>/dev/null | \
                awk '$2=="disk" { if (!seen[$1]++) sum+=$3 }
                     END { if (sum > 0) printf "%d", sum / 1073741824 }')
        fi
        if [[ "$disk_gb" =~ ^[0-9]+$ ]]; then
            disk_desc="disk backing $disk_path ($disk_src)"
        else
            # Fallback: filesystem size (e.g. lsblk missing, non-block source)
            disk_gb=$(df -BG --output=size "$disk_path" 2>/dev/null | awk 'NR==2 {gsub(/[G ]/,""); print}')
            disk_desc="filesystem $disk_path"
        fi
        if [[ ! "$disk_gb" =~ ^[0-9]+$ ]]; then
            log_warning "[WARNING] Could not determine disk size of $disk_path. Skipping disk size check."
        elif (( disk_gb < min_disk_gb * (100 - tol_pct) / 100 )); then
            log_error "[ERROR] Insufficient disk for $role: ${disk_gb}GB ${disk_desc}. Minimum required: ${min_disk_gb}GB (tolerance ${tol_pct}%)"
            errors=$((errors + 1))
        else
            log_success "[OK] Disk size check passed: ${disk_gb}GB ${disk_desc} (minimum ${min_disk_gb}GB)"
        fi

        # Free space: warning only
        local free_warn_gb="${FREE_DISK_WARN_GB:-50}" free_gb
        free_gb=$(df -BG --output=avail "$disk_path" 2>/dev/null | awk 'NR==2 {gsub(/[G ]/,""); print}')
        if [[ ! "$free_gb" =~ ^[0-9]+$ ]]; then
            log_warning "[WARNING] Could not determine free space on $disk_path."
        elif (( free_gb < free_warn_gb )); then
            log_warning "[WARNING] Low free space on $disk_path: ${free_gb}GB free (recommended at least ${free_warn_gb}GB). Installation will continue."
        else
            log_success "[OK] Free space on $disk_path: ${free_gb}GB (warning threshold ${free_warn_gb}GB)"
        fi
    fi

    # NTP time sync check (warning only)
    check_ntp_sync

    # DNS resolution check (warning only)
    check_dns_resolution

    # Port conflict check (warning only)
    check_required_ports

    # Join endpoint reachability + TOKEN validation (hard error for joining nodes)
    if ! check_vip_join_endpoint; then
        errors=$((errors + 1))
    fi

    if ! check_apiserver_reachable; then
        errors=$((errors + 1))
    fi

    if ! check_join_token; then
        errors=$((errors + 1))
    fi

    # Check minimum disk space (300GB on /var or root) - DISABLED FOR NOW
    # local min_disk_gb=300
    # local disk_path="/var"
    # if ! df "$disk_path" &>/dev/null; then
    #     disk_path="/"
    # fi
    # local available_disk_gb=$(df -BG "$disk_path" | awk 'NR==2 {gsub(/G/,""); print $4}')
    #
    # if [[ $available_disk_gb -lt $min_disk_gb ]]; then
    #     log_error "[ERROR] Insufficient disk space on $disk_path: ${available_disk_gb}GB available. Minimum required: ${min_disk_gb}GB"
    #     errors=$((errors + 1))
    # else
    #     log_success "[OK] Disk space check passed: ${available_disk_gb}GB available on $disk_path"
    # fi

    if [[ $errors -gt 0 ]]; then
        log_error "[ERROR] Pre-flight checks failed with $errors error(s)."
        if ! confirm_override "Do you want to continue anyway?"; then
            log_error "Exiting due to failed pre-flight checks."
            exit 1
        fi
        log_warning "[WARNING] Continuing despite failed pre-flight checks..."
    else
        log_success "All pre-flight checks passed!"
    fi
}

# Check script location, working directory, and available disk space on /var
check_script_location() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local cwd
    cwd="$(pwd)"
    local recommended_base="${UC_BASE_DIR}"
    local warn_threshold_gb=80
    local abort_threshold_gb=50

    log "Script location   : $script_dir"
    log "Working directory : $cwd"

    # --- Script location check (hard error) ---
    if [[ "$script_dir" != "${UC_BASE_DIR}" && "$script_dir" != ${UC_BASE_DIR}/* ]]; then
        log_error "[ERROR] Script is not located under ${UC_BASE_DIR} (found: $script_dir)."
        log_error "[ERROR] Required location: $recommended_base"
        log_error "[ERROR] Please move the script and all associated files to ${UC_BASE_DIR} and re-run."
        exit 1
    else
        log_success "[OK] Script location check passed: $script_dir"
    fi

    # --- Working directory check for airgapped/import modes ---
    if [[ "$ARGUMENT_TYPE" == "--airgapped" || "$ARGUMENT_TYPE" == "--scale-airgapped" || "$ARGUMENT_TYPE" == "--import" ]]; then
        if [[ ! -d "${cwd}/k8s-airgapped-files" ]]; then
            log_warning "[WARNING] 'k8s-airgapped-files/' directory not found next to the script ($cwd)."
            log_warning "[WARNING] It will be extracted from k8s-airgapped-files.tar[.gz] if one is present there."
            log_warning "[WARNING] This is a warning only — installation will continue."
        else
            log_success "[OK] Airgapped files directory found: ${cwd}/k8s-airgapped-files"
        fi
    fi

    # --- Disk space check on /var (hard limits) ---
    local disk_target="/var"
    local available_gb
    available_gb=$(df -BG "$disk_target" 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $4}')

    if [[ -z "$available_gb" || ! "$available_gb" =~ ^[0-9]+$ ]]; then
        log_warning "[WARNING] Could not determine free disk space on $disk_target. Skipping disk space check."
        return 0
    fi

    log "Available disk space on $disk_target: ${available_gb}GB"

    # ha-workers (4CPU/8GB/150GB masters): free space is warning-only; the
    # disk size itself is enforced in preflight_checks.
    if [[ "$(get_deployment_profile)" == "ha-workers" ]]; then
        local ha_warn_gb="${FREE_DISK_WARN_GB:-50}"
        if [[ $available_gb -lt $ha_warn_gb ]]; then
            log_warning "[WARNING] Low free space on $disk_target: ${available_gb}GB available (recommended at least ${ha_warn_gb}GB). Installation will continue."
        else
            log_success "[OK] Disk space check passed: ${available_gb}GB available on $disk_target."
        fi
        return 0
    fi

    if [[ $available_gb -lt $abort_threshold_gb ]]; then
        log_error "[ERROR] Critically low disk space on $disk_target: ${available_gb}GB available."
        log_error "[ERROR] Minimum required to proceed: ${abort_threshold_gb}GB. Installation cannot continue."
        exit 1
    elif [[ $available_gb -lt $warn_threshold_gb ]]; then
        log_warning "[WARNING] Low disk space on $disk_target: ${available_gb}GB available."
        log_warning "[WARNING] Recommended minimum: ${warn_threshold_gb}GB. Installation may fail if space runs out during extraction."
    else
        log_success "[OK] Disk space check passed: ${available_gb}GB available on $disk_target."
    fi
}

# Validate all configuration before starting installation
if [[ "$ARGUMENT_TYPE" != "--import" ]]; then
    validate_all_config
fi

# Checking and Logging Variables
if [[ "$ARGUMENT_TYPE" != "--import" ]]; then
    log "***************************************************************"
    log "Starting installations using the following User configurations:"
    log "LOG_FILE: $LOG_FILE"
    log "USE_PROXY: $USE_PROXY"
    if [[ "$USE_PROXY" == true ]]; then
        log "PROXY: $PROXY"
        log "HTTPS_PROXY: $HTTPS_PROXY"
        log "FTP_PROXY: $FTP_PROXY"
        log "NO_PROXY: $NO_PROXY"
    fi
    log "RKE2_VERSION: $RKE2_VERSION"
    log "HELM_VERSION: $HELM_VERSION"
    log "CALICOCTL_VERSION: $CALICOCTL_VERSION"
    log "METALLB_VERSION: $METALLB_VERSION"
    log "LONGHORN_VERSION: $LONGHORN_VERSION"
    log "SERVICE_POOL_RANGE: $SERVICE_POOL_RANGE"
    log "CALICO_IP_POOL: $CALICO_IP_POOL"
    log "KUBEVIP_VERSION: $KUBEVIP_VERSION"
    log "VIP: $VIP"
    log "NODES_NUMBER: $NODES_NUMBER"
    log "INTERFACE: $INTERFACE"
    log "NODE1: $NODE1"
    if [[ $NODES_NUMBER -gt 1 ]]; then
        log "NODE2: $NODE2"
        log "NODE3: $NODE3"
    fi
    if [[ -n "$TOKEN" ]]; then
        log_only "TOKEN: $TOKEN"
    fi
    log "***************************************************************"

    if [[ $NODES_NUMBER -gt 1 ]]; then
        # check if NODE1, NODE2, NODE3 are set
        if [[ -z "$NODE1" || -z "$NODE2" || -z "$NODE3" ]]; then
            log_error "[ERROR] NODE1, NODE2, and NODE3 must be set in config.env for multi-node setup."
            exit 1
        fi
        if [[ -z "$VIP" ]]; then
            log_error "[ERROR] VIP must be set in config.env for multi-node setup."
            exit 1
        fi
        NO_PROXY="$NO_PROXY,$NODE1,$NODE2,$NODE3,$VIP,$CALICO_IP_POOL"
    fi

NO_PROXY=$(echo "$NO_PROXY" | sed -E 's/,+/,/g; s/^,+//; s/,+$//')
fi

# End of user prompts and configuration section
# (for -help, -check, -collect, -upgrade, -rollback, these are skipped)
fi

#check the limits.conf file and change the nproc to unlimited and memlock settings 4032948
check_limits_conf() {
    dry_run_guard "Update /etc/security/limits.conf (nproc, nofile, memlock)" && return 0
    log "Checking /etc/security/limits.conf for nproc, nofile, and memlock settings..."

    update_or_append_limit() {
        local setting="$1"
        local soft_val="$2"
        local hard_val="$3"
        local conf="/etc/security/limits.conf"

        # Check if correct values already exist (idempotency)
        if grep -q "^\* soft ${setting} ${soft_val}$" "$conf" && grep -q "^\* hard ${setting} ${hard_val}$" "$conf"; then
            log "${setting} already set to soft=$soft_val hard=$hard_val. Skipping."
            return 0
        fi

        # Remove existing lines related to the setting (excluding unrelated comments)
        sed -i "/^[[:space:]]*\*.*[[:space:]]${setting}[[:space:]]/d" "$conf"

        log "Setting ${setting} to soft=$soft_val hard=$hard_val..."
        echo "* soft ${setting} ${soft_val}" >> "$conf"
        echo "* hard ${setting} ${hard_val}" >> "$conf"
    }

    update_or_append_limit "nproc" "unlimited" "unlimited"
    update_or_append_limit "nofile" "131072" "131072"
    update_or_append_limit "memlock" "4032948" "4032948"

    log "Finished updating /etc/security/limits.conf."
}

set_pid_max() {
    dry_run_guard "Set kernel.pid_max to 4194304 in /etc/sysctl.conf" && return 0
    log "Checking and setting kernel.pid_max to 4194304..."
    # Check if already set correctly (idempotency)
    local current_val
    current_val=$(sysctl -n kernel.pid_max 2>/dev/null)
    if [[ "$current_val" == "4194304" ]] && grep -q "^kernel.pid_max = 4194304$" /etc/sysctl.conf 2>/dev/null; then
        log "kernel.pid_max already set to 4194304. Skipping."
        return 0
    fi
    if grep -q "^kernel.pid_max" /etc/sysctl.conf; then
        sed -i 's/^kernel.pid_max.*/kernel.pid_max = 4194304/' /etc/sysctl.conf
    else
        echo "kernel.pid_max = 4194304" >> /etc/sysctl.conf
    fi
    sysctl -w kernel.pid_max=4194304
    log "kernel.pid_max updated and applied."
}

set_stack_size() {
    dry_run_guard "Update /etc/security/limits.conf stack size to 65536 KB" && return 0
    log "Setting stack size to 65536 KB (64MB)..."

    # Set soft limit to 65536 KB
    if grep -q "^\\* soft stack" /etc/security/limits.conf; then
        sed -i 's/^\* soft stack.*/\* soft stack 65536/' /etc/security/limits.conf
    else
        echo "* soft stack 65536" >> /etc/security/limits.conf
    fi

    # Set hard limit to 65536 KB
    if grep -q "^\\* hard stack" /etc/security/limits.conf; then
        sed -i 's/^\* hard stack.*/\* hard stack 65536/' /etc/security/limits.conf
    else
        echo "* hard stack 65536" >> /etc/security/limits.conf
    fi

    log "Stack size updated to 65536 KB (64MB) in /etc/security/limits.conf"
}

# ==================== P0/P1: KERNEL NETWORK & MEMORY TUNING ====================
# Tunes sysctl parameters for high-connection UC workloads (SIP, RTP, XMPP)
# Safe on single-node — these are ceilings, not pre-allocations
configure_kernel_tuning() {
    dry_run_guard "Apply kernel network/memory tuning for UC workloads" && return 0
    log "Applying kernel tuning for UC workloads (network buffers, conntrack, memory)..."

    local sysctl_file="/etc/sysctl.d/99-uc-performance.conf"
    local desired_params=(
        # --- Network: Socket buffers for RTP/SIP/XMPP ---
        "net.core.somaxconn = 65535"
        "net.core.netdev_max_backlog = 30000"
        "net.core.rmem_max = 16777216"
        "net.core.wmem_max = 16777216"
        "net.core.rmem_default = 1048576"
        "net.core.wmem_default = 1048576"
        # --- Network: default qdisc for NEW interfaces (incl. pod veths Calico
        # creates dynamically) — without this, only the physical NIC gets
        # fq_codel; the veth hop before it would keep the kernel's default. ---
        "net.core.default_qdisc = fq_codel"
        # --- Network: guaranteed minimum UDP socket buffers for RTP ---
        "net.ipv4.udp_rmem_min = 1048576"
        "net.ipv4.udp_wmem_min = 1048576"
        # --- Network: system-wide UDP memory pool (pages), covering ALL UDP
        # sockets combined — distinct from the per-socket min/max above.
        # Sized for thousands of concurrent RTP streams. ---
        "net.ipv4.udp_mem = 65536 131072 262144"
        # --- Network: TCP tuning for SIP/XMPP connections ---
        "net.ipv4.tcp_rmem = 4096 1048576 16777216"
        "net.ipv4.tcp_wmem = 4096 1048576 16777216"
        "net.ipv4.tcp_max_syn_backlog = 65536"
        "net.ipv4.tcp_tw_reuse = 1"
        "net.ipv4.ip_local_port_range = 1024 65535"
        "net.ipv4.tcp_fin_timeout = 15"
        "net.ipv4.tcp_keepalive_time = 300"
        "net.ipv4.tcp_keepalive_intvl = 15"
        "net.ipv4.tcp_keepalive_probes = 5"
        # --- Network: Connection tracking for high session counts ---
        "net.netfilter.nf_conntrack_max = 1048576"
        "net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30"
        "net.netfilter.nf_conntrack_tcp_timeout_established = 86400"
        # --- Memory: Prevent swapping and optimize writeback for real-time media ---
        "vm.swappiness = 0"
        "vm.dirty_ratio = 10"
        "vm.dirty_background_ratio = 5"
        "vm.dirty_expire_centisecs = 1000"
        "vm.dirty_writeback_centisecs = 500"
        "vm.max_map_count = 262144"
        "vm.overcommit_memory = 1"
        # --- File system: inotify and AIO for Longhorn + databases ---
        "fs.file-max = 2097152"
        "fs.inotify.max_user_watches = 524288"
        "fs.inotify.max_user_instances = 8192"
        "fs.aio-max-nr = 1048576"
    )

    # Check if file already exists and is up to date
    if [[ -f "$sysctl_file" ]]; then
        local needs_update=false
        for param in "${desired_params[@]}"; do
            local key="${param%% =*}"
            if ! grep -q "^${key} " "$sysctl_file" 2>/dev/null; then
                needs_update=true
                break
            fi
        done
        if [[ "$needs_update" == "false" ]]; then
            log "Kernel tuning already applied in $sysctl_file. Skipping."
            return 0
        fi
    fi

    # Write the sysctl configuration file
    {
        echo "# UC Performance Tuning — Auto-generated by k8s_cluster_multienv_setup"
        echo "# Applied: $(date -Iseconds)"
        echo ""
        for param in "${desired_params[@]}"; do
            echo "$param"
        done
    } > "$sysctl_file"

    # Load nf_conntrack module before applying conntrack settings
    if ! lsmod | grep -q nf_conntrack; then
        modprobe nf_conntrack 2>/dev/null || true
    fi
    # Ensure nf_conntrack loads on boot
    if [[ ! -f /etc/modules-load.d/nf_conntrack.conf ]]; then
        echo "nf_conntrack" > /etc/modules-load.d/nf_conntrack.conf
    fi

    # Apply all parameters
    if sysctl --system >> "$LOG_FILE" 2>&1; then
        log_success "Kernel tuning applied successfully from $sysctl_file."
    else
        log_warning "[WARNING] Some sysctl parameters may not have applied. Check $LOG_FILE for details."
    fi
}

# ==================== P0/P1: NIC RING BUFFER, RSS HASH & QDISC TUNING ====================
# Tunes the primary NIC for high-connection UC workloads (SIP, RTP, XMPP)
configure_nic_tuning() {
    dry_run_guard "Apply NIC ring buffer, RSS flow-hash, and qdisc tuning on $INTERFACE" && return 0

    if ! ip link show "$INTERFACE" &>/dev/null; then
        log_warning "[WARNING] Network interface '$INTERFACE' does not exist. Skipping NIC tuning."
        return 0
    fi

    log "Applying NIC tuning for UC workloads on $INTERFACE (ring buffers, RSS hash, qdisc)..."

    # --- Ring buffers: increase rx/tx descriptors to reduce drops under burst UDP/RTP load ---
    # 4096 confirmed supported across the target hardware fleet.
    if ethtool -G "$INTERFACE" rx 4096 tx 4096 2>>"$LOG_FILE"; then
        log_success "Ring buffers set to rx=4096 tx=4096 on $INTERFACE."
    else
        log_warning "[WARNING] Could not set ring buffers on $INTERFACE (driver may not support it). Check $LOG_FILE."
    fi

    # --- Offloads: disable GRO/LRO so the NIC/driver delivers packets as they
    # arrive instead of coalescing them first. Coalescing trades a little CPU
    # for added latency/jitter, which is the wrong tradeoff for real-time RTP.
    # LRO in particular is unsupported on many drivers (e.g. virtio-net) —
    # that's a normal skip, not a failure.
    if ethtool -K "$INTERFACE" gro off lro off 2>>"$LOG_FILE"; then
        log_success "GRO/LRO offloads disabled on $INTERFACE."
    else
        log_warning "[WARNING] Could not fully disable GRO/LRO on $INTERFACE (driver may not support one of them). Check $LOG_FILE."
    fi

    # --- RSS flow hash: include UDP src/dst port in hash so RTP streams spread across queues ---
    if ethtool -N "$INTERFACE" rx-flow-hash udp4 sdfn 2>>"$LOG_FILE" && \
       ethtool -N "$INTERFACE" rx-flow-hash udp6 sdfn 2>>"$LOG_FILE"; then
        log_success "RSS rx-flow-hash set to sdfn (udp4/udp6) on $INTERFACE."
    else
        log_warning "[WARNING] Could not set rx-flow-hash on $INTERFACE (driver/NIC may not support UDP RSS). Check $LOG_FILE."
    fi

    # --- RX/TX queues: scale combined queues to the NIC's max so RSS hashing above
    # actually has multiple queues to spread RTP streams across (important when
    # several RTP pods share one node). Many virtual NICs (virtio-net, etc.) don't
    # support channel changes at all, so treat that as a normal skip, not a failure.
    if ethtool -l "$INTERFACE" &>/dev/null; then
        local max_combined
        max_combined=$(ethtool -l "$INTERFACE" 2>/dev/null | awk '/Pre-set maximums:/{f=1; next} f && /Combined:/{print $2; exit}')
        if [[ "$max_combined" =~ ^[0-9]+$ && "$max_combined" -gt 1 ]]; then
            if ethtool -L "$INTERFACE" combined "$max_combined" 2>>"$LOG_FILE"; then
                log_success "RX/TX queues scaled to combined=$max_combined on $INTERFACE."
            else
                log_warning "[WARNING] Could not set combined queue count on $INTERFACE. Check $LOG_FILE."
            fi
        else
            log "NIC $INTERFACE reports $((max_combined)) combined queue(s) available. Skipping queue scaling."
        fi
    else
        log "NIC $INTERFACE does not expose channel info (ethtool -l unsupported, e.g. a virtual NIC). Skipping queue scaling."
    fi

    # --- Qdisc: fq_codel to bound latency/bufferbloat for real-time media ---
    if tc qdisc replace dev "$INTERFACE" root fq_codel 2>>"$LOG_FILE"; then
        log_success "Qdisc set to fq_codel on $INTERFACE."
    else
        log_warning "[WARNING] Could not set fq_codel qdisc on $INTERFACE. Check $LOG_FILE."
    fi

    # --- Persistence: everything above only lasts until the next reboot,
    # NIC reset, or link flap unless it's re-applied on every interface-up.
    persist_nic_tuning "$INTERFACE"
}

# Registers a SLES/wicked POST_UP_SCRIPT so the NIC tuning above reapplies
# automatically on every interface up (reboot, NIC reset, link flap) instead
# of only taking effect for the current boot.
persist_nic_tuning() {
    local iface="$1"
    local script_dir="/etc/sysconfig/network/scripts"
    local script_path="${script_dir}/${iface}-ethtool.sh"
    local ifcfg_file="/etc/sysconfig/network/ifcfg-${iface}"

    if [[ ! -f "$ifcfg_file" ]]; then
        log_warning "[WARNING] $ifcfg_file not found — cannot persist NIC tuning across reboots. Settings applied for this boot only."
        return 0
    fi

    sudo mkdir -p "$script_dir"

    sudo tee "$script_path" > /dev/null <<HEADER
#!/bin/bash
# Auto-generated by k8s_cluster_multienv_setup — reapplies NIC tuning for UC
# workloads (RTP/SIP/XMPP) every time this interface comes up.
IFACE="$iface"
HEADER

    sudo tee -a "$script_path" > /dev/null <<'BODY'
ethtool -G "$IFACE" rx 4096 tx 4096
ethtool -K "$IFACE" gro off lro off
ethtool -N "$IFACE" rx-flow-hash udp4 sdfn
ethtool -N "$IFACE" rx-flow-hash udp6 sdfn

if ethtool -l "$IFACE" &>/dev/null; then
    max_combined=$(ethtool -l "$IFACE" 2>/dev/null | awk '/Pre-set maximums:/{f=1; next} f && /Combined:/{print $2; exit}')
    if [[ "$max_combined" =~ ^[0-9]+$ && "$max_combined" -gt 1 ]]; then
        ethtool -L "$IFACE" combined "$max_combined"
    fi
fi

tc qdisc replace dev "$IFACE" root fq_codel
BODY

    sudo chmod +x "$script_path"
    log_success "Wrote persistent NIC tuning script: $script_path"

    if grep -q "^POST_UP_SCRIPT=\"wicked:${script_path}\"" "$ifcfg_file" 2>/dev/null; then
        log "POST_UP_SCRIPT already registered in $ifcfg_file."
    elif grep -q "^POST_UP_SCRIPT=" "$ifcfg_file" 2>/dev/null; then
        log_warning "[WARNING] $ifcfg_file already sets a different POST_UP_SCRIPT — not overwriting it."
        log_warning "[WARNING] Add this manually if you want the NIC tuning to persist: POST_UP_SCRIPT=\"wicked:${script_path}\""
    else
        echo "POST_UP_SCRIPT=\"wicked:${script_path}\"" | sudo tee -a "$ifcfg_file" > /dev/null
        log_success "Registered POST_UP_SCRIPT in $ifcfg_file — NIC tuning will now survive reboots."
    fi
}

# ==================== IRQ BALANCING ====================
# Spreads NIC interrupts (including the RX/TX queues enabled above) across CPUs.
# Without this, interrupts default to a single core, which can saturate that
# core's capacity well before the network link itself is the bottleneck —
# undoing the benefit of the RSS/queue tuning in configure_nic_tuning above.
install_irqbalance_airgapped() {
    dry_run_guard "Install and enable irqbalance" && return 0
    log "Installing irqbalance from local RPM packages..."

    if systemctl is-active --quiet irqbalance.service; then
        log_success "irqbalance is already installed and running."
        return 0
    fi

    if ! command -v irqbalance >/dev/null 2>&1; then
        local rpm_file
        rpm_file=$(ls ./k8s-airgapped-files/packages/irqbalance-*.rpm 2>/dev/null | head -n1)
        if [[ -z "$rpm_file" ]]; then
            log_warning "[WARNING] No irqbalance package found under ./k8s-airgapped-files/packages/. Skipping."
            return 1
        fi
        log "Installing irqbalance from: $(basename "$rpm_file")"
        if ! rpm -ivh "$rpm_file" >> "$LOG_FILE" 2>&1; then
            log_error "[ERROR] irqbalance installation failed."
            return 1
        fi
    fi

    sudo systemctl enable irqbalance.service >> "$LOG_FILE" 2>&1
    sudo systemctl start irqbalance.service >> "$LOG_FILE" 2>&1

    if systemctl is-active --quiet irqbalance.service; then
        log_success "irqbalance installed and running."
    else
        log_warning "[WARNING] irqbalance installed but service did not start. Check $LOG_FILE."
    fi
}

# ==================== P3: DISK I/O SCHEDULER TUNING ====================
# Optimizes block device I/O scheduler for SSDs (none/noop) or HDDs (mq-deadline)
configure_io_scheduler() {
    dry_run_guard "Configure I/O scheduler for block devices" && return 0
    log "Configuring I/O scheduler for block devices..."

    local udev_rule="/etc/udev/rules.d/60-io-scheduler.rules"
    local changed=0

    for dev in /sys/block/sd* /sys/block/vd* /sys/block/nvme*; do
        [[ -d "$dev" ]] || continue
        local devname
        devname=$(basename "$dev")
        local rotational
        rotational=$(cat "$dev/queue/rotational" 2>/dev/null || echo "1")

        local target_sched="mq-deadline"
        [[ "$rotational" == "0" ]] && target_sched="none"

        local current_sched
        current_sched=$(cat "$dev/queue/scheduler" 2>/dev/null | grep -oP '\[\K[^\]]+' || echo "")

        if [[ "$current_sched" != "$target_sched" ]]; then
            echo "$target_sched" > "$dev/queue/scheduler" 2>/dev/null && {
                log "Set I/O scheduler for $devname to $target_sched (rotational=$rotational)"
                changed=1
            }
        else
            log "I/O scheduler for $devname already set to $target_sched."
        fi
    done

    # Persist via udev rule
    if [[ ! -f "$udev_rule" ]]; then
        cat > "$udev_rule" <<'UDEV_EOF'
# I/O scheduler: none for SSDs, mq-deadline for HDDs
ACTION=="add|change", KERNEL=="sd*|vd*|nvme*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd*|vd*|nvme*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"
UDEV_EOF
        log "Persisted I/O scheduler via udev rule: $udev_rule"
        changed=1
    fi

    if [[ $changed -eq 1 ]]; then
        log_success "I/O scheduler configuration applied."
    else
        log "I/O scheduler already optimized."
    fi
}

# Optimize filesystem mount options for XFS partitions
optimize_filesystem() {
    log "Optimizing filesystem mount options (noatime on all XFS partitions)..."

    local fstab="/etc/fstab"
    local fstab_backup="/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    local changed=0

    # Backup fstab before any modification
    cp "$fstab" "$fstab_backup"
    log "fstab backup created at $fstab_backup"

    # Dynamically enumerate all currently mounted XFS filesystems
    # -r = raw (no truncation), -n = no header, -t xfs = only XFS, -o TARGET = target column only
    local xfs_mounts
    xfs_mounts=$(findmnt -rn -t xfs -o TARGET 2>/dev/null | sort)

    if [[ -z "$xfs_mounts" ]]; then
        log "No XFS mount points found at runtime. Skipping filesystem optimization."
        return 0
    fi

    log "Discovered XFS mount points: $(echo "$xfs_mounts" | tr '\n' ' ')"

    while IFS= read -r mountpoint; do
        [[ -z "$mountpoint" ]] && continue
        log "Processing $mountpoint..."

        # --- Validate runtime fstype and options via findmnt ---
        local runtime_fstype runtime_opts
        runtime_fstype=$(findmnt -rno FSTYPE "$mountpoint" 2>/dev/null || echo "")
        runtime_opts=$(findmnt -rno OPTIONS "$mountpoint" 2>/dev/null || echo "")

        if [[ "$runtime_fstype" != "xfs" ]]; then
            log "Skipping $mountpoint (runtime fstype: ${runtime_fstype:-unknown}, not XFS)"
            continue
        fi

        # --- Check mountpoint exists in fstab (skip auto/systemd-managed mounts) ---
        if ! awk -v mp="$mountpoint" '$1 !~ /^#/ && $2 == mp' "$fstab" | grep -q .; then
            log "Skipping $mountpoint (not in fstab — auto or systemd managed)"
            continue
        fi

        # --- Read current fstab options with empty-option guard ---
        local current_opts
        current_opts=$(awk -v mp="$mountpoint" '$1 !~ /^#/ && $2 == mp {print $4; exit}' "$fstab")

        # Guard: if fstab options field is empty or missing, default to "defaults"
        if [[ -z "$current_opts" ]]; then
            log_error "[WARNING] $mountpoint has empty options field in fstab — defaulting to 'defaults'"
            current_opts="defaults"
        fi

        # --- Compute new options: strip conflicting atime flags, append noatime ---
        local new_opts
        new_opts=$(echo "$current_opts" \
            | tr ',' '\n' \
            | grep -Ev '^(atime|relatime|strictatime|noatime)$' \
            | tr '\n' ',' \
            | sed 's/,$//')

        # Guard: if stripping left an empty string, fall back to "defaults"
        if [[ -z "$new_opts" ]]; then
            new_opts="defaults"
        fi
        new_opts="${new_opts},noatime"

        # --- REMOUNT FIRST: apply live before touching fstab ---
        # This validates the option is accepted by the kernel before we persist it.
        if echo "$runtime_opts" | tr ',' '\n' | grep -qx "noatime"; then
            log "noatime already active at runtime on $mountpoint. No remount needed."
            local remount_ok=1
        else
            log "Applying noatime live on $mountpoint (pre-persistence validation)..."
            if mount -o remount,noatime "$mountpoint" >> "$LOG_FILE" 2>&1; then
                log "noatime applied live on $mountpoint."
                local remount_ok=1
            else
                log_error "[WARNING] Could not remount $mountpoint with noatime — skipping fstab update for this mount. Will require manual intervention."
                local remount_ok=0
            fi
        fi

        # --- Persist to fstab ONLY if live remount succeeded ---
        if [[ $remount_ok -eq 1 ]]; then
            if [[ "$current_opts" == "$new_opts" ]]; then
                log "fstab already optimal for $mountpoint (options: $current_opts)"
            else
                log "Persisting to fstab for $mountpoint: [$current_opts] -> [$new_opts]"
                # Use index()+substr() in awk to replace only the options token in-place,
                # preserving all original whitespace and column alignment
                awk -v mp="$mountpoint" -v oldopts="$current_opts" -v newopts="$new_opts" '
                    $1 !~ /^#/ && $2 == mp {
                        idx = index($0, oldopts)
                        if (idx > 0) {
                            $0 = substr($0, 1, idx - 1) newopts substr($0, idx + length(oldopts))
                        }
                    }
                    { print }
                ' "$fstab" > "${fstab}.tmp" && mv "${fstab}.tmp" "$fstab"
                changed=1
            fi
        fi

    done <<< "$xfs_mounts"

    if [[ $changed -eq 1 ]]; then
        log_success "Filesystem optimization applied: noatime set on all XFS partitions in /etc/fstab."
    else
        log_success "Filesystem optimization: noatime already configured on all XFS partitions."
    fi
}

# Stop, disable and mask the host firewall.
# The pre-3.1.6 version only acted when firewalld was *running*: a firewalld
# that was stopped but still enabled was reported as "already inactive" and
# left enabled, so it came back on the next reboot (seen on workers after the
# kernel install). It is now always disabled and masked, whatever its state,
# and the result is verified instead of assumed.
check_firewall() {
    log "Checking firewall status..."
    local svc found=false
    for svc in firewalld SuSEfirewall2 ufw; do
        # list-unit-files also lists masked units, so a re-run stays quiet.
        systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null | grep -q . || continue
        found=true
        if [[ "$DRY_RUN" == true ]]; then
            log "[DRY-RUN] Would stop, disable and mask ${svc} (now: $(systemctl is-active "$svc" 2>/dev/null)/$(systemctl is-enabled "$svc" 2>/dev/null))"
            continue
        fi
        capture_output systemctl disable --now "$svc"
        capture_output systemctl mask "$svc"
        local state enabled
        state="$(systemctl is-active "$svc" 2>/dev/null)"
        enabled="$(systemctl is-enabled "$svc" 2>/dev/null)"
        if [[ "$state" == "active" || "$enabled" == "enabled" ]]; then
            log_error "[ERROR] ${svc} could not be turned off (active: ${state}, enabled: ${enabled})."
            confirm_override "Continue with ${svc} still on?" || exit 1
        else
            log_success "[OK] ${svc} stopped, disabled and masked (active: ${state}, enabled: ${enabled})."
        fi
    done
    [[ "$found" == false ]] && log "No host firewall service installed."
    return 0
}

# ETC/HOSTS Configuration
configure_hosts() {
    if [[ "$USE_PROXY" == true ]]; then
        log "Appending to /etc/hosts..."
        # Backup existing hosts file
        cp /etc/hosts /etc/hosts.bak
        # Check if entries already exist to avoid duplication
        grep -q "$VIP" /etc/hosts || {
            {
                echo ""
                echo "# Added by cluster setup script"
                echo "$VIP mastervip"
            } >> /etc/hosts

            log "/etc/hosts updated with VIP and node mappings."
        }
    fi
}

# Proxy Configuration
configure_proxy() {
    if [[ "$USE_PROXY" == true ]]; then
        log "Setting up system-wide proxy..."
        capture_output tee /etc/sysconfig/proxy > /dev/null <<EOF
PROXY_ENABLED="yes"
HTTP_PROXY="$PROXY"
HTTPS_PROXY="$HTTPS_PROXY"
FTP_PROXY="$FTP_PROXY"
NO_PROXY="$NO_PROXY"
EOF
        log "System-wide proxy configured."
    fi
}

# Zypper Proxy Configuration
configure_zypper_proxy() {
    if [[ "$USE_PROXY" == true ]]; then
        log "Configuring Zypper proxy settings..."
        capture_output sed -i "/\[global\]/a proxy_http=$PROXY\nproxy_https=$PROXY" /etc/zypp/zypper.conf
        log "Zypper proxy configuration completed."
    fi
}

export_local_variables(){
    log "Reloading updated environment variables..."
    source ~/.bashrc
    if [[ "$USE_PROXY" == true ]]; then
        export http_proxy=$PROXY
        export https_proxy=$HTTPS_PROXY
        export ftp_proxy=$FTP_PROXY
        export no_proxy=$NO_PROXY
        export HTTP_PROXY="$PROXY"
        export HTTPS_PROXY="$HTTPS_PROXY"
        export FTP_PROXY="$FTP_PROXY"
        export NO_PROXY="$NO_PROXY"
    fi

    sleep_for 5
}

# Check and Install curl
check_install_curl() {
    if ! command -v curl >> "$LOG_FILE" 2>&1; then
        log "Command curl not found, installing with Zypper..."
        capture_output zypper install -y curl
        if ! command -v curl >> "$LOG_FILE" 2>&1; then
            log_error "[ERROR] Failed to install curl. Exiting."
            exit 1
        fi
    fi
    log "Command curl is available."
}

# Files every airgapped install path consumes from the bundle. Keep this in
# sync with the REQUIRED_FILES list in the downloader script — it is the same
# contract, checked from the other end.
# Sets MISSING_BUNDLE_FILES to a space-separated list; returns 1 if any are absent.
MISSING_BUNDLE_FILES=""
_verify_airgapped_bundle() {
    local dir="$1"
    local required=(
        "install.sh"
        "rke2.linux-amd64.tar.gz"
        "rke2-images-core.linux-amd64.tar.zst"
        "rke2-images-calico.linux-amd64.tar.zst"
        "sha256sum-amd64.txt"
    )
    local missing=() f
    for f in "${required[@]}"; do
        [[ -f "$dir/$f" ]] || missing+=("$f")
    done
    MISSING_BUNDLE_FILES="${missing[*]}"
    [[ ${#missing[@]} -eq 0 ]]
}

# Function to extract airgapped archive files (.tar or .tar.gz)
# This function checks for k8s-airgapped-files.tar.gz or .tar and extracts them automatically
extract_airgapped_archive() {
    local airgapped_dir="$SCRIPT_DIR/k8s-airgapped-files"
    local tar_gz_file="$SCRIPT_DIR/k8s-airgapped-files.tar.gz"
    local tar_file="$SCRIPT_DIR/k8s-airgapped-files.tar"

    # Check if the directory already exists AND is complete. Existence alone is
    # not enough: a partially-copied or half-extracted bundle used to satisfy
    # this check and then fail much later with "Required file not found:
    # ./k8s-airgapped-files/install.sh", far from the actual cause.
    local needs_extract=true
    if [[ -d "$airgapped_dir" ]]; then
        if _verify_airgapped_bundle "$airgapped_dir"; then
            log "Airgapped directory already exists and is complete: $airgapped_dir. Skipping extraction."
            needs_extract=false
        elif [[ -f "$tar_gz_file" || -f "$tar_file" ]]; then
            log_warning "[WARNING] $airgapped_dir exists but is incomplete — missing: ${MISSING_BUNDLE_FILES}"
            log_warning "[WARNING] Re-extracting the archive over it."
        else
            log_error "[ERROR] $airgapped_dir exists but is incomplete, and no archive is present to repair it."
            log_error "[ERROR] Missing from the bundle: ${MISSING_BUNDLE_FILES}"
            log_error "[ERROR] Copy a complete k8s-airgapped-files.tar[.gz] to $SCRIPT_DIR, or remove"
            log_error "[ERROR] the incomplete directory and re-run: rm -rf $airgapped_dir"
            exit 1
        fi
    fi

    if [[ "$needs_extract" == true ]]; then
        # Try to extract .tar.gz first, then .tar
        if [[ -f "$tar_gz_file" ]]; then
            log "Found airgapped archive: $tar_gz_file"
            log "Extracting $tar_gz_file into $SCRIPT_DIR..."
            if tar -xzf "$tar_gz_file" -C "$SCRIPT_DIR"; then
                log_success "Successfully extracted $tar_gz_file"
            else
                log_error "[ERROR] Failed to extract $tar_gz_file"
                exit 1
            fi
        elif [[ -f "$tar_file" ]]; then
            log "Found airgapped archive: $tar_file"
            log "Extracting $tar_file into $SCRIPT_DIR..."
            if tar -xf "$tar_file" -C "$SCRIPT_DIR"; then
                log_success "Successfully extracted $tar_file"
            else
                log_error "[ERROR] Failed to extract $tar_file"
                exit 1
            fi
        else
            log_error "[ERROR] No airgapped archive found!"
            log_error "[ERROR] Please provide either:"
            log_error "        - $tar_gz_file"
            log_error "        - $tar_file"
            log_error "        - Or an already extracted $airgapped_dir directory"
            exit 1
        fi
    fi
    
    # Verify the directory exists after extraction
    if [[ ! -d "$airgapped_dir" ]]; then
        log_error "[ERROR] Airgapped directory not found after extraction: $airgapped_dir"
        exit 1
    fi

    # …and that it actually holds what the install needs. Failing here names
    # the missing files; failing later only names the first one reached.
    if ! _verify_airgapped_bundle "$airgapped_dir"; then
        log_error "[ERROR] The airgapped bundle in $airgapped_dir is incomplete."
        log_error "[ERROR] Missing: ${MISSING_BUNDLE_FILES}"
        log_error "[ERROR] The archive may be truncated or built by an older downloader."
        log_error "[ERROR] Re-transfer k8s-airgapped-files.tar.gz and remove $airgapped_dir before retrying."
        exit 1
    fi

    # Extract container-images archive if it exists and hasn't been extracted
    local container_images_dir="$airgapped_dir/container-images"
    local container_tar_gz="$airgapped_dir/container-images.tar.gz"
    local container_tar="$airgapped_dir/container-images.tar"

    if [[ ! -d "$container_images_dir" ]]; then
        if [[ -f "$container_tar_gz" ]]; then
            log "Found container images archive: $container_tar_gz"
            log "Extracting container images..."
            if tar -xzf "$container_tar_gz" -C "$airgapped_dir"; then
                log_success "Successfully extracted container images"
            else
                log_error "[ERROR] Failed to extract $container_tar_gz"
                exit 1
            fi
        elif [[ -f "$container_tar" ]]; then
            log "Found container images archive: $container_tar"
            log "Extracting container images..."
            if tar -xf "$container_tar" -C "$airgapped_dir"; then
                log_success "Successfully extracted container images"
            else
                log_error "[ERROR] Failed to extract $container_tar"
                exit 1
            fi
        fi
    else
        log "Container images directory already exists. Skipping extraction."
    fi

    log_success "Airgapped files are ready in: $airgapped_dir"
}

# Function to load container images in airgapped environment
load_container_images() {

    # Create code to load container images to the system with ctr
    log "Loading container images for airgapped installation..."
    local images_dir="./k8s-airgapped-files/container-images"
    if [[ ! -d "$images_dir" ]]; then
        log_error "[ERROR] Directory $images_dir not found. Please ensure it contains the required container images."
        exit 1
    fi

    # Move all images to /var/lib/rancher/rke2/agent/images/
    log "Moving container images to /var/lib/rancher/rke2/agent/images/..."
    if [[ ! -d /var/lib/rancher/rke2/agent/images/ ]]; then
        log "Creating directory /var/lib/rancher/rke2/agent/images/..."
        sudo mkdir -p /var/lib/rancher/rke2/agent/images/
    fi
    sudo cp "$images_dir"/*.tar /var/lib/rancher/rke2/agent/images/ >> "$LOG_FILE" 2>&1
    if [[ $? -ne 0 ]]; then
        log_error "[ERROR] Failed to copy images from $images_dir to /var/lib/rancher/rke2/agent/images/"
        exit 1
    fi
    log "Container images moved successfully to /var/lib/rancher/rke2/agent/images/."
}


# Install RKE2 with Proxy Support if Enabled
install_rke2() {
    if systemctl is-active --quiet rke2-server.service; then
        log_success "RKE2 is already installed and running."
        if [[ "$NODE_TYPE" == "node2" || "$NODE_TYPE" == "node3" ]]; then
            log_warning "[Warning] Please double check your config.env, especially that NODE IPs exists and that the Token is the correct one generated by Node 1."
        fi
        return
    fi

    log "Creating RKE2 configuration directory..."
    sudo mkdir -p /etc/rancher/rke2/

    # In ha-workers mode (3 control-plane + N workers) masters run only the
    # control plane: CriticalAddonsOnly is the RKE2-documented taint for
    # dedicated servers. UC charts do not tolerate it, so no UC pods land here.
    local node_taint_block=""
    if [[ "$(get_deployment_profile)" == "ha-workers" ]]; then
        node_taint_block=$'node-taint:\n  - "CriticalAddonsOnly=true:NoExecute"'
        log "ha-workers deployment: $NODE_TYPE will be tainted CriticalAddonsOnly=true:NoExecute"
    fi

    # Compute kubelet reservations based on node type
    local sys_cpu="500m" sys_mem="1Gi" eviction_mem="2Gi"
    if [[ "$NODE_TYPE" != "single" ]]; then
        sys_cpu="1" sys_mem="2Gi" eviction_mem="2Gi"
    fi

    if [[ "$NODE_TYPE" == "node1" || "$NODE_TYPE" == "single" ]]; then
        log "Creating production RKE2 config for $NODE_TYPE..."
        sudo tee /etc/rancher/rke2/config.yaml > /dev/null <<EOF
advertise-address: $NODE1
node-ip: $NODE1
tls-san:
  - mastervip
  - $NODE1
  - $VIP
cni:
  - calico
disable:
  - rke2-canal
node-label:
  - "role=control"
${node_taint_block}

# === SPEGEL EMBEDDED REGISTRY MIRROR ===
embedded-registry: true

# === ESSENTIAL PRODUCTION SETTINGS ===
kubelet-arg:
  - "container-log-max-size=10Mi"
  - "container-log-max-files=3"
  - "serialize-image-pulls=false"
  - "system-reserved=cpu=${sys_cpu},memory=${sys_mem},ephemeral-storage=2Gi"
  - "kube-reserved=cpu=500m,memory=1Gi,ephemeral-storage=2Gi"
  - "eviction-hard=memory.available<${eviction_mem},nodefs.available<10%,imagefs.available<10%"

# === API SERVER & ETCD TUNING ===
kube-apiserver-arg:
  - "max-requests-inflight=800"
  - "max-mutating-requests-inflight=400"

etcd-arg:
  - "quota-backend-bytes=4294967296"
EOF
    fi

    if [[ "$NODE_TYPE" == "node2" ]]; then
        log "Creating production RKE2 config for $NODE_TYPE..."
        sudo tee /etc/rancher/rke2/config.yaml > /dev/null <<EOF
server: https://$VIP:9345
token: "$TOKEN"
advertise-address: $NODE2
node-ip: $NODE2
tls-san:
  - mastervip
  - $NODE1
  - $NODE2
  - $VIP
cni:
  - calico
disable:
  - rke2-canal
node-label:
  - "role=control"
${node_taint_block}

# === SPEGEL EMBEDDED REGISTRY MIRROR ===
embedded-registry: true

# === ESSENTIAL PRODUCTION SETTINGS ===
kubelet-arg:
  - "container-log-max-size=10Mi"
  - "container-log-max-files=3"
  - "serialize-image-pulls=false"
  - "system-reserved=cpu=${sys_cpu},memory=${sys_mem},ephemeral-storage=2Gi"
  - "kube-reserved=cpu=500m,memory=1Gi,ephemeral-storage=2Gi"
  - "eviction-hard=memory.available<${eviction_mem},nodefs.available<10%,imagefs.available<10%"

# === API SERVER & ETCD TUNING ===
kube-apiserver-arg:
  - "max-requests-inflight=800"
  - "max-mutating-requests-inflight=400"

etcd-arg:
  - "quota-backend-bytes=4294967296"
EOF
    fi

    if [[ "$NODE_TYPE" == "node3" ]]; then
        log "Creating production RKE2 config for $NODE_TYPE..."
        sudo tee /etc/rancher/rke2/config.yaml > /dev/null <<EOF
server: https://$VIP:9345
token: "$TOKEN"
advertise-address: $NODE3
node-ip: $NODE3
tls-san:
  - mastervip
  - $NODE1
  - $NODE2
  - $NODE3
  - $VIP
cni:
  - calico
disable:
  - rke2-canal
node-label:
  - "role=control"
${node_taint_block}

# === SPEGEL EMBEDDED REGISTRY MIRROR ===
embedded-registry: true

# === ESSENTIAL PRODUCTION SETTINGS ===
kubelet-arg:
  - "container-log-max-size=10Mi"
  - "container-log-max-files=3"
  - "serialize-image-pulls=false"
  - "system-reserved=cpu=${sys_cpu},memory=${sys_mem},ephemeral-storage=2Gi"
  - "kube-reserved=cpu=500m,memory=1Gi,ephemeral-storage=2Gi"
  - "eviction-hard=memory.available<${eviction_mem},nodefs.available<10%,imagefs.available<10%"

# === API SERVER & ETCD TUNING ===
kube-apiserver-arg:
  - "max-requests-inflight=800"
  - "max-mutating-requests-inflight=400"

etcd-arg:
  - "quota-backend-bytes=4294967296"
EOF
    fi

    log "Installing RKE2 version v$RKE2_VERSION with Calico CNI..."
    if ! run_with_spinner "Installing RKE2" bash -c "curl -sfL --connect-timeout 30 --max-time 300 https://get.rke2.io | INSTALL_RKE2_VERSION=v$RKE2_VERSION sh -s '' --cni calico"; then
        log_error "[ERROR] Failed to install RKE2. Check network connectivity and proxy settings."
        exit 1
    fi
    log_success "RKE2 binaries installed successfully."
    capture_output systemctl enable rke2-server.service

    # Configure proxy for RKE2 if needed
    if [[ "$USE_PROXY" == true ]]; then
        log "Configuring RKE2 proxy..."
        capture_output tee /etc/default/rke2-server > /dev/null <<EOF
HTTP_PROXY="$PROXY"
HTTPS_PROXY="$HTTPS_PROXY"
FTP_PROXY="$FTP_PROXY"
NO_PROXY="$NO_PROXY"
EOF
    fi

    # Configure proxy for RKE2-Server environment if needed
    if [[ "$USE_PROXY" == true ]]; then
        log "Configuring RKE2-SERVER proxy..."
        capture_output tee /usr/lib/systemd/system/rke2-server.env > /dev/null <<EOF
HTTP_PROXY=$PROXY
HTTPS_PROXY=$HTTPS_PROXY
FTP_PROXY="$FTP_PROXY"
NO_PROXY=$NO_PROXY
EOF
    fi

    log "Starting RKE2 Service. This may take a while ..."
    local rke2_start_time
    rke2_start_time=$(date '+%Y-%m-%d %H:%M:%S')
    if ! run_with_spinner "Starting RKE2 Service" timeout 600 systemctl start rke2-server.service; then
        diagnose_rke2_service_failure "rke2-server.service" "rke2-server" "$rke2_start_time"
        exit 1
    fi

    # Wait for service to be fully ready
    log "Waiting for RKE2 service to be ready..."
    local ready=false
    for i in {1..30}; do
        if systemctl is-failed --quiet rke2-server.service; then
            diagnose_rke2_service_failure "rke2-server.service" "rke2-server" "$rke2_start_time"
            exit 1
        fi
        if systemctl is-active --quiet rke2-server.service && [[ -f /etc/rancher/rke2/rke2.yaml ]]; then
            ready=true
            break
        fi
        run_with_spinner "Waiting for RKE2 to be ready" sleep 10
    done

    if [[ "$ready" == "true" ]]; then
        log_success "RKE2 installation completed and service started."
    else
        diagnose_rke2_service_failure "rke2-server.service" "rke2-server" "$rke2_start_time"
        log_error "[ERROR] RKE2 service did not become ready within 5 minutes. Aborting."
        exit 1
    fi

    # Set KUBECONFIG and secure permissions
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml  PATH=$PATH:/var/lib/rancher/rke2/bin
    chmod 600 /etc/rancher/rke2/rke2.yaml
    grep -q 'KUBECONFIG=/etc/rancher/rke2/rke2.yaml' ~/.bashrc 2>/dev/null || \
        echo "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml  PATH=\$PATH:/var/lib/rancher/rke2/bin" >> ~/.bashrc
    source ~/.bashrc
}


#############################################  AIRGAPPED  ####################################################
install_rke2_airgapped() {
    if systemctl is-active --quiet rke2-server.service; then
        log_success "RKE2 is already installed and running."
        return
    fi

    log "Creating RKE2 configuration directory..."
    sudo mkdir -p /etc/rancher/rke2/

    # Create artifacts directory structure
    local artifacts_dir="${UC_TMP_DIR}/rke2-artifacts"
    mkdir -p "$artifacts_dir"

    # Check if required files exist
    local required_files=("./k8s-airgapped-files/install.sh" "./k8s-airgapped-files/rke2.linux-amd64.tar.gz" "./k8s-airgapped-files/rke2-images-core.linux-amd64.tar.zst" "./k8s-airgapped-files/rke2-images-calico.linux-amd64.tar.zst" "./k8s-airgapped-files/sha256sum-amd64.txt")

    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_error "[ERROR] Required file not found: $file"
            exit 1
        fi
    done

    # Copy files to artifacts directory
    log "Preparing RKE2 artifacts..."
    cp ./k8s-airgapped-files/rke2-images-calico.linux-amd64.tar.zst "$artifacts_dir/"
    cp ./k8s-airgapped-files/rke2-images-core.linux-amd64.tar.zst "$artifacts_dir/"
    cp ./k8s-airgapped-files/rke2.linux-amd64.tar.gz "$artifacts_dir/"
    cp ./k8s-airgapped-files/sha256sum-amd64.txt "$artifacts_dir/"
    cp ./k8s-airgapped-files/install.sh "$artifacts_dir/"

    # Pre-stage images
    log "Pre-staging RKE2 images..."
    sudo mkdir -p /var/lib/rancher/rke2/agent/images/
    sudo mkdir -p /var/lib/longhorn/
    # sudo cp ./k8s-airgapped-files/rke2-images.linux-amd64.tar.zst /var/lib/rancher/rke2/agent/images/
    sudo cp ./k8s-airgapped-files/rke2-images-calico.linux-amd64.tar.zst /var/lib/rancher/rke2/agent/images/
    sudo cp ./k8s-airgapped-files/rke2-images-core.linux-amd64.tar.zst /var/lib/rancher/rke2/agent/images/

    load_container_images


    # In ha-workers mode (3 control-plane + N workers) masters run only the
    # control plane: CriticalAddonsOnly is the RKE2-documented taint for
    # dedicated servers. UC charts do not tolerate it, so no UC pods land here.
    local node_taint_block=""
    if [[ "$(get_deployment_profile)" == "ha-workers" ]]; then
        node_taint_block=$'node-taint:\n  - "CriticalAddonsOnly=true:NoExecute"'
        log "ha-workers deployment: $NODE_TYPE will be tainted CriticalAddonsOnly=true:NoExecute"
    fi

    # Compute kubelet reservations based on node type
    local sys_cpu="500m" sys_mem="1Gi" eviction_mem="2Gi"
    if [[ "$NODE_TYPE" != "single" ]]; then
        sys_cpu="1" sys_mem="2Gi" eviction_mem="2Gi"
    fi

    # Configuration with essential production settings
    if [[ "$NODE_TYPE" == "node1" || "$NODE_TYPE" == "single" ]]; then
        log "Creating production RKE2 config for $NODE_TYPE..."
        sudo tee /etc/rancher/rke2/config.yaml > /dev/null <<EOF
advertise-address: $NODE1
node-ip: $NODE1
tls-san:
  - mastervip
  - $NODE1
  - $VIP
cni:
  - calico
disable:
  - rke2-canal
node-label:
  - "role=control"
${node_taint_block}

# === SPEGEL EMBEDDED REGISTRY MIRROR ===
embedded-registry: true

# === ESSENTIAL PRODUCTION SETTINGS ===
kubelet-arg:
  - "container-log-max-size=10Mi"
  - "container-log-max-files=3"
  - "serialize-image-pulls=false"
  - "system-reserved=cpu=${sys_cpu},memory=${sys_mem},ephemeral-storage=2Gi"
  - "kube-reserved=cpu=500m,memory=1Gi,ephemeral-storage=2Gi"
  - "eviction-hard=memory.available<${eviction_mem},nodefs.available<10%,imagefs.available<10%"

# === API SERVER & ETCD TUNING ===
kube-apiserver-arg:
  - "max-requests-inflight=800"
  - "max-mutating-requests-inflight=400"

etcd-arg:
  - "quota-backend-bytes=4294967296"
EOF
    fi

    if [[ "$NODE_TYPE" == "node2" ]]; then
        log "Creating production RKE2 config for $NODE_TYPE..."
        sudo tee /etc/rancher/rke2/config.yaml > /dev/null <<EOF
server: https://$VIP:9345
token: "$TOKEN"
advertise-address: $NODE2
node-ip: $NODE2
tls-san:
  - mastervip
  - $NODE1
  - $NODE2
  - $VIP
cni:
  - calico
disable:
  - rke2-canal
node-label:
  - "role=control"
${node_taint_block}

# === SPEGEL EMBEDDED REGISTRY MIRROR ===
embedded-registry: true

# === ESSENTIAL PRODUCTION SETTINGS ===
kubelet-arg:
  - "container-log-max-size=10Mi"
  - "container-log-max-files=3"
  - "serialize-image-pulls=false"
  - "system-reserved=cpu=${sys_cpu},memory=${sys_mem},ephemeral-storage=2Gi"
  - "kube-reserved=cpu=500m,memory=1Gi,ephemeral-storage=2Gi"
  - "eviction-hard=memory.available<${eviction_mem},nodefs.available<10%,imagefs.available<10%"

# === API SERVER & ETCD TUNING ===
kube-apiserver-arg:
  - "max-requests-inflight=800"
  - "max-mutating-requests-inflight=400"

etcd-arg:
  - "quota-backend-bytes=4294967296"
EOF
    fi

    if [[ "$NODE_TYPE" == "node3" ]]; then
        log "Creating production RKE2 config for $NODE_TYPE..."
        sudo tee /etc/rancher/rke2/config.yaml > /dev/null <<EOF
server: https://$VIP:9345
token: "$TOKEN"
advertise-address: $NODE3
node-ip: $NODE3
tls-san:
  - mastervip
  - $NODE1
  - $NODE2
  - $NODE3
  - $VIP
cni:
  - calico
disable:
  - rke2-canal
node-label:
  - "role=control"
${node_taint_block}

# === SPEGEL EMBEDDED REGISTRY MIRROR ===
embedded-registry: true

# === ESSENTIAL PRODUCTION SETTINGS ===
kubelet-arg:
  - "container-log-max-size=10Mi"
  - "container-log-max-files=3"
  - "serialize-image-pulls=false"
  - "system-reserved=cpu=${sys_cpu},memory=${sys_mem},ephemeral-storage=2Gi"
  - "kube-reserved=cpu=500m,memory=1Gi,ephemeral-storage=2Gi"
  - "eviction-hard=memory.available<${eviction_mem},nodefs.available<10%,imagefs.available<10%"

# === API SERVER & ETCD TUNING ===
kube-apiserver-arg:
  - "max-requests-inflight=800"
  - "max-mutating-requests-inflight=400"

etcd-arg:
  - "quota-backend-bytes=4294967296"
EOF
    fi

    # Run install using INSTALL_RKE2_ARTIFACT_PATH method
    log "Running RKE2 installation in airgapped mode..."
    chmod +x "$artifacts_dir/install.sh"

    if ! run_with_spinner "Installing RKE2 (airgapped)" env INSTALL_RKE2_ARTIFACT_PATH="$artifacts_dir" "$artifacts_dir/install.sh"; then
        log_error "[ERROR] Failed to install RKE2 using airgapped method using install.sh script. Exiting."
        exit 1
    fi
    log_success "RKE2 binaries installed successfully."

    # Cleanup
    # rm -rf "$artifacts_dir"

    # Enable and configure service (existing logic)
    capture_output systemctl enable rke2-server.service

    log "Starting RKE2 Service. This may take a while ..."
    local rke2_start_time
    rke2_start_time=$(date '+%Y-%m-%d %H:%M:%S')
    if ! run_with_spinner "Starting RKE2 Service" timeout 600 systemctl start rke2-server.service; then
        diagnose_rke2_service_failure "rke2-server.service" "rke2-server" "$rke2_start_time"
        exit 1
    fi

    # Wait for service to be fully ready
    log "Waiting for RKE2 service to be ready..."
    local ready=false
    for i in {1..30}; do
        if systemctl is-failed --quiet rke2-server.service; then
            diagnose_rke2_service_failure "rke2-server.service" "rke2-server" "$rke2_start_time"
            exit 1
        fi
        if systemctl is-active --quiet rke2-server.service && [[ -f /etc/rancher/rke2/rke2.yaml ]]; then
            ready=true
            break
        fi
        run_with_spinner "Waiting for RKE2 to be ready" sleep 10
    done

    if [[ "$ready" == "true" ]]; then
        log_success "RKE2 installation completed and service started."
    else
        diagnose_rke2_service_failure "rke2-server.service" "rke2-server" "$rke2_start_time"
        log_error "[ERROR] RKE2 service did not become ready within 5 minutes. Aborting."
        exit 1
    fi

    # Set KUBECONFIG and secure permissions
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    export PATH=$PATH:/var/lib/rancher/rke2/bin
    chmod 600 /etc/rancher/rke2/rke2.yaml
    grep -q 'KUBECONFIG=/etc/rancher/rke2/rke2.yaml' ~/.bashrc 2>/dev/null || \
        echo "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml" >> ~/.bashrc
    grep -q '/var/lib/rancher/rke2/bin' ~/.bashrc 2>/dev/null || \
        echo "export PATH=\$PATH:/var/lib/rancher/rke2/bin" >> ~/.bashrc
    source ~/.bashrc
    sleep 10
}

# ==================== RKE2 AGENT (WORKER NODE) INSTALLATION ====================
install_rke2_agent_airgapped() {
    if systemctl is-active --quiet rke2-agent.service; then
        log_success "RKE2 Agent is already installed and running."
        return
    fi

    log "Installing RKE2 Agent (worker node) in airgapped mode..."
    sudo mkdir -p /etc/rancher/rke2/

    # Create artifacts directory structure
    local artifacts_dir="${UC_TMP_DIR}/rke2-artifacts"
    mkdir -p "$artifacts_dir"

    # Check if required files exist
    local required_files=("./k8s-airgapped-files/install.sh" "./k8s-airgapped-files/rke2.linux-amd64.tar.gz" "./k8s-airgapped-files/rke2-images-core.linux-amd64.tar.zst" "./k8s-airgapped-files/rke2-images-calico.linux-amd64.tar.zst" "./k8s-airgapped-files/sha256sum-amd64.txt")

    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_error "[ERROR] Required file not found: $file"
            exit 1
        fi
    done

    # The application images (MetalLB, Longhorn, …) live in container-images/.
    # Workers run the MetalLB speaker and the Longhorn manager/instance-manager/
    # engine/CSI DaemonSets, so they need these exactly as much as a
    # control-plane node does — and an airgapped worker has no registry to fall
    # back on. Checked here, before any install work, because
    # load_container_images() below exits hard if the directory is missing.
    local container_images_dir="./k8s-airgapped-files/container-images"
    if [[ ! -d "$container_images_dir" ]] || ! compgen -G "$container_images_dir/*.tar" > /dev/null; then
        log_error "[ERROR] No container image archives found in $container_images_dir."
        log_error "[ERROR] Without them MetalLB and Longhorn pods land in ImagePullBackOff on this worker."
        log_error "[ERROR] Ensure container-images.tar.gz is part of the airgapped bundle on this node."
        exit 1
    fi

    # Copy files to artifacts directory
    log "Preparing RKE2 agent artifacts..."
    cp ./k8s-airgapped-files/rke2-images-calico.linux-amd64.tar.zst "$artifacts_dir/"
    cp ./k8s-airgapped-files/rke2-images-core.linux-amd64.tar.zst "$artifacts_dir/"
    cp ./k8s-airgapped-files/rke2.linux-amd64.tar.gz "$artifacts_dir/"
    cp ./k8s-airgapped-files/sha256sum-amd64.txt "$artifacts_dir/"
    cp ./k8s-airgapped-files/install.sh "$artifacts_dir/"

    # Pre-stage images
    log "Pre-staging RKE2 images for agent..."
    sudo mkdir -p /var/lib/rancher/rke2/agent/images/
    sudo mkdir -p /var/lib/longhorn/
    sudo cp ./k8s-airgapped-files/rke2-images-calico.linux-amd64.tar.zst /var/lib/rancher/rke2/agent/images/
    sudo cp ./k8s-airgapped-files/rke2-images-core.linux-amd64.tar.zst /var/lib/rancher/rke2/agent/images/

    # Stage MetalLB/Longhorn/etc. the same way install_rke2_airgapped() does for
    # control-plane nodes. Must happen before install.sh starts rke2-agent —
    # containerd imports this directory on startup.
    load_container_images

    # Determine worker IP
    local worker_num="${NODE_TYPE//worker/}"
    local worker_var="WORKER${worker_num}"
    local worker_ip="${!worker_var}"

    # Kubelet reservations for worker nodes (multi-node values)
    local sys_cpu="1" sys_mem="2Gi" eviction_mem="2Gi"

    # Create RKE2 agent config
    log "Creating RKE2 agent config for $NODE_TYPE (IP: $worker_ip)..."
    sudo tee /etc/rancher/rke2/config.yaml > /dev/null <<EOF
server: https://$VIP:9345
token: "$TOKEN"
node-ip: $worker_ip
node-label:
  - "role=worker"
  # Longhorn creates default disks only on labelled nodes in ha-workers mode
  - "node.longhorn.io/create-default-disk=true"

# === ESSENTIAL PRODUCTION SETTINGS ===
kubelet-arg:
  - "container-log-max-size=10Mi"
  - "container-log-max-files=3"
  - "serialize-image-pulls=false"
  - "system-reserved=cpu=${sys_cpu},memory=${sys_mem},ephemeral-storage=2Gi"
  - "kube-reserved=cpu=500m,memory=1Gi,ephemeral-storage=2Gi"
  - "eviction-hard=memory.available<${eviction_mem},nodefs.available<10%,imagefs.available<10%"
EOF

    # Install RKE2 as agent type
    log "Running RKE2 agent installation in airgapped mode..."
    chmod +x "$artifacts_dir/install.sh"

    if ! run_with_spinner "Installing RKE2 Agent (airgapped)" env INSTALL_RKE2_ARTIFACT_PATH="$artifacts_dir" INSTALL_RKE2_TYPE="agent" "$artifacts_dir/install.sh"; then
        log_error "[ERROR] Failed to install RKE2 agent using airgapped method. Exiting."
        exit 1
    fi
    log_success "RKE2 agent binaries installed successfully."

    # Configure proxy for RKE2-Agent environment if needed
    if [[ "$USE_PROXY" == true ]]; then
        log "Configuring RKE2-AGENT proxy..."
        capture_output tee /usr/lib/systemd/system/rke2-agent.env > /dev/null <<EOF
HTTP_PROXY=$PROXY
HTTPS_PROXY=$HTTPS_PROXY
FTP_PROXY="$FTP_PROXY"
NO_PROXY=$NO_PROXY
EOF
    fi

    # Enable and start agent service
    capture_output systemctl enable rke2-agent.service

    log "Starting RKE2 Agent Service. This may take a while..."
    local rke2_start_time
    rke2_start_time=$(date '+%Y-%m-%d %H:%M:%S')
    if ! run_with_spinner "Starting RKE2 Agent Service" timeout 600 systemctl start rke2-agent.service; then
        diagnose_rke2_service_failure "rke2-agent.service" "rke2-agent" "$rke2_start_time"
        exit 1
    fi

    # Wait for agent service to be ready
    log "Waiting for RKE2 agent service to be ready..."
    local ready=false
    for i in {1..30}; do
        if systemctl is-failed --quiet rke2-agent.service; then
            diagnose_rke2_service_failure "rke2-agent.service" "rke2-agent" "$rke2_start_time"
            exit 1
        fi
        if systemctl is-active --quiet rke2-agent.service; then
            ready=true
            break
        fi
        run_with_spinner "Waiting for RKE2 Agent to be ready" sleep 10
    done

    if [[ "$ready" == "true" ]]; then
        log_success "RKE2 Agent installation completed and service started."
    else
        diagnose_rke2_service_failure "rke2-agent.service" "rke2-agent" "$rke2_start_time"
        log_error "[ERROR] RKE2 agent service did not become ready within 5 minutes. Aborting."
        exit 1
    fi

    # Set PATH for RKE2 binaries (agents don't have their own kubeconfig by default)
    export PATH=$PATH:/var/lib/rancher/rke2/bin
    grep -q '/var/lib/rancher/rke2/bin' ~/.bashrc 2>/dev/null || \
        echo "export PATH=\$PATH:/var/lib/rancher/rke2/bin" >> ~/.bashrc

    # Install a cluster-admin kubeconfig if one was staged for this worker, so
    # -check/-upgrade can be run locally here over SSH. Generate one on a
    # control-plane node with: ./<script> -export-worker-kubeconfig
    local worker_kubeconfig="./worker-kubeconfig.yaml"
    if [[ -f "$worker_kubeconfig" ]]; then
        log "Found $worker_kubeconfig — installing kubectl access for this worker..."
        sudo mkdir -p /etc/rancher/rke2/
        sudo cp "$worker_kubeconfig" /etc/rancher/rke2/rke2.yaml
        sudo chmod 600 /etc/rancher/rke2/rke2.yaml
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        grep -q 'KUBECONFIG=/etc/rancher/rke2/rke2.yaml' ~/.bashrc 2>/dev/null || \
            echo "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml" >> ~/.bashrc
        log_success "Kubeconfig installed. --check/--upgrade can now be run locally on this worker."
        log_warning "[WARNING] $worker_kubeconfig grants full cluster-admin access — delete it now that it's installed: rm $worker_kubeconfig"
    else
        log_warning "[WARNING] No $worker_kubeconfig found next to the script."
        log_warning "[WARNING] --check/--upgrade will NOT work locally on this worker until you:"
        log_warning "[WARNING]   1. On a control-plane node, run: ./$(basename "$0") --export-worker-kubeconfig"
        log_warning "[WARNING]   2. Copy the resulting worker-kubeconfig.yaml to ${UC_BASE_DIR}/ on this worker"
        log_warning "[WARNING]   3. Re-run this install (or manually copy it to /etc/rancher/rke2/rke2.yaml and set KUBECONFIG)"
    fi

    source ~/.bashrc
    sleep 10
}

# Verify KUBECONFIG
verify_kubeconfig() {
    log "Verifying KUBECONFIG..."
    source ~/.bashrc
    if [[ "$KUBECONFIG" == "/etc/rancher/rke2/rke2.yaml" ]]; then
        log "KUBECONFIG set correctly."
    else
        log "Failed to set KUBECONFIG."
        sleep_for 10
    fi
}

# Check kubectl version
check_kubectl() {
    log "Checking kubectl version..."
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml  PATH=$PATH:/var/lib/rancher/rke2/bin
    if kubectl version --client >> "$LOG_FILE" 2>&1; then
        log "kubectl is functional."
    else
        log "kubectl not functioning properly. Please verify configuration."
        sleep_for 10
    fi
}

# Configure crictl with default runtime endpoint
configure_crictl() {
    log "Configuring crictl with default runtime endpoint..."
    sudo tee /etc/crictl.yaml > /dev/null <<EOF
runtime-endpoint: unix:///run/k3s/containerd/containerd.sock
image-endpoint: unix:///run/k3s/containerd/containerd.sock
timeout: 10
debug: false
EOF
    log "crictl configuration completed."
}

check_kubernetes_cluster_health() {
    local max_retries=30
    local retry_interval=30  # seconds between retries
    local retries=0

    log "Checking Kubernetes cluster health..."
    while [ $retries -lt $max_retries ]; do
        # Check if the Kubernetes API is accessible and nodes are available
        capture_output kubectl get nodes >> "$LOG_FILE" 2>&1
        if [ $? -eq 0 ]; then
            log "Kubernetes cluster is healthy."
            return 0
        else
            retries=$((retries + 1))
            log_error "[ERROR] Kubernetes cluster is not accessible. Attempt $retries/$max_retries."
            if [ $retries -eq $max_retries ]; then
                log_error "[ERROR] Max retries reached. Kubernetes cluster is still not accessible."
                log_error "Please allow the system to stabilize for a few seconds and re-run the script! "
                exit 1
            fi
            log "Retrying in $retry_interval seconds..."
            sleep $retry_interval
        fi
    done
}

retrieve_token(){
    if [[ "$NODE_TYPE" == "node1" || "$NODE_TYPE" == "single" ]]; then

        RKE2_TOKEN=$(cat /var/lib/rancher/rke2/server/token)

        log "RKE2 Token retrieved and saved to config.env"
        log_only "RKE2 Token: $RKE2_TOKEN"

        if grep -q "^TOKEN=" "$CONFIG_FILE_PATH"; then
            sed -i "s|^TOKEN=.*|TOKEN=\"$RKE2_TOKEN\"|" "$CONFIG_FILE_PATH"
        else
            echo "TOKEN=\"$RKE2_TOKEN\"" >> "$CONFIG_FILE_PATH"
        fi

        log_only "TOKEN saved: $(cat "$CONFIG_FILE_PATH" | grep TOKEN)"
    fi
}

# ==================== WORKER KUBECONFIG EXPORT ====================
# Run this on a control-plane node to produce a kubeconfig that can be copied
# to a worker node, so -check/-upgrade can be run locally there via SSH.
# NOTE: this exports the full cluster-admin kubeconfig. Treat the resulting
# file as a credential: transfer it securely and remove it from the worker
# once installed (it gets copied into /etc/rancher/rke2/rke2.yaml there).
export_worker_kubeconfig() {
    local kubeconfig_src="/etc/rancher/rke2/rke2.yaml"

    if [[ ! -f "$kubeconfig_src" ]]; then
        log_error "[ERROR] $kubeconfig_src not found. Run --export-worker-kubeconfig on a control-plane node (node1/node2/node3/single)."
        return 1
    fi

    if [[ -z "$VIP" ]]; then
        log_error "[ERROR] VIP is not set in config.env. Cannot rewrite the kubeconfig's server address."
        return 1
    fi

    local out_file="./worker-kubeconfig.yaml"
    log "Exporting kubeconfig for worker distribution (rewriting server to https://$VIP:6443)..."
    sed "s#server: https://127.0.0.1:6443#server: https://${VIP}:6443#" "$kubeconfig_src" > "$out_file"
    chmod 600 "$out_file"

    log_success "Worker kubeconfig written to $out_file"
    log_warning "[WARNING] This file grants full cluster-admin access — handle it like a credential."
    log_console "${YELLOW}Next steps:${NC}"
    log_console "  1. Copy it to the worker's script directory, e.g.:"
    log_console "     scp $out_file <user>@<worker-ip>:${UC_BASE_DIR}/worker-kubeconfig.yaml"
    log_console "  2. Run the worker install (--airgapped workerN) — it will detect and install this file automatically."
    log_console "  3. Delete $out_file from this node once copied."
    return 0
}

configure_kube_vip() {
    log "Configuring Kube-VIP on $NODE_TYPE with IP: $VIP on $INTERFACE"

    # Create the Kube-VIP manifest
    cat <<EOF > /var/lib/rancher/rke2/server/manifests/kube-vip.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  creationTimestamp: null
  name: kube-vip-ds
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: kube-vip-ds
  template:
    metadata:
      creationTimestamp: null
      labels:
        name: kube-vip-ds
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/master
                operator: Exists
            - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
      containers:
      - args:
        - manager
        env:
        - name: vip_arp
          value: "true"
        - name: port
          value: "6443"
        - name: vip_interface
          value: $INTERFACE
        - name: vip_cidr
          value: "32"
        - name: cp_enable
          value: "true"
        - name: vip_ddns
          value: "false"
        - name: address
          value: $VIP
        image: ghcr.io/kube-vip/kube-vip:v$KUBEVIP_VERSION
        imagePullPolicy: IfNotPresent
        name: kube-vip
        resources: {}
        securityContext:
          capabilities:
            add:
            - NET_ADMIN
            - NET_RAW
            - SYS_TIME
      hostNetwork: true
      serviceAccountName: kube-vip
      tolerations:
      - effect: NoSchedule
        operator: Exists
      - effect: NoExecute
        operator: Exists
  updateStrategy: {}
status:
  currentNumberScheduled: 0
  desiredNumberScheduled: 0
  numberMisscheduled: 0
  numberReady: 0
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-vip
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  name: system:kube-vip-role
rules:
  - apiGroups: [""]
    resources: ["services/status"]
    verbs: ["update"]
  - apiGroups: [""]
    resources: ["services", "endpoints"]
    verbs: ["list","get","watch", "update"]
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["list","get","watch", "update", "patch"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["list", "get", "watch", "update", "create"]
  - apiGroups: ["discovery.k8s.io"]
    resources: ["endpointslices"]
    verbs: ["list","get","watch", "update"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: system:kube-vip-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-vip-role
subjects:
- kind: ServiceAccount
  name: kube-vip
  namespace: kube-system
EOF
    # Restart RKE2 to apply changes
    # systemctl restart rke2-server
}

check_nodes_ready() {
    local node_count="$1"  # minimum number of Ready nodes
    local ready_status="Ready"
    local check_interval=30
    local timeout="${2:-600}"
    local elapsed_time=0
    local ready_nodes

    log "Checking Kubernetes node status (expecting $node_count nodes)..."

    # Test kubectl connectivity first
    if ! timeout 30 kubectl cluster-info >> "$LOG_FILE" 2>&1; then
        log_error "[ERROR] Cannot connect to Kubernetes API server. Check RKE2 service status."
        return 1
    fi

    while true; do
        ready_nodes=$(timeout 30 kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" {count++} END {print count}')

        # -ge, not -eq: workers that joined before node3 must not cause a timeout
        if [[ "${ready_nodes:-0}" -ge "$node_count" ]]; then
        log_success "All $node_count nodes are Ready! (Ready: $ready_nodes)"
        return 0
        else
        log "Ready nodes: $ready_nodes / $node_count. Waiting..."
        elapsed_time=$((elapsed_time + check_interval))
        if [[ "$elapsed_time" -ge "$timeout" ]]; then
            log_error "[ERROR] Timeout reached! Not all nodes became Ready within $timeout seconds."
            log "Current node status:"
            kubectl get nodes -o wide
            return 1
        fi
        sleep_for $check_interval
        fi
    done
}


# Install Helm
install_helm() {
    log "Checking Helm installation..."
    if helm version --short | grep -q "v$HELM_VERSION" >> "$LOG_FILE" 2>&1 ; then
        log "Helm is already installed with target version v$HELM_VERSION."
    else
        log "Installing Helm v$HELM_VERSION..."
        if ! run_with_spinner "Downloading Helm v$HELM_VERSION" curl -LO --connect-timeout 30 --max-time 300 "https://get.helm.sh/helm-v$HELM_VERSION-linux-amd64.tar.gz"; then
            log_error "[ERROR] Failed to download Helm. Check network connectivity."
            exit 1
        fi
        log "Extracting Helm..."
        tar -zxf "helm-v$HELM_VERSION-linux-amd64.tar.gz" >> "$LOG_FILE" 2>&1
        mv linux-amd64/helm /usr/local/bin/
        rm -rf "helm-v$HELM_VERSION-linux-amd64.tar.gz" linux-amd64/
        log_success "Helm installation completed."
        sleep_for 10
    fi
}

install_helm_airgapped() {
    log "Installing Helm from local file..."

    if helm version --short | grep -q "v$HELM_VERSION" >> "$LOG_FILE" 2>&1 ; then
        log "Helm is already installed at the airgapped environment with target version v$HELM_VERSION."
    else
        if [[ ! -f "./k8s-airgapped-files/helm-v${HELM_VERSION}-linux-amd64.tar.gz" ]]; then
            log_error "[ERROR] Helm archive not found: ./k8s-airgapped-files/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
            exit 1
        fi
        log "Extracting Helm archive..."
        tar -zxf "./k8s-airgapped-files/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
        sudo mv linux-amd64/helm /usr/local/bin/
        rm -rf linux-amd64/

        log "Helm installation completed."
    fi
}


check_helm_installed() {
    log "Checking Helm installation..."

    helm version --short >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log_error "[ERROR] Helm is NOT installed or NOT configured correctly."
        return 1
    fi

    log "Helm is installed."
}

# Check and wait for nginx ingress controller to be ready
wait_for_nginx_ingress() {
    log "Waiting for the nginx ingress controller to be ready..."
    while ! kubectl get pods -n kube-system | grep -E "rke2-ingress-nginx-controller-[a-z0-9]+.*Running" >> "$LOG_FILE" 2>&1; do
        run_with_spinner "Waiting for nginx ingress controller" sleep 25
    done
    log_success "nginx ingress controller is ready."

    # Wait for the NGINX ingress admission webhook service to have available endpoints
    while ! kubectl get endpoints -n kube-system rke2-ingress-nginx-controller-admission | grep -qE '\b([0-9]{1,3}\.){3}[0-9]{1,3}:'; do
        run_with_spinner "Waiting for nginx admission webhook" sleep 25
    done
    log_success "nginx ingress controller admission webhook service is ready."
}

# Function to check if all pods in a namespace are running
check_pods_ready() {
    local namespace=$1
    local retries=30
    local delay=30

    log "Checking if all pods in namespace '$namespace' are running..."
    for ((i=1; i<=retries; i++)); do
        local pending_pods
        pending_pods=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | grep -v Running | wc -l)
        if [[ "$pending_pods" -eq 0 ]]; then
            log_success "All pods in namespace '$namespace' are running."
            return 0
        fi
        log "Waiting for pods in namespace '$namespace' to become ready. Retry $i/$retries..."
        run_with_spinner "Checking pod status" sleep "$delay"
    done
    log_error "ERROR: Some pods in namespace '$namespace' are not running after $retries retries."
    return 1
}

# Install nfs-client (openSUSE equivalent of nfs-common)
install_nfs_client() {
    log "Checking if nfs-client is already installed..."
    if rpm -q nfs-client >/dev/null 2>&1; then
        log "nfs-client is already installed."
    else
        log "nfs-client is not installed. Installing now..."
        run_with_spinner "Installing nfs-client" sudo zypper install -y nfs-client
        if rpm -q nfs-client >/dev/null 2>&1; then
            log_success "nfs-client installed successfully."
        else
            log_error "[ERROR] Failed to install nfs-client. Please check the logs for details."
            exit 1
        fi
    fi
}


#############################################  AIRGAPPED  ####################################################
install_nfs_client_airgapped() {
    local pattern="./k8s-airgapped-files/packages/nfs-client-*.rpm"
    local rpm_files=(${pattern})

    if [[ ${#rpm_files[@]} -eq 0 ]] || [[ ! -f "${rpm_files[0]}" ]]; then
        log_warning "[WARNING] No NFS client packages found."
        return 1
    fi

    # Check if already installed
    if rpm -q nfs-client &>/dev/null; then
        log "NFS client is already installed."
        return 0
    fi

    # Get the first matching package
    local rpm_file="${rpm_files[0]}"
    log "Installing NFS client from: $(basename "$rpm_file")"

    if sudo rpm -ivh "$rpm_file" >> "$LOG_FILE" 2>&1; then
        log_success "NFS client installed successfully."
        # Start and enable NFS client services
        sudo systemctl enable nfs-client.target >> "$LOG_FILE" 2>&1
        sudo systemctl start nfs-client.target >> "$LOG_FILE" 2>&1
        return 0
    else
        log_error "[ERROR] NFS client installation failed."
        return 1
    fi
}


install_kernel() {
    log "Checking and enabling iscsi_tcp module..."

    # Install kernel-default-extra package
    if ! rpm -q kernel-default-extra &>/dev/null; then
        log "Installing kernel-default-extra package..."
        run_with_spinner "Installing kernel-default-extra" sudo zypper install -y kernel-default-extra
        log_success "kernel-default-extra installed successfully."
    else
        log "kernel-default-extra package is already installed."
    fi

    # Load iscsi_tcp module
    if ! lsmod | grep -q iscsi_tcp; then
        log "Loading iscsi_tcp kernel module..."
        capture_output sudo modprobe iscsi_tcp
    else
        log "iscsi_tcp module is already loaded."
    fi

    # Ensure module loads on reboot
    if ! grep -q "iscsi_tcp" /etc/modules-load.d/iscsi.conf 2>/dev/null; then
        log "Adding iscsi_tcp module to autoload..."
        echo "iscsi_tcp" | sudo tee -a /etc/modules-load.d/iscsi.conf >> "$LOG_FILE" 2>&1
    fi

    log_success "iSCSI TCP module setup completed."
}


# compare_kernel_versions <v1> <v2>
# Returns 0 (true) if v1 >= v2 (running kernel is same or newer — skip install)
# Returns 1 (false) if v1 < v2 (RPM is newer — proceed with install)
compare_kernel_versions() {
    local v1="$1" v2="$2"
    local highest
    highest=$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | tail -1)
    [[ "$highest" == "$v2" && "$v1" != "$v2" ]] && return 1
    return 0
}

#############################################  AIRGAPPED  ####################################################
install_kernel_airgapped() {
    log "Installing kernel packages from local RPM packages..."

    local packages_dir="./k8s-airgapped-files/packages"

    # Detect OS type
    local is_sles=0
    if grep -qi "SLES\|SUSE Linux Enterprise Server" /etc/os-release 2>/dev/null; then
        is_sles=1
        log "Detected SUSE Linux Enterprise Server (SLES)"
    else
        log "Detected openSUSE"
    fi

    # Find kernel-default package first
    local kernel_base_package=$(find "$packages_dir" -name "kernel-default-[0-9]*.rpm" ! -name "*extra*" ! -name "*devel*" ! -name "*base*" | head -1)

    # Check current kernel version
    local current_kernel=$(uname -r)
    log "Current kernel version: $current_kernel"
    # Normalize: strip the "-default" arch suffix so it can be compared to RPM VERSION-RELEASE
    local current_kernel_ver="${current_kernel%-default}"

    # Install kernel-default first (if found and not already installed)
    if [[ -n "$kernel_base_package" ]]; then
        log "Found kernel base package: $kernel_base_package"

        # Compare RPM version against running kernel — skip if running kernel is same or newer
        local pkg_ver=$(rpm -qp --queryformat '%{VERSION}-%{RELEASE}' "$kernel_base_package" 2>/dev/null)
        if compare_kernel_versions "$current_kernel_ver" "$pkg_ver"; then
            log_warning "[WARNING] Running kernel ($current_kernel_ver) is the same or newer than the available package ($pkg_ver). Skipping kernel-default installation."
        else
            # Check if this exact kernel version is already installed
            local package_name=$(rpm -qp --queryformat '%{NAME}-%{VERSION}-%{RELEASE}' "$kernel_base_package" 2>/dev/null)

            if rpm -q "$package_name" &> /dev/null; then
                log "Kernel base package is already installed: $package_name"
            else
                log "Installing kernel base package: $kernel_base_package"
                sudo rpm -ivh "$kernel_base_package" >> "$LOG_FILE" 2>&1

                if [[ $? -eq 0 ]]; then
                    log "Kernel base package installed successfully."
                    log "NOTE: System reboot may be required to use the new kernel."
                else
                    log_error "[ERROR] Kernel base package installation failed."
                    return 1
                fi
            fi
        fi
    else
        log_warning "[WARNING] No kernel-default package found in $packages_dir"
    fi

    # Install OS-specific kernel packages
    if [[ $is_sles -eq 1 ]]; then
        # SLES: Install kernel-default-devel and kernel-default-base
        log "Installing SLES-specific kernel packages (kernel-default-devel, kernel-default-base)..."

        local kernel_devel_package=$(find "$packages_dir" -name "kernel-default-devel-*.rpm" | head -1)
        local kernel_base_module=$(find "$packages_dir" -name "kernel-default-base-*.rpm" | head -1)

        if [[ -n "$kernel_devel_package" ]]; then
            log "Found kernel-default-devel package: $kernel_devel_package"
            local devel_pkg_ver=$(rpm -qp --queryformat '%{VERSION}-%{RELEASE}' "$kernel_devel_package" 2>/dev/null)
            if compare_kernel_versions "$current_kernel_ver" "$devel_pkg_ver"; then
                log_warning "[WARNING] Running kernel ($current_kernel_ver) is the same or newer than available devel package ($devel_pkg_ver). Skipping kernel-default-devel installation."
            elif ! rpm -q kernel-default-devel &> /dev/null; then
                log "Installing kernel-default-devel..."
                sudo rpm -ivh "$kernel_devel_package" >> "$LOG_FILE" 2>&1
                [[ $? -eq 0 ]] && log "Kernel devel package installed successfully." || log_warning "[WARNING] Kernel devel installation failed."
            else
                log "Kernel-default-devel is already installed."
            fi
        else
            log_warning "[WARNING] No kernel-default-devel package found"
        fi

        if [[ -n "$kernel_base_module" ]]; then
            log "Found kernel-default-base package: $kernel_base_module"
            local base_pkg_ver=$(rpm -qp --queryformat '%{VERSION}-%{RELEASE}' "$kernel_base_module" 2>/dev/null)
            if compare_kernel_versions "$current_kernel_ver" "$base_pkg_ver"; then
                log_warning "[WARNING] Running kernel ($current_kernel_ver) is the same or newer than available base package ($base_pkg_ver). Skipping kernel-default-base installation."
            elif ! rpm -q kernel-default-base &> /dev/null; then
                log "Installing kernel-default-base..."
                sudo rpm -ivh "$kernel_base_module" >> "$LOG_FILE" 2>&1
                [[ $? -eq 0 ]] && log "Kernel base modules installed successfully." || log_warning "[WARNING] Kernel base modules installation failed."
            else
                log "Kernel-default-base is already installed."
            fi
        else
            log_warning "[WARNING] No kernel-default-base package found"
        fi
    else
        # openSUSE: Install kernel-default-extra
        local kernel_extra_package=$(find "$packages_dir" -name "kernel-default-extra-*.rpm" | head -1)

        if [[ -n "$kernel_extra_package" ]]; then
            log "Found kernel extra package: $kernel_extra_package"
            local extra_pkg_ver=$(rpm -qp --queryformat '%{VERSION}-%{RELEASE}' "$kernel_extra_package" 2>/dev/null)
            if compare_kernel_versions "$current_kernel_ver" "$extra_pkg_ver"; then
                log_warning "[WARNING] Running kernel ($current_kernel_ver) is the same or newer than available extra package ($extra_pkg_ver). Skipping kernel-default-extra installation."
            elif rpm -q kernel-default-extra &> /dev/null; then
                log "Kernel extras are already installed."
            else
                log "Installing kernel extras from: $kernel_extra_package"
                sudo rpm -ivh "$kernel_extra_package" >> "$LOG_FILE" 2>&1

                if [[ $? -eq 0 ]]; then
                    log "Kernel extras installed successfully."
                else
                    log_error "[ERROR] Kernel extras installation failed."
                    return 1
                fi
            fi
        else
            log_warning "[WARNING] No kernel-default-extra package found in $packages_dir"
            return 1
        fi
    fi

    log "Kernel installation process completed."
}


install_iscsi() {
  # Add SUSE:SLE-15:Update repo if missing to get open-iscsi package
#   if ! zypper repos | grep -q 'SUSE:SLE-15:Update'; then
#     echo "Adding SUSE:SLE-15:Update repository..."
#     sudo zypper addrepo https://download.opensuse.org/repositories/SUSE:SLE-15:Update/SLE_15_SP7/SUSE:SLE-15:Update.repo
#     sudo zypper refresh
#   fi

  log "Refreshing package repositories..."
  log_only "Running: zypper refresh"
  sudo zypper refresh >> "$LOG_FILE" 2>&1

  # Install open-iscsi and yast2-iscsi-client if not already installed
  if ! rpm -q open-iscsi > /dev/null 2>&1; then
    log "Installing iSCSI initiator packages..."
    log_only "Installing open-iscsi and yast2-iscsi-client"
    sudo zypper install -y open-iscsi yast2-iscsi-client >> "$LOG_FILE" 2>&1
    sleep 10
    if ! command -v iscsiadm > /dev/null 2>&1; then
      log_error "Failed to install open-iscsi."
      return 1
    fi
    log_success "iSCSI initiator installed successfully."
  else
    log "iSCSI initiator already installed."
  fi
}

#############################################  AIRGAPPED  ####################################################
install_iscsi_airgapped() {
    log "Installing iSCSI initiator from local RPM packages..."

    # Function to find and install RPM packages
    install_rpm_package() {
        local package_pattern="$1"
        local package_name="$2"

        # Find the first matching package
        local rpm_file=$(ls ${package_pattern} 2>/dev/null | head -n1)

        if [[ -z "$rpm_file" ]]; then
            log_warning "[WARNING] No ${package_name} package found matching pattern: ${package_pattern}"
            return 1
        fi

        log "Found ${package_name} package: $(basename "$rpm_file")"

        # Check if already installed
        if rpm -q "${package_name}" &>/dev/null; then
            log "${package_name} is already installed."
            return 0
        fi

        # Install the package
        log "Installing ${package_name} from: $(basename "$rpm_file")"
        rpm -ivh "$rpm_file" >> "$LOG_FILE" 2>&1

        if [[ $? -eq 0 ]]; then
            log_success "${package_name} installed successfully."
            return 0
        else
            log_error "[ERROR] ${package_name} installation failed."
            return 1
        fi
    }

    # Install libopeniscsiusr0 first (dependency for open-iscsi)
    if ! install_rpm_package "./k8s-airgapped-files/packages/libopeniscsiusr0-*.rpm" "libopeniscsiusr0"; then
        return 1
    fi

    # Install open-iscsi
    if ! install_rpm_package "./k8s-airgapped-files/packages/open-iscsi-*.rpm" "open-iscsi"; then
        return 1
    fi

    log_success "iSCSI initiator installation completed."
}


# Function to install, enable, and start iSCSI services
enable_and_start_iscsi() {
    log "Configuring iSCSI services..."
    log_only "Loading iscsi_tcp kernel module..."
    sudo modprobe iscsi_tcp 2>> "$LOG_FILE"
    if ! grep -q ^iscsi_tcp /etc/modules-load.d/iscsi.conf 2>/dev/null; then
        echo "iscsi_tcp" | sudo tee -a /etc/modules-load.d/iscsi.conf >> "$LOG_FILE" 2>&1
    fi

    log_only "Enabling and starting iscsid.service and iscsid.socket..."
    # Enable and start iscsid service
    sudo systemctl enable iscsid.service >> "$LOG_FILE" 2>&1
    sudo systemctl start iscsid.service >> "$LOG_FILE" 2>&1

    # Enable and start iscsid socket
    sudo systemctl enable iscsid.socket >> "$LOG_FILE" 2>&1
    sudo systemctl start iscsid.socket >> "$LOG_FILE" 2>&1

    # Check the status of both services
    log_only "Checking the status of iscsid.service..."
    sudo systemctl status iscsid.service >> "$LOG_FILE" 2>&1

    log_only "Checking the status of iscsid.socket..."
    sudo systemctl status iscsid.socket >> "$LOG_FILE" 2>&1

    log_success "iSCSI services configured and started."
}


# Function to install and verify JQ package
install_jq() {
  command -v jq >> "$LOG_FILE" 2>&1
  if ! [ $? -eq 0 ]; then
    log "Installing jq."
    zypper install -y jq >> "$LOG_FILE" 2>&1 
  else
    log "jq already installed. Skipping installation..."
  fi
}

#############################################  AIRGAPPED  ####################################################
install_jq_airgapped() {
    log "Installing jq from local RPM packages..."

    # Function to find and install the first matching RPM package
    install_rpm_package() {
        local package_pattern="$1"
        local package_name="$2"

        # Find the first matching package
        local rpm_file=$(ls ${package_pattern} 2>/dev/null | head -n1)

        if [[ -z "$rpm_file" ]]; then
            log_warning "[WARNING] No ${package_name} package found matching pattern: ${package_pattern}"
            return 1
        fi

        log "Found ${package_name} package: $(basename "$rpm_file")"

        # Check if already installed
        if rpm -q "${package_name}" &>/dev/null; then
            log "${package_name} is already installed."
            return 0
        fi

        # Install the package
        log "Installing ${package_name} from: $(basename "$rpm_file")"
        rpm -ivh "$rpm_file" >> "$LOG_FILE" 2>&1

        if [[ $? -eq 0 ]]; then
            log_success "${package_name} installed successfully."
            return 0
        else
            log_error "[ERROR] ${package_name} installation failed."
            return 1
        fi
    }

    # Install libonig4 first (dependency for libjq1)
    if ! install_rpm_package "./k8s-airgapped-files/packages/libonig4-*.rpm" "libonig4"; then
        return 1
    fi

    # Install libjq1 second (dependency for jq)
    if ! install_rpm_package "./k8s-airgapped-files/packages/libjq1-*.rpm" "libjq1"; then
        return 1
    fi

    # Install jq last
    if ! install_rpm_package "./k8s-airgapped-files/packages/jq-*.rpm" "jq"; then
        return 1
    fi

    # Verify jq installation
    if command -v jq >/dev/null 2>&1; then
        local jq_version=$(jq --version 2>/dev/null)
        log_success "jq installed and working: $jq_version"
    else
        log_error "[ERROR] jq installation verification failed."
        return 1
    fi
}

# Function to check Calicoctl version
install_calicoctl() {
    log "Checking Calicoctl version..."
    if command -v calicoctl &> /dev/null; then
        calico_version=$(calicoctl version 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            log "Calicoctl version details: $(echo "$calico_version" | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
            echo "$calico_version" >> "$LOG_FILE" 2>&1
        else
            log "Failed to retrieve Calicoctl version. Ensure calicoctl is properly configured."
        fi
    else
        log "Installing calicoctl version v$CALICOCTL_VERSION..."
        if ! curl -L --connect-timeout 30 --max-time 300 "https://github.com/projectcalico/calico/releases/download/v$CALICOCTL_VERSION/calicoctl-linux-amd64" -o calicoctl >> "$LOG_FILE" 2>&1; then
            log_error "[ERROR] Failed to download calicoctl. Check network connectivity."
            return 1
        fi
        chmod +x ./calicoctl
        sudo mv ./calicoctl /usr/bin/
        log "calicoctl v$CALICOCTL_VERSION installed successfully."
    fi
}

#############################################  AIRGAPPED  ####################################################
install_calicoctl_airgapped() {
    log "Installing calicoctl from local file..."

    if [[ ! -f "./k8s-airgapped-files/calicoctl" ]]; then
        log_error "[ERROR] calicoctl binary not found."
        exit 1
    fi

    if command -v calicoctl &> /dev/null; then
        log "Calicoctl is already installed."
        return
    fi

    sudo cp ./k8s-airgapped-files/calicoctl /usr/bin/
    sudo chmod +x /usr/bin/calicoctl
    log "calicoctl installed successfully."
}

# Function to install AWS CLI
install_aws_cli() {
    if [[ "$INSTALL_AWS_CLI" =~ ^[Yy]$ ]]; then
        log "Checking AWS CLI installation..."

        if command -v aws &> /dev/null; then
            log "AWS CLI is already installed. Skipping installation."
            return
        fi

        log "AWS CLI not found. Installing AWS CLI..."
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" >> "$LOG_FILE" 2>&1
        if [ $? -ne 0 ]; then
            log_error "[ERROR] Failed to download AWS CLI. Please check your network or the download URL."
            return
        fi

        unzip awscliv2.zip &>/dev/null
        if [ $? -ne 0 ]; then
            log_error "[ERROR] Failed to unzip AWS CLI package. Please ensure 'unzip' is installed."
            return
        fi

        sudo ./aws/install &>/dev/null
        if [ $? -eq 0 ]; then
            log "AWS CLI installed successfully."
        else
            log_error "[ERROR] AWS CLI installation failed. Please check the logs for more details."
            return
        fi

        # Clean up installation files
        rm -rf awscliv2.zip aws
        log "Cleaned up AWS CLI installation files."
    fi
}


#############################################  AIRGAPPED  ####################################################
install_aws_cli_airgapped() {
    if [[ "$INSTALL_AWS_CLI" =~ ^[Yy]$ ]]; then
        log "Installing AWS CLI from local file..."

        if [[ ! -f "./k8s-airgapped-files/awscliv2.zip" ]]; then
            log_warning "[WARNING] AWS CLI archive not found. Skipping installation."
            return
        fi

        if command -v aws &> /dev/null; then
            log "AWS CLI is already installed."
            return
        fi

        unzip ./k8s-airgapped-files/awscliv2.zip >> "$LOG_FILE" 2>&1
        sudo ./aws/install >> "$LOG_FILE" 2>&1
        rm -rf aws
        log "AWS CLI installed successfully."
    fi
}

install_metallb() {
    log "Creating MetalLB namespace..."
    if ! kubectl get namespace metallb-system >> "$LOG_FILE" 2>&1; then
        kubectl create namespace metallb-system >> "$LOG_FILE" 2>&1 || true
    fi

    log "Checking if MetalLB is installed..."
    if kubectl get deployments -n metallb-system | grep -q 'controller'; then
        log "MetalLB is already installed. Skipping..."
        return
    fi

    log "Installing MetalLB..."
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v$METALLB_VERSION/config/manifests/metallb-native.yaml -n metallb-system >> "$LOG_FILE" 2>&1

    # Wait for MetalLB CRDs to be installed
    log "Waiting for MetalLB CRDs to be installed..."
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if kubectl get crd ipaddresspools.metallb.io >> "$LOG_FILE" 2>&1; then
            log_success "MetalLB CRDs are installed."
            break
        fi
        attempt=$((attempt + 1))
        if [ $attempt -eq $max_attempts ]; then
            log_error "[ERROR] MetalLB CRDs failed to install after $max_attempts attempts."
            return 1
        fi
        sleep 2
    done

    # Wait for MetalLB controller deployment to be available
    log "Waiting for MetalLB controller deployment..."
    kubectl wait --for=condition=available deployment/controller -n metallb-system --timeout=300s >> "$LOG_FILE" 2>&1

    # Wait for MetalLB speaker daemonset to be ready
    log "Waiting for MetalLB speaker daemonset..."
    kubectl rollout status daemonset/speaker -n metallb-system --timeout=300s >> "$LOG_FILE" 2>&1

    if kubectl get pods -n metallb-system | grep -q 'Running'; then
        log_success "MetalLB is up and running."
    else
        log_error "[ERROR] MetalLB pods are not running as expected."
    fi
}

#############################################  AIRGAPPED  ####################################################
install_metallb_airgapped() {
    log "Creating MetalLB namespace..."
    if ! kubectl get namespace metallb-system >> "$LOG_FILE" 2>&1; then
        kubectl create namespace metallb-system >> "$LOG_FILE" 2>&1
    fi

    if kubectl get deployments -n metallb-system | grep -q 'controller'; then
        log "MetalLB is already installed. Skipping..."
        return
    fi

    # Use the static YAML method instead of Helm for MetalLB in airgapped
    # You'll need to download the YAML file beforehand
    if [[ ! -f "./k8s-airgapped-files/metallb-native.yaml" ]]; then
        log_error "[ERROR] MetalLB YAML manifest not found."
        exit 1
    fi

    log "Installing MetalLB from local manifest..."
    kubectl apply -f ./k8s-airgapped-files/metallb-native.yaml -n metallb-system >> "$LOG_FILE" 2>&1

    # Wait for MetalLB CRDs to be installed
    log "Waiting for MetalLB CRDs to be installed..."
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if kubectl get crd ipaddresspools.metallb.io >> "$LOG_FILE" 2>&1; then
            log_success "MetalLB CRDs are installed."
            break
        fi
        attempt=$((attempt + 1))
        if [ $attempt -eq $max_attempts ]; then
            log_error "[ERROR] MetalLB CRDs failed to install after $max_attempts attempts."
            return 1
        fi
        sleep 2
    done

    # Wait for MetalLB controller deployment to be available
    log "Waiting for MetalLB controller deployment..."
    kubectl wait --for=condition=available deployment/controller -n metallb-system --timeout=300s >> "$LOG_FILE" 2>&1

    # Wait for MetalLB speaker daemonset to be ready
    log "Waiting for MetalLB speaker daemonset..."
    kubectl rollout status daemonset/speaker -n metallb-system --timeout=300s >> "$LOG_FILE" 2>&1
}

# Configure MetalLB IP pool
configure_metallb_ip_pool() {
    log "Configuring MetalLB IP pool [$ARGUMENT_TYPE]..."
    METALLB_IP_POOL_FILE="metallb-ippool.yaml"
    METALLB_IP_ADVERTISEMENT_FILE="metallb-ipadvertisement.yaml"

    if ! kubectl get ipaddresspool ucpool -n metallb-system >> "$LOG_FILE" 2>&1; then
        cat <<EOF | sudo tee "$METALLB_IP_POOL_FILE" > /dev/null
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ucpool
  namespace: metallb-system
spec:
  addresses:
    - $SERVICE_POOL_RANGE
EOF
        kubectl apply -f "$METALLB_IP_POOL_FILE"

        cat <<EOF | sudo tee "$METALLB_IP_ADVERTISEMENT_FILE" > /dev/null
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ucpool-adv
  namespace: metallb-system
spec:
  ipAddressPools:
  - ucpool
EOF
        kubectl apply -f "$METALLB_IP_ADVERTISEMENT_FILE"
        log "MetalLB IP pool and advertisement configured successfully."
    else
        log "MetalLB IP pool already exists."
    fi
}

# Function to convert IPv4 string to integer
ip_to_int() {
    local ip="$1"
    IFS=. read -r o1 o2 o3 o4 <<< "$ip"
    # Use bit shifts for efficient calculation (o1*2^24 + o2*2^16 + o3*2^8 + o4)
    echo $(( (o1 * 16777216) + (o2 * 65536) + (o3 * 256) + o4 ))
}

# Function to convert integer to IPv4 string
int_to_ip() {
    local ip_int="$1"
    local o4=$((ip_int % 256))
    ip_int=$((ip_int / 256))
    local o3=$((ip_int % 256))
    ip_int=$((ip_int / 256))
    local o2=$((ip_int % 256))
    local o1=$((ip_int / 256))
    echo "$o1.$o2.$o3.$o4"
}

# Configure Calico IP pool
configure_calico_ip_pool() {
    log "Configuring Calico IP pool (encap mode: $CALICO_ENCAP_MODE, MTU: $CALICO_MTU)..."
    CALICO_IP_POOL_FILE="${UC_TMP_DIR}/calico-ippool.yaml"
    # ucpool is for the media servers (ucmsN) only; all other UC pods use the default pod pool.
    # natOutgoing: false - RTP must leave with the pod IP announced, not the node IP.
    # Only pods whose IP MetalLB announces may use this pool.
    # blockSize: 32 - one block per IP so each pod's route follows it to its node (multi-node).
    #   Immutable after creation.
    if ! kubectl get ippool ucpool >> "$LOG_FILE" 2>&1; then
        cat <<EOF | sudo tee "$CALICO_IP_POOL_FILE" > /dev/null
apiVersion: crd.projectcalico.org/v1
kind: IPPool
metadata:
  name: ucpool
spec:
  cidr: $CALICO_IP_POOL
  blockSize: 32
  natOutgoing: false
  nodeSelector: '!all()'
  vxlanMode: $CALICO_ENCAP_MODE
  allowedUses:
    - Workload
    - LoadBalancer
EOF
        kubectl apply -f "$CALICO_IP_POOL_FILE"
        log "Calico IP pool configured successfully."

        # Configure Calico VXLAN MTU if set (non-zero)
        if [[ "$CALICO_MTU" != "0" && -n "$CALICO_MTU" ]]; then
            log "Setting Calico VXLAN MTU to $CALICO_MTU..."
            if kubectl get felixconfiguration default >> "$LOG_FILE" 2>&1; then
                kubectl patch felixconfiguration default --type=merge \
                    -p "{\"spec\":{\"vxlanMTU\":$CALICO_MTU}}" >> "$LOG_FILE" 2>&1 \
                    && log "Calico VXLAN MTU set to $CALICO_MTU." \
                    || log_warning "[WARNING] Could not set Calico MTU. Set manually via felixconfiguration."
            else
                log_warning "[WARNING] felixconfiguration/default not found yet. MTU will need to be set after Calico is fully running."
            fi
        fi


        # Set strictAffinity to false in IPAMConfig
        log "Configuring Calico strictAffinity..."
        CALICO_STRICTAFFINITY_FILE="calico-strictaffinity.yaml"
            cat <<EOF | sudo tee "$CALICO_STRICTAFFINITY_FILE" > /dev/null
apiVersion: crd.projectcalico.org/v1
kind: IPAMConfig
metadata:
  name: default
spec:
  autoAllocateBlocks: true
  strictAffinity: false
EOF
        kubectl apply -f "$CALICO_STRICTAFFINITY_FILE"
        log "Calico strictAffinity configured successfully."


        # Set IPReservation for the nodes
        log "Configuring Calico IPReservation..."

        # Parse the service pool range (split by '-')
        IFS=- read -r start_ip end_ip <<< "$SERVICE_POOL_RANGE"

        # Convert start and end IPs to their integer representations
        start_int=$(ip_to_int "$start_ip")
        end_int=$(ip_to_int "$end_ip")

        # --- Basic Validation ---
        if [[ "$end_int" -lt "$start_int" ]]; then
            log "Error: End IP ($end_ip) is less than Start IP ($start_ip) in SERVICE_POOL_RANGE."
            exit 1
        fi

        # --- Generate the list of IPs in YAML format ---
        RESERVED_IPS_YAML=""
        log "Generating list of IPs from range $SERVICE_POOL_RANGE..."
        for ((i=start_int; i<=end_int; i++)); do
            current_ip=$(int_to_ip "$i")
            # Append with correct indentation and '/32' CIDR notation
            RESERVED_IPS_YAML+="    - $current_ip/32"$'\n'
        done
        log "Finished generating IP list."

        # --- Construct and Apply the IPReservation YAML ---
        CALICO_IPRESERVATION_FILE="calico-ipreservation.yaml"
        log "Creating Calico IPReservation manifest at $CALICO_IPRESERVATION_FILE..."

        # Use a here-document to create the YAML file, embedding the generated list
        if [[ $NODES_NUMBER -gt 1 ]]; then
            cat <<EOF | sudo tee "$CALICO_IPRESERVATION_FILE" > /dev/null
apiVersion: projectcalico.org/v3
kind: IPReservation
metadata:
  name: my-ipreservation
spec:
  reservedCIDRs:
    # Fixed IPs/Subnets to reserve
    - $NODE1/32
    - $NODE2/32
    - $NODE3/32
    - $VIP/32
    # IPs from the SERVICE_POOL_RANGE expanded to /32 CIDRs
$RESERVED_IPS_YAML
EOF
        else
            cat <<EOF | sudo tee "$CALICO_IPRESERVATION_FILE" > /dev/null
apiVersion: projectcalico.org/v3
kind: IPReservation
metadata:
  name: my-ipreservation
spec:
  reservedCIDRs:
    # Fixed IPs/Subnets to reserve
    - $NODE1/32
    - $VIP/32
    # IPs from the SERVICE_POOL_RANGE expanded to /32 CIDRs
$RESERVED_IPS_YAML
EOF
        fi
        # Apply the IPReservation configuration
        log "Applying Calico IPReservation configuration..."
        calicoctl apply -f "$CALICO_IPRESERVATION_FILE"

        log "Calico IPReservation configured successfully."

    else
        log "Calico IP pool already exists."
        if [[ "$(kubectl get ippool ucpool -o jsonpath='{.spec.natOutgoing}' 2>/dev/null)" == "true" ]]; then
            log "ucpool has natOutgoing: true - media server RTP is sent from the node IP."
            # Only safe when no non-media-server pod holds a ucpool IP: without NAT, replies to
            # pod IPs that MetalLB does not announce never come back.
            local pool_cidr pool_net pool_bits pool_start pool_end ip_int blocking_pods=""
            pool_cidr=$(kubectl get ippool ucpool -o jsonpath='{.spec.cidr}' 2>/dev/null)
            IFS=/ read -r pool_net pool_bits <<< "$pool_cidr"
            pool_start=$(ip_to_int "$pool_net")
            pool_end=$(( pool_start + (1 << (32 - pool_bits)) - 1 ))
            while read -r ns name ip host_net; do
                [[ -z "$ip" || "$host_net" == "true" || "$name" == ucms* ]] && continue
                ip_int=$(ip_to_int "$ip")
                if (( ip_int >= pool_start && ip_int <= pool_end )); then
                    blocking_pods+="$ns/$name($ip) "
                fi
            done < <(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.podIP}{" "}{.spec.hostNetwork}{"\n"}{end}' 2>/dev/null)

            if [[ -n "$blocking_pods" ]]; then
                log_warning "[WARNING] Not disabling natOutgoing on ucpool - these non-media-server pods use it: $blocking_pods"
                log_warning "[WARNING] Move them to the default pool, then run: kubectl patch ippool ucpool --type=merge -p '{\"spec\":{\"natOutgoing\":false}}'"
            elif ! dry_run_guard "Patch ucpool natOutgoing to false"; then
                if kubectl patch ippool ucpool --type=merge -p '{"spec":{"natOutgoing":false}}' >> "$LOG_FILE" 2>&1; then
                    log_success "ucpool natOutgoing set to false."
                else
                    log_warning "[WARNING] Could not patch ucpool natOutgoing. Run manually: kubectl patch ippool ucpool --type=merge -p '{\"spec\":{\"natOutgoing\":false}}'"
                fi
            fi
        fi
        if [[ "$(kubectl get ippool ucpool -o jsonpath='{.spec.blockSize}' 2>/dev/null)" != "32" && $NODES_NUMBER -gt 1 ]]; then
            log_warning "[WARNING] ucpool blockSize is not 32 - media server IPs may be misrouted across nodes. blockSize is immutable; recreate ucpool to change it."
        fi
    fi

}

# Install Longhorn
install_longhorn() {
    local longhorn_namespace="longhorn-system"
    local longhorn_chart="longhorn/longhorn"

    log "Adding Longhorn Helm repository..."
    helm repo add longhorn https://charts.longhorn.io >> "$LOG_FILE" 2>&1
    helm repo update >> "$LOG_FILE" 2>&1

    log "Creating Longhorn namespace..."
    if ! kubectl get namespace "$longhorn_namespace" >> "$LOG_FILE" 2>&1; then
        kubectl create namespace "$longhorn_namespace" >> "$LOG_FILE" 2>&1
    fi

    log "Checking if Longhorn is already installed..."
    if kubectl get deployments -n "$longhorn_namespace" | grep -q 'longhorn-manager'; then
        log "Longhorn is already installed. Skipping..."
        return
    fi

    log "Installing Longhorn..."
    local longhorn_replicas=2
    local longhorn_im_cpu="${LONGHORN_INSTANCE_MANAGER_CPU:-12}"
    if [[ "$NODE_TYPE" == "single" ]]; then
        longhorn_replicas=1
        [[ -z "$LONGHORN_INSTANCE_MANAGER_CPU" ]] && longhorn_im_cpu=8
    fi
    # ha-workers: masters (150GB) hold no Longhorn data — default disks are
    # created only on nodes labelled node.longhorn.io/create-default-disk=true
    # (set by install_rke2_agent_airgapped on every worker).
    local longhorn_extra_args=()
    if [[ "$(get_deployment_profile)" == "ha-workers" ]]; then
        longhorn_extra_args+=(--set-string defaultSettings.createDefaultDiskLabeledNodes=true)
    fi
    helm install longhorn "$longhorn_chart" \
        --namespace "$longhorn_namespace" \
        --version "$LONGHORN_VERSION" \
        --set-string defaultSettings.defaultReplicaCount="$longhorn_replicas" \
        --set defaultSettings.defaultDataLocality=best-effort \
        --set-string defaultSettings.guaranteedInstanceManagerCPU="$longhorn_im_cpu" \
        --set-string defaultSettings.storageOverProvisioningPercentage=100 \
        --set-string defaultSettings.storageMinimalAvailablePercentage=15 \
        "${longhorn_extra_args[@]}" >> "$LOG_FILE" 2>&1

    # Wait for Longhorn pods to be ready
    log "Waiting for Longhorn pods to be up and running..."
    kubectl wait --for=condition=ready pod --all -n "$longhorn_namespace" --timeout=300s >> "$LOG_FILE" 2>&1

    if kubectl get pods -n "$longhorn_namespace" | grep -q 'Running'; then
        log "Longhorn pods are up and running."
    else
        log_error "[ERROR] Longhorn pods are not running as expected."
    fi

    # Fix StorageClass with correct parameters for node count
    fix_longhorn_default_storageclass
}

#############################################  AIRGAPPED  ####################################################
install_longhorn_airgapped() {
    local longhorn_namespace="longhorn-system"

    if [[ ! -f "./k8s-airgapped-files/longhorn-${LONGHORN_VERSION}.tgz" ]]; then
        log_error "[ERROR] Longhorn chart archive not found: ./k8s-airgapped-files/longhorn-${LONGHORN_VERSION}.tgz"
        exit 1
    fi

    log "Creating Longhorn namespace..."
    if ! kubectl get namespace "$longhorn_namespace" >> "$LOG_FILE" 2>&1; then
        kubectl create namespace "$longhorn_namespace" >> "$LOG_FILE" 2>&1
    fi

    if kubectl get deployments -n "$longhorn_namespace" | grep -q 'longhorn-manager'; then
        log "Longhorn is already installed. Skipping..."
        return
    fi

    log "Installing Longhorn from local chart..."
    local longhorn_replicas=2
    local longhorn_im_cpu="${LONGHORN_INSTANCE_MANAGER_CPU:-12}"
    if [[ "$NODE_TYPE" == "single" ]]; then
        longhorn_replicas=1
        [[ -z "$LONGHORN_INSTANCE_MANAGER_CPU" ]] && longhorn_im_cpu=8
    fi
    # ha-workers: masters (150GB) hold no Longhorn data — default disks are
    # created only on nodes labelled node.longhorn.io/create-default-disk=true
    # (set by install_rke2_agent_airgapped on every worker).
    local longhorn_extra_args=()
    if [[ "$(get_deployment_profile)" == "ha-workers" ]]; then
        longhorn_extra_args+=(--set-string defaultSettings.createDefaultDiskLabeledNodes=true)
    fi
    helm install longhorn "./k8s-airgapped-files/longhorn-${LONGHORN_VERSION}.tgz" \
        --namespace "$longhorn_namespace" \
        --set-string defaultSettings.defaultReplicaCount="$longhorn_replicas" \
        --set defaultSettings.defaultDataLocality=best-effort \
        --set-string defaultSettings.guaranteedInstanceManagerCPU="$longhorn_im_cpu" \
        --set-string defaultSettings.storageOverProvisioningPercentage=100 \
        --set-string defaultSettings.storageMinimalAvailablePercentage=15 \
        "${longhorn_extra_args[@]}" >> "$LOG_FILE" 2>&1

    # Wait for pods to be ready
    log "Waiting for Longhorn pods to be up and running..."
    kubectl wait --for=condition=ready pod --all -n "$longhorn_namespace" --timeout=300s >> "$LOG_FILE" 2>&1

    if kubectl get pods -n "$longhorn_namespace" | grep -q 'Running'; then
        log "Longhorn pods are up and running."
    else
        log_error "[ERROR] Longhorn pods are not running as expected."
    fi

    # Fix StorageClass with correct parameters for node count
    fix_longhorn_default_storageclass
}

# Function to fix default Longhorn StorageClass with correct replica count and dataLocality
fix_longhorn_default_storageclass() {
    log "Configuring default Longhorn StorageClass..."

    # Determine replicas dynamically from live node count (works for install, upgrade,
    # and scale): 1 node -> 1 replica, 2 nodes -> 2, 3+ nodes -> 3 (Longhorn's own
    # recommended ceiling; more replicas past that just adds write overhead with no
    # real extra protection). Explicit LONGHORN_REPLICAS in config.env still wins if set.
    # Count only nodes that can hold replicas: with createDefaultDiskLabeledNodes
    # (3 masters + workers) Longhorn disks exist only on nodes labelled
    # create-default-disk=true (the workers), so the masters must not be counted
    # — 3 masters + 2 workers would otherwise give 3 replicas and every volume
    # would stay degraded. Without labelled nodes, every node holds replicas.
    local node_count
    node_count=$(kubectl get nodes -l node.longhorn.io/create-default-disk=true --no-headers 2>/dev/null | wc -l)
    if [[ $node_count -eq 0 ]]; then
        # Clusters installed without the label: ask Longhorn which nodes can
        # take replicas (scheduling allowed and at least one schedulable disk).
        node_count=$(kubectl -n longhorn-system get nodes.longhorn.io -o json 2>/dev/null \
            | jq '[.items[] | select(.spec.allowScheduling == true and ([(.spec.disks // {})[] | select(.allowScheduling == true)] | length) > 0)] | length' 2>/dev/null)
        [[ "$node_count" =~ ^[0-9]+$ ]] || node_count=0
    fi
    if [[ $node_count -eq 0 ]]; then
        node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    fi
    local longhorn_replicas=3
    if [[ "$NODE_TYPE" == "single" ]] || [[ $node_count -eq 1 ]]; then
        longhorn_replicas=1
    elif [[ -n "$node_count" && $node_count -gt 0 && $node_count -lt 3 ]]; then
        longhorn_replicas=$node_count
    fi
    longhorn_replicas="${LONGHORN_REPLICAS:-$longhorn_replicas}"
    local longhorn_data_locality="${LONGHORN_DATA_LOCALITY:-best-effort}"

    log "Setting StorageClass parameters: replicas=$longhorn_replicas, dataLocality=$longhorn_data_locality (Longhorn storage nodes=$node_count)"

    # Build the StorageClass YAML
    local sc_yaml
    sc_yaml=$(cat <<SCEOF
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: longhorn
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: "Delete"
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "$longhorn_replicas"
  staleReplicaTimeout: "30"
  fromBackup: ""
  fsType: "ext4"
  dataLocality: "$longhorn_data_locality"
  unmapMarkSnapChainRemoved: "ignored"
  disableRevisionCounter: "true"
  dataEngine: "v1"
SCEOF
    )

    # Patch the ConfigMap so Longhorn doesn't auto-recreate with wrong values
    if kubectl get configmap longhorn-storageclass -n longhorn-system >> "$LOG_FILE" 2>&1; then
        kubectl create configmap longhorn-storageclass -n longhorn-system \
            --from-literal=storageclass.yaml="$sc_yaml" \
            --dry-run=client -o yaml | kubectl apply -f - >> "$LOG_FILE" 2>&1
        log "Updated longhorn-storageclass ConfigMap."
    fi

    # Delete existing StorageClass (parameters are immutable)
    if kubectl get storageclass longhorn >> "$LOG_FILE" 2>&1; then
        log "Removing old default StorageClass 'longhorn'..."
        kubectl delete storageclass longhorn >> "$LOG_FILE" 2>&1
    fi

    # Create the correct StorageClass
    echo "$sc_yaml" | kubectl apply -f - >> "$LOG_FILE" 2>&1

    if kubectl get storageclass longhorn >> "$LOG_FILE" 2>&1; then
        log_success "Default StorageClass 'longhorn' configured (replicas=$longhorn_replicas, dataLocality=$longhorn_data_locality)."
    else
        log_error "[ERROR] Failed to configure default StorageClass 'longhorn'."
    fi
}

# Function to create Longhorn StorageClass for logs (1 replica, best-effort)
create_longhorn_log_storageclass() {
    log "Creating Longhorn log StorageClass (1 replica, strict-local)..."

    # Check if StorageClass already exists
    if kubectl get storageclass longhorn-log >> "$LOG_FILE" 2>&1; then
        log "StorageClass 'longhorn-log' already exists. Skipping..."
        return
    fi

    local log_replicas="${LONGHORN_LOG_REPLICAS:-1}"
    local log_locality="${LONGHORN_LOG_DATA_LOCALITY:-strict-local}"

    log "Creating StorageClass with replicas=$log_replicas, dataLocality=$log_locality"

    cat <<EOF | kubectl apply -f - >> "$LOG_FILE" 2>&1
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-log
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "$log_replicas"
  dataLocality: "$log_locality"
  staleReplicaTimeout: "30"
EOF

    if kubectl get storageclass longhorn-log >> "$LOG_FILE" 2>&1; then
        log_success "StorageClass 'longhorn-log' created successfully."
    else
        log_error "[ERROR] Failed to create StorageClass 'longhorn-log'."
    fi
}

# Function to check if Longhorn is installed and running
check_longhorn() {
    log "Checking if Longhorn is installed and running..."

    # Check if the Longhorn namespace exists
    if kubectl get ns longhorn-system >> "$LOG_FILE" 2>&1; then
        log "Longhorn namespace exists."

        # Check if Longhorn manager pods are running
        if kubectl get pods -n longhorn-system | grep -q "longhorn-manager"; then
            log "Longhorn manager is running."
        else
            log_error "[ERROR] Longhorn manager is NOT running."
        fi
    else
        log_error "[ERROR] Longhorn is NOT installed (longhorn-system namespace not found)."
    fi
}

# Function to check if MetalLB IP pool is correct
check_metallb_ip_pool() {
    log "Checking MetalLB IP pool..."

    # Get the MetalLB IP pool range by extracting the Addresses field
    METALLB_POOL=$(kubectl get ipaddresspool ucpool -n metallb-system -o jsonpath='{.spec.addresses[0]}')

    if [[ "$METALLB_POOL" == "$SERVICE_POOL_RANGE" ]]; then
        log "MetalLB IP pool is correctly configured: $METALLB_POOL"
    else
        log_error "[ERROR] MetalLB IP pool is NOT correctly configured. Expected: $SERVICE_POOL_RANGE, Found: $METALLB_POOL"
    fi
}

# Function to check if Calico IP pool is correct
check_calico_ip_pool() {
    log "Checking Calico IP pool..."

    # Get the Calico IP pool CIDR using kubectl describe and grep
    CALICO_POOL=$(kubectl describe ippool ucpool | grep "Cidr" | awk '{print $2}')

    if [[ "$CALICO_POOL" == "$CALICO_IP_POOL" ]]; then
        log "Calico IP pool is correctly configured: $CALICO_POOL"
    else
        log_error "[ERROR] Calico IP pool is NOT correctly configured. Expected: $CALICO_IP_POOL, Found: $CALICO_POOL"
    fi
}

# User Experience tools, Aliases and Bash Completions.
install_ux_tools() {
    if [[ "$INSTALL_COMPLETION" =~ ^[Yy]$ ]]; then
        if ! rpm -q bash-completion >/dev/null 2>&1; then
            log "Installing bash-completion..."
            log_only "Installing bash-completion using zypper..."
            sudo zypper install -y bash-completion >> "$LOG_FILE" 2>&1
        else
            log "bash-completion is already installed."
        fi

        if ! grep -q "alias k='kubectl'" ~/.bashrc; then
            echo "alias k='kubectl'" >> ~/.bashrc
            log_only "Alias 'k' for 'kubectl' added to ~/.bashrc."
        fi

        source <(kubectl completion bash) 2>/dev/null

        if ! grep -q "source <(kubectl completion bash)" ~/.bashrc; then
            echo "source <(kubectl completion bash)" >> ~/.bashrc
            log_only "kubectl bash completion command added to ~/.bashrc."
        fi

        if ! grep -q "complete -F __start_kubectl k" ~/.bashrc; then
            echo "complete -F __start_kubectl k" >> ~/.bashrc
            log_only "kubectl alias completion command added to ~/.bashrc."
        fi

        source ~/.bashrc 2>/dev/null

        log_success "kubectl alias and bash completion configured."
    fi
}

#############################################  AIRGAPPED  ####################################################
install_ux_tools_airgapped() {
    if [[ "$INSTALL_COMPLETION" =~ ^[Yy]$ ]]; then
        local pattern="./k8s-airgapped-files/packages/bash-completion-*.rpm"
        local rpm_files=(${pattern})

        # Install bash-completion if RPM is available and not already installed
        if [[ ${#rpm_files[@]} -gt 0 ]] && [[ -f "${rpm_files[0]}" ]]; then
            if ! rpm -q bash-completion &>/dev/null; then
                local rpm_file="${rpm_files[0]}"
                log "Installing bash-completion from: $(basename "$rpm_file")"

                if sudo rpm -ivh "$rpm_file" >> "$LOG_FILE" 2>&1; then
                    log_success "bash-completion installed successfully."
                else
                    log_error "[ERROR] Failed to install bash-completion."
                fi
            else
                log "bash-completion is already installed."
            fi
        else
            log_warning "[WARNING] No bash-completion packages found. Skipping RPM install."
        fi

        # Set up kubectl alias
        if ! grep -q "alias k='kubectl'" ~/.bashrc; then
            echo "alias k='kubectl'" >> ~/.bashrc
            log "Alias 'k' for 'kubectl' added to ~/.bashrc."
        fi

        # Set up kubectl completion
        source <(kubectl completion bash)

        if ! grep -q "source <(kubectl completion bash)" ~/.bashrc; then
            echo "source <(kubectl completion bash)" >> ~/.bashrc
            log "kubectl bash completion command added to ~/.bashrc."
        fi

        if ! grep -q "complete -F __start_kubectl k" ~/.bashrc; then
            echo "complete -F __start_kubectl k" >> ~/.bashrc
            log "kubectl alias completion command added to ~/.bashrc."
        fi

        source ~/.bashrc

        log "kubectl alias -> k and Bash completion are now enabled by default."
    fi
}

# ==================== HELP ====================
show_help() {
    local script_name
    script_name=$(basename "$0")
    log_console ""
    log_console "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    log_console "${GREEN}║       Kubernetes Multi-Environment Setup Script v$SCRIPT_VERSION        ║${NC}"
    log_console "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    log_console ""
    log_console "${YELLOW}USAGE:${NC}"
    log_console "  $script_name <mode> [options]"
    log_console ""
    log_console "${YELLOW}INSTALL MODES:${NC}"
    log_console "  ${GREEN}--airgapped single${NC}         Install single-node K8s cluster (airgapped)"
    log_console "  ${GREEN}--airgapped node1${NC}          Install node 1 of 3-node HA cluster"
    log_console "  ${GREEN}--airgapped node2${NC}          Install node 2 of 3-node HA cluster"
    log_console "  ${GREEN}--airgapped node3${NC}          Install node 3 of 3-node HA cluster (full stack; with workers: RKE2 only)"
    log_console "  ${GREEN}--airgapped worker1..${MAX_WORKERS}${NC}    Install worker-only node (agent, no control plane)"
    log_console "  ${GREEN}--airgapped stack${NC}          3 masters + workers only: on node3 AFTER the last worker —"
    log_console "                             installs Helm, MetalLB, Longhorn (safe to re-run)"
    log_console "  ${GREEN}--scale-airgapped node2|3${NC}  Add master node to existing cluster"
    log_console "  ${GREEN}--scale-airgapped worker1..${MAX_WORKERS}${NC} Add worker node to existing cluster"
    log_console "  ${GREEN}--export-worker-kubeconfig${NC} Export a kubeconfig for a worker (run on control-plane node)"
    log_console "  ${GREEN}--import uc [VERSION]${NC}      Import UC container images"
    log_console ""
    log_console "${YELLOW}UPGRADE & ROLLBACK:${NC}"
    log_console "  ${GREEN}--upgrade <component>${NC}      Upgrade a single component"
    log_console "  ${GREEN}--upgrade all${NC}              Upgrade all components (recommended order)"
    log_console "  ${GREEN}--upgrade all --airgapped${NC}  Upgrade all components (airgapped mode)"
    log_console "  ${GREEN}--rollback${NC}                 Rollback to most recent backup"
    log_console "  ${GREEN}--rollback <timestamp>${NC}     Rollback to specific backup (e.g. 20260428-143000)"
    log_console "  ${GREEN}--uninstall${NC}                Remove RKE2 and this script's config from this node"
    log_console ""
    log_console "${YELLOW}INFORMATION & DIAGNOSTICS:${NC}"
    log_console "  ${GREEN}--info${NC}                     Show cluster component versions and status"
    log_console "  ${GREEN}--check${NC}                    Compare installed vs target versions + cert expiry"
    log_console "  ${GREEN}--collect${NC}                  Generate diagnostic bundle for support"
    log_console "  ${GREEN}--help${NC}                     Show this help message"
    log_console ""
    log_console "${YELLOW}FLAGS (combinable, any position):${NC}"
    log_console "  ${GREEN}--dry-run${NC}                  Preview changes without executing"
    log_console "                             Example: $script_name --dry-run --upgrade all"
    log_console "                             Example: $script_name --dry-run --airgapped single"
    log_console "  ${GREEN}--interactive${NC}              Ask the configuration questions and confirmations"
    log_console "                             Example: $script_name --interactive --airgapped node1"
    log_console ""
    log_console "${YELLOW}UNATTENDED BY DEFAULT:${NC}"
    log_console "  Without ${GREEN}--interactive${NC} the script never prompts. Values come from"
    log_console "  config.env (or the built-in defaults), the operation named on the"
    log_console "  command line is auto-confirmed, and optional cleanup is skipped."
    log_console "  A ${RED}failed pre-flight or connectivity check still aborts${NC} — it is not"
    log_console "  overridden silently. Re-run with --interactive to override one."
    log_console ""
    log_console "${YELLOW}UPGRADE COMPONENTS:${NC}"
    log_console "  rke2, helm, calico, metallb, longhorn, kubevip, all"
    log_console ""
    log_console "${YELLOW}UPGRADE ORDER (when using 'all'):${NC}"
    log_console "  1. Helm  →  2. Calico  →  3. MetalLB  →  4. Longhorn  →  5. Kube-VIP  →  6. RKE2"
    log_console ""
    log_console "${YELLOW}PREREQUISITES:${NC}"
    log_console "  • SLES 15 SP7 operating system"
    log_console "  • Root or sudo access"
    log_console "  • config.env in same directory as script"
    log_console "  • For airgapped: k8s-airgapped-files.tar.gz in same directory"
    log_console "  • For upgrades: tmux or screen recommended for SSH sessions"
    log_console ""
    log_console "${YELLOW}CONFIG FILE:${NC}"
    log_console "  config.env — Set target versions, network config, node IPs"
    log_console "  Key variables: RKE2_VERSION, HELM_VERSION, METALLB_VERSION,"
    log_console "  LONGHORN_VERSION, CALICOCTL_VERSION, KUBEVIP_VERSION"
    log_console "  Worker variables: WORKERS_NUMBER (0-${MAX_WORKERS}), WORKER1..WORKER${MAX_WORKERS}"
    log_console ""
    log_console "  ${YELLOW}Optional Performance Variables:${NC}"
    log_console "  MAX_PARALLEL_DIAGNOSTICS     — Diagnostic collection (default: 8)"
    log_console "  MAX_PARALLEL_VERSION_CHECKS  — Version checks (default: 6)"
    log_console "  Higher values = faster operations but more I/O"
    log_console ""
    log_console "${YELLOW}EXAMPLES:${NC}"
    log_console "  $script_name --airgapped single         # Fresh single-node install"
    log_console "  $script_name --airgapped worker1        # Add first worker node"
    log_console ""
    log_console "  3 masters + workers (NODES_NUMBER=3, WORKERS_NUMBER>=1), in this order:"
    log_console "    node1: $script_name --airgapped node1"
    log_console "    node2: $script_name --airgapped node2"
    log_console "    node3: $script_name --airgapped node3"
    log_console "    each worker: $script_name --airgapped worker1, worker2, ..."
    log_console "    node3: $script_name --airgapped stack  # LAST: after the final worker"
    log_console ""
    log_console "  $script_name --scale-airgapped worker2  # Scale: add second worker"
    log_console "  $script_name --check                    # Check what needs upgrading"
    log_console "  $script_name --import uc V11R1.1.0-040100   # Import UC images for a specific version"
    log_console "  $script_name --upgrade longhorn         # Upgrade Longhorn only"
    log_console "  $script_name --rollback                 # Rollback last upgrade"
    log_console "  $script_name --collect                  # Generate support bundle"
    log_console "  $script_name --dry-run --uninstall      # Preview what an uninstall would remove"
    log_console ""
    log_console "${YELLOW}MULTI-NODE ROLLOUT:${NC}"
    log_console "  deploy_cluster-V${SCRIPT_VERSION}.sh is released together with this script (same"
    log_console "  version). Run it from one node (e.g. control01) to copy the files to every"
    log_console "  node and drive firewall / uninstall / install / import on the workers over SSH."
    log_console "  It refuses to run a setup script whose version does not match its own."
    log_console "    ./deploy_cluster-V${SCRIPT_VERSION}.sh --help"
    log_console ""
}

# ==================== VERSION CHECK ====================
check_versions() {
    log_console ""
    log_console "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    log_console "${GREEN}║               VERSION CHECK & CLUSTER HEALTH                  ║${NC}"
    log_console "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    log_console ""

    # Check if kubectl is available
    if ! command -v kubectl &>/dev/null; then
        log_warning "[WARNING] kubectl not found. Showing target versions only."
    fi

    log_console "${YELLOW}Component Versions:${NC}"
    log_console "  ┌──────────────┬─────────────────────────┬─────────────────────────┬────────────┐"
    log_console "  │ Component    │ Installed               │ Target (config.env)     │ Status     │"
    log_console "  ├──────────────┼─────────────────────────┼─────────────────────────┼────────────┤"

    local components=("rke2" "helm" "calico" "metallb" "longhorn" "kubevip")
    local targets=("$RKE2_VERSION" "$HELM_VERSION" "$CALICOCTL_VERSION" "$METALLB_VERSION" "$LONGHORN_VERSION" "$KUBEVIP_VERSION")
    local names=("RKE2" "Helm" "Calico" "MetalLB" "Longhorn" "Kube-VIP")

    for i in "${!components[@]}"; do
        local comp="${components[$i]}"
        local name="${names[$i]}"
        local target="${targets[$i]}"
        local installed
        installed=$(get_current_version "$comp" 2>/dev/null)

        local status_icon status_color
        if [[ -z "$installed" || "$installed" == "unknown" ]]; then
            status_icon="? Not installed"
            status_color="$RED"
        else
            # Strip v prefix for comparison
            local inst_clean="${installed#v}"
            local tgt_clean="${target#v}"
            if [[ "$inst_clean" == "$tgt_clean" ]]; then
                status_icon="✓ Match"
                status_color="$GREEN"
            elif version_gte "$tgt_clean" "$inst_clean" && [[ "$inst_clean" != "$tgt_clean" ]]; then
                status_icon="↑ Upgrade"
                status_color="$YELLOW"
            else
                status_icon="✗ Downgrade"
                status_color="$RED"
            fi
        fi

        printf "  │ %-12s │ %-23s │ %-23s │ ${status_color}%-10s${NC} │\n" \
            "$name" "${installed:-N/A}" "$target" "$status_icon"
    done

    log_console "  └──────────────┴─────────────────────────┴─────────────────────────┴────────────┘"
    log_console ""

    # Certificate expiry check
    check_certificates

    # Node health
    if command -v kubectl &>/dev/null && kubectl get nodes &>/dev/null 2>&1; then
        log_console ""
        log_console "${YELLOW}Cluster Nodes:${NC}"
        kubectl get nodes -o wide 2>/dev/null | while read -r line; do
            log_console "  $line"
        done
    fi

    # Show upgrade history if exists
    local history_file="${BACKUP_DIR:-/var/backup/k8s-upgrades}/history.json"
    if [[ -f "$history_file" ]]; then
        log_console ""
        log_console "${YELLOW}Recent Upgrade History (last 6):${NC}"
        tail -6 "$history_file" | while IFS= read -r line; do
            local ts action comp from_ver to_ver status
            ts=$(echo "$line" | sed -n 's/.*"timestamp":"\([^"]*\)".*/\1/p')
            action=$(echo "$line" | sed -n 's/.*"action":"\([^"]*\)".*/\1/p')
            comp=$(echo "$line" | sed -n 's/.*"component":"\([^"]*\)".*/\1/p')
            status=$(echo "$line" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
            log_console "  • $ts | $action $comp | $status"
        done
    fi

    log_console ""
}

# ==================== UPGRADE STATE VARIABLES ====================
BACKUP_DIR="${BACKUP_DIR:-/var/backup/k8s-upgrades}"
BACKUP_TIMESTAMP=""
UPGRADE_FAILED=false
CURRENT_COMPONENT=""
ETCD_SNAPSHOT_NAME=""

# ==================== UPGRADE HISTORY ====================
append_upgrade_history() {
    local action="$1"      # upgrade or rollback
    local component="$2"
    local from_version="$3"
    local to_version="$4"
    local status="$5"      # success or failed

    mkdir -p "$BACKUP_DIR"
    local history_file="$BACKUP_DIR/history.json"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local hostname_val
    hostname_val=$(hostname 2>/dev/null || echo "unknown")

    echo "{\"timestamp\":\"$timestamp\",\"action\":\"$action\",\"component\":\"$component\",\"from_version\":\"$from_version\",\"to_version\":\"$to_version\",\"status\":\"$status\",\"hostname\":\"$hostname_val\"}" >> "$history_file"
}

# ==================== BACKUP SYSTEM ====================
backup_etcd() {
    ETCD_SNAPSHOT_NAME="pre-upgrade-${BACKUP_TIMESTAMP}"
    local snapshot_dir="$BACKUP_DIR/$BACKUP_TIMESTAMP"

    log "Creating etcd snapshot: $ETCD_SNAPSHOT_NAME..."

    if rke2 etcd-snapshot save --name "$ETCD_SNAPSHOT_NAME" >> "$LOG_FILE" 2>&1; then
        # Find the snapshot file (rke2 saves to default location)
        local snapshot_path
        snapshot_path=$(find /var/lib/rancher/rke2/server/db/snapshots -name "${ETCD_SNAPSHOT_NAME}*" -type f 2>/dev/null | head -1)
        if [[ -n "$snapshot_path" ]]; then
            cp "$snapshot_path" "$snapshot_dir/" 2>/dev/null
        fi
        echo "$ETCD_SNAPSHOT_NAME" > "$snapshot_dir/snapshot-name.txt"
        log_success "[OK] etcd snapshot created: $ETCD_SNAPSHOT_NAME"
        return 0
    else
        log_error "[ERROR] Failed to create etcd snapshot"
        return 1
    fi
}

backup_binaries() {
    local backup_bin_dir="$BACKUP_DIR/$BACKUP_TIMESTAMP/binaries"
    mkdir -p "$backup_bin_dir"

    log "Backing up component binaries..."

    if [[ -f /usr/local/bin/helm ]]; then
        local helm_ver
        helm_ver=$(helm version --short 2>/dev/null | sed -n 's/.*\(v[0-9]*\.[0-9]*\.[0-9]*\).*/\1/p')
        cp -p /usr/local/bin/helm "$backup_bin_dir/helm-${helm_ver:-unknown}" 2>/dev/null
        log_only "Backed up helm binary ($helm_ver)"
    fi

    if [[ -f /usr/local/bin/calicoctl ]]; then
        local calico_ver
        calico_ver=$(calicoctl version 2>/dev/null | grep "Client Version" | awk '{print $3}')
        cp -p /usr/local/bin/calicoctl "$backup_bin_dir/calicoctl-${calico_ver:-unknown}" 2>/dev/null
        log_only "Backed up calicoctl binary ($calico_ver)"
    fi

    if [[ -f /usr/local/bin/rke2 ]]; then
        local rke2_ver
        rke2_ver=$(rke2 --version 2>/dev/null | head -1 | sed -n 's/.*\(v[0-9]*\.[0-9]*\.[0-9]*+rke2r[0-9]*\).*/\1/p')
        cp -p /usr/local/bin/rke2 "$backup_bin_dir/rke2-${rke2_ver:-unknown}" 2>/dev/null
        log_only "Backed up rke2 binary ($rke2_ver)"
    fi

    log_success "[OK] Binary backups completed"
}

backup_helm_values() {
    local backup_helm_dir="$BACKUP_DIR/$BACKUP_TIMESTAMP/helm-values"
    mkdir -p "$backup_helm_dir"

    log "Backing up Helm release values..."

    if helm list -n metallb-system 2>/dev/null | grep -q metallb; then
        helm get values metallb -n metallb-system -o yaml > "$backup_helm_dir/metallb-values.yaml" 2>/dev/null
        log_only "Backed up MetalLB helm values"
    fi

    if helm list -n longhorn-system 2>/dev/null | grep -q longhorn; then
        helm get values longhorn -n longhorn-system -o yaml > "$backup_helm_dir/longhorn-values.yaml" 2>/dev/null
        log_only "Backed up Longhorn helm values"
    fi

    log_success "[OK] Helm values backup completed"
}

backup_version_inventory() {
    local inventory_file="$BACKUP_DIR/$BACKUP_TIMESTAMP/version-inventory.json"

    log "Creating version inventory..."

    cat > "$inventory_file" <<EOF
{
  "timestamp": "$BACKUP_TIMESTAMP",
  "node": "$(hostname 2>/dev/null)",
  "versions": {
    "rke2": "$(get_current_version 'rke2')",
    "helm": "$(get_current_version 'helm')",
    "calico": "$(get_current_version 'calico')",
    "metallb": "$(get_current_version 'metallb')",
    "longhorn": "$(get_current_version 'longhorn')",
    "kubevip": "$(get_current_version 'kubevip')"
  },
  "config": {
    "vip": "${VIP:-unknown}",
    "nodes_number": "${NODES_NUMBER:-1}",
    "interface": "${INTERFACE:-unknown}"
  }
}
EOF
    log_success "[OK] Version inventory saved"
}

backup_everything() {
    BACKUP_TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
    local backup_path="$BACKUP_DIR/$BACKUP_TIMESTAMP"
    mkdir -p "$backup_path"

    log ""
    log "╔══════════════════════════════════════════════════════════════╗"
    log "║  PRE-UPGRADE BACKUP                                          ║"
    log "╚══════════════════════════════════════════════════════════════╝"
    log "Backup directory: $backup_path"
    log ""

    # CRITICAL: etcd snapshot (abort upgrade if this fails)
    if ! backup_etcd; then
        log_error "[ERROR] etcd snapshot backup FAILED — cannot proceed with upgrade"
        return 1
    fi

    # Non-critical backups (continue even if these fail)
    backup_binaries || log_warning "[WARNING] Binary backup had issues (continuing)"
    backup_helm_values || log_warning "[WARNING] Helm values backup had issues (continuing)"
    backup_version_inventory || log_warning "[WARNING] Version inventory backup had issues (continuing)"

    # Copy current log for reference
    cp "$LOG_FILE" "$backup_path/pre-upgrade.log" 2>/dev/null

    log ""
    log_success "Pre-upgrade backup completed at: $backup_path"
    log ""
    return 0
}

# ==================== UPGRADE FUNCTIONS ====================
upgrade_helm() {
    CURRENT_COMPONENT="helm"
    local target_version="${1:-$HELM_VERSION}"
    local current_version
    current_version=$(get_current_version "helm")

    log "═══════════════════════════════════════════"
    log "  HELM UPGRADE"
    log "═══════════════════════════════════════════"
    log "  Current: $current_version  →  Target: v$target_version"

    # Skip if already at target
    local curr_clean="${current_version#v}"
    if [[ "$curr_clean" == "$target_version" ]]; then
        log_success "[SKIP] Helm is already at version $target_version"
        return 0
    fi

    dry_run_guard "Download and install Helm v$target_version" && return 0

    if [[ "${UPGRADE_AIRGAPPED:-false}" == true ]]; then
        local helm_tar="k8s-airgapped-files/helm-v${target_version}-linux-amd64.tar.gz"
        if [[ ! -f "$helm_tar" ]]; then
            helm_tar="k8s-upgrade-airgapped-files/helm-v${target_version}-linux-amd64.tar.gz"
        fi
        if [[ ! -f "$helm_tar" ]]; then
            log_error "[ERROR] Helm airgapped archive not found: $helm_tar"
            return 1
        fi
        tar -xzf "$helm_tar" -C /tmp/ >> "$LOG_FILE" 2>&1
        cp /tmp/linux-amd64/helm /usr/local/bin/helm
        chmod +x /usr/local/bin/helm
        rm -rf /tmp/linux-amd64
    else
        log "Downloading Helm v${target_version}..."
        curl -fsSL "https://get.helm.sh/helm-v${target_version}-linux-amd64.tar.gz" -o /tmp/helm.tar.gz >> "$LOG_FILE" 2>&1
        if [[ $? -ne 0 ]]; then
            log_error "[ERROR] Failed to download Helm v${target_version}"
            return 1
        fi
        tar -xzf /tmp/helm.tar.gz -C /tmp/ >> "$LOG_FILE" 2>&1
        cp /tmp/linux-amd64/helm /usr/local/bin/helm
        chmod +x /usr/local/bin/helm
        rm -rf /tmp/linux-amd64 /tmp/helm.tar.gz
    fi

    local new_version
    new_version=$(helm version --short 2>/dev/null | sed -n 's/.*\(v[0-9]*\.[0-9]*\.[0-9]*\).*/\1/p')
    log_success "Helm upgraded: $current_version → $new_version"
    append_upgrade_history "upgrade" "helm" "$current_version" "$new_version" "success"
    return 0
}

upgrade_calico() {
    CURRENT_COMPONENT="calico"
    local target_version="${1:-$CALICOCTL_VERSION}"
    local current_version
    current_version=$(get_current_version "calico")

    log "═══════════════════════════════════════════"
    log "  CALICO (calicoctl) UPGRADE"
    log "═══════════════════════════════════════════"
    log "  Current: $current_version  →  Target: v$target_version"

    local curr_clean="${current_version#v}"
    if [[ "$curr_clean" == "$target_version" ]]; then
        log_success "[SKIP] Calicoctl is already at version $target_version"
        return 0
    fi

    dry_run_guard "Download and install calicoctl v$target_version" && return 0

    if [[ "${UPGRADE_AIRGAPPED:-false}" == true ]]; then
        local calico_bin="k8s-airgapped-files/calicoctl-linux-amd64"
        if [[ ! -f "$calico_bin" ]]; then
            calico_bin="k8s-upgrade-airgapped-files/calicoctl-linux-amd64"
        fi
        if [[ ! -f "$calico_bin" ]]; then
            log_error "[ERROR] Calicoctl airgapped binary not found"
            return 1
        fi
        cp "$calico_bin" /usr/bin/calicoctl
        chmod +x /usr/bin/calicoctl
    else
        log "Downloading calicoctl v${target_version}..."
        curl -fsSL "https://github.com/projectcalico/calico/releases/download/v${target_version}/calicoctl-linux-amd64" \
            -o /usr/bin/calicoctl >> "$LOG_FILE" 2>&1
        if [[ $? -ne 0 ]]; then
            log_error "[ERROR] Failed to download calicoctl v${target_version}"
            return 1
        fi
        chmod +x /usr/bin/calicoctl
    fi

    local new_version
    new_version=$(get_current_version "calico")
    log_success "Calicoctl upgraded: $current_version → $new_version"
    append_upgrade_history "upgrade" "calico" "$current_version" "$new_version" "success"
    return 0
}

upgrade_metallb() {
    CURRENT_COMPONENT="metallb"
    local target_version="${1:-$METALLB_VERSION}"
    local current_version
    current_version=$(get_current_version "metallb")

    log "═══════════════════════════════════════════"
    log "  METALLB UPGRADE"
    log "═══════════════════════════════════════════"
    log "  Current: $current_version  →  Target: v$target_version"

    local curr_clean="${current_version#v}"
    if [[ "$curr_clean" == "$target_version" ]]; then
        log_success "[SKIP] MetalLB is already at version $target_version"
        return 0
    fi

    dry_run_guard "Upgrade MetalLB to v$target_version in namespace metallb-system" && return 0

    # Backup current CRD configuration
    log "Backing up MetalLB IP pool configuration..."
    kubectl get ipaddresspool -n metallb-system -o yaml > /tmp/metallb-ippool-backup.yaml 2>/dev/null
    kubectl get l2advertisement -n metallb-system -o yaml > /tmp/metallb-l2adv-backup.yaml 2>/dev/null

    # Check if MetalLB was installed via Helm or raw YAML
    local installed_via_helm=false
    if helm list -n metallb-system 2>/dev/null | grep -q "metallb"; then
        installed_via_helm=true
        log "Detected Helm-based MetalLB installation"
    else
        log "Detected YAML-based MetalLB installation (will use kubectl apply)"
    fi

    local metallb_upgrade_rc=0

    if [[ "$installed_via_helm" == true ]]; then
        # Helm-based upgrade
        if ! command -v helm &>/dev/null; then
            log_error "[ERROR] Helm is required to upgrade MetalLB (installed via Helm)"
            return 1
        fi

        if [[ "${UPGRADE_AIRGAPPED:-false}" == true ]]; then
            local chart_file="k8s-airgapped-files/metallb-${target_version}.tgz"
            if [[ ! -f "$chart_file" ]]; then
                chart_file="k8s-upgrade-airgapped-files/metallb-${target_version}.tgz"
            fi
            if [[ ! -f "$chart_file" ]]; then
                log_error "[ERROR] MetalLB chart not found: $chart_file"
                return 1
            fi
            # Load container images if available
            local img_dir="k8s-upgrade-airgapped-files/container-images"
            [[ ! -d "$img_dir" ]] && img_dir="k8s-airgapped-files/container-images"
            if [[ -d "$img_dir" ]]; then
                local metallb_tars=()
                for img in "$img_dir"/metallb-*.tar; do
                    [[ -f "$img" ]] && metallb_tars+=("$img")
                done
                [[ ${#metallb_tars[@]} -gt 0 ]] && stage_and_wait_for_import "metallb" "${metallb_tars[@]}"
            fi
            helm upgrade metallb "$chart_file" \
                --namespace metallb-system \
                --wait --timeout 10m >> "$LOG_FILE" 2>&1 || metallb_upgrade_rc=$?
        else
            helm repo update >> "$LOG_FILE" 2>&1
            helm upgrade metallb metallb/metallb \
                --namespace metallb-system \
                --version "$target_version" \
                --wait --timeout 10m >> "$LOG_FILE" 2>&1 || metallb_upgrade_rc=$?
        fi
    else
        # YAML-based upgrade (original installation method)
        log "Upgrading MetalLB using kubectl apply..."

        if [[ "${UPGRADE_AIRGAPPED:-false}" == true ]]; then
            local yaml_file="k8s-airgapped-files/metallb-native.yaml"
            if [[ ! -f "$yaml_file" ]]; then
                yaml_file="k8s-upgrade-airgapped-files/metallb-native.yaml"
            fi
            if [[ ! -f "$yaml_file" ]]; then
                log_error "[ERROR] MetalLB YAML manifest not found: $yaml_file"
                log_error "[ERROR] Please download: https://raw.githubusercontent.com/metallb/metallb/v${target_version}/config/manifests/metallb-native.yaml"
                return 1
            fi
            kubectl apply -f "$yaml_file" -n metallb-system >> "$LOG_FILE" 2>&1 || metallb_upgrade_rc=$?
        else
            log "Downloading and applying MetalLB v${target_version} manifest..."
            kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/v${target_version}/config/manifests/metallb-native.yaml" \
                -n metallb-system >> "$LOG_FILE" 2>&1 || metallb_upgrade_rc=$?
        fi
    fi

    if [[ $metallb_upgrade_rc -ne 0 ]]; then
        log_error "[ERROR] MetalLB upgrade failed"
        append_upgrade_history "upgrade" "metallb" "$current_version" "v$target_version" "failed"
        return 1
    fi

    # Wait for controller deployment
    log "Waiting for MetalLB controller deployment..."
    kubectl wait --for=condition=available deployment/controller -n metallb-system --timeout=300s >> "$LOG_FILE" 2>&1

    # Wait for speaker daemonset
    log "Waiting for MetalLB speaker daemonset..."
    kubectl rollout status daemonset/speaker -n metallb-system --timeout=300s >> "$LOG_FILE" 2>&1

    # Verify pods ready
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=metallb \
        -n metallb-system --timeout=300s >> "$LOG_FILE" 2>&1

    local new_version
    new_version=$(get_current_version "metallb")
    log_success "MetalLB upgraded: $current_version → $new_version"
    append_upgrade_history "upgrade" "metallb" "$current_version" "$new_version" "success"
    return 0
}

upgrade_longhorn() {
    CURRENT_COMPONENT="longhorn"
    local target_version="${1:-$LONGHORN_VERSION}"
    local current_version
    current_version=$(get_current_version "longhorn")

    log "═══════════════════════════════════════════"
    log "  LONGHORN UPGRADE"
    log "═══════════════════════════════════════════"
    log "  Current: $current_version  →  Target: v$target_version"

    local curr_clean="${current_version#v}"
    if [[ "$curr_clean" == "$target_version" ]]; then
        log_success "[SKIP] Longhorn is already at version $target_version"
        return 0
    fi

    if ! command -v helm &>/dev/null; then
        log_error "[ERROR] Helm is required to upgrade Longhorn"
        return 1
    fi

    # Detect large version jump (>1 minor version) and offer incremental upgrade
    local current_major current_minor target_major target_minor
    current_major=$(echo "${current_version#v}" | cut -d'.' -f1)
    current_minor=$(echo "${current_version#v}" | cut -d'.' -f2)
    target_major=$(echo "$target_version" | cut -d'.' -f1)
    target_minor=$(echo "$target_version" | cut -d'.' -f2)

    if [[ -n "$current_minor" && -n "$target_minor" && "$current_major" == "$target_major" ]]; then
        local version_diff=$(( target_minor - current_minor ))
        if [[ $version_diff -gt 1 ]]; then
            log_warning "[WARNING] Large version jump detected ($current_version → v$target_version)"
            log_warning "[WARNING] Longhorn requires upgrading through each minor version."
            log_warning "[WARNING] The script will perform an automatic incremental upgrade:"
            log ""

            # Build the upgrade path
            local upgrade_path="  Upgrade path: $current_version"
            for ((m = current_minor + 1; m < target_minor; m++)); do
                upgrade_path+=" → v${current_major}.${m}.0"
            done
            upgrade_path+=" → v${target_version}"
            log "$upgrade_path"
            log ""

            if ! confirm_action "Proceed with incremental Longhorn upgrade?"; then
                log "Longhorn upgrade cancelled by user."
                return 0
            fi

            # Perform incremental upgrades
            for ((m = current_minor + 1; m <= target_minor; m++)); do
                local step_version
                if [[ $m -eq $target_minor ]]; then
                    step_version="$target_version"
                else
                    step_version="${current_major}.${m}.0"
                fi

                local step_current
                step_current=$(get_current_version "longhorn")
                log ""
                log "═══════════════════════════════════════════"
                log "  INCREMENTAL STEP: ${step_current} → v${step_version}"
                log "═══════════════════════════════════════════"

                if ! _longhorn_upgrade_step "$step_version"; then
                    log_error "[ERROR] Incremental upgrade to v${step_version} failed."
                    log_error "[ERROR] Current Longhorn version: $(get_current_version 'longhorn')"
                    append_upgrade_history "upgrade" "longhorn" "$current_version" "v$target_version" "failed-at-v${step_version}"
                    return 1
                fi

                # Wait for longhorn to stabilize between steps
                if [[ $m -lt $target_minor ]]; then
                    log "Waiting for Longhorn to stabilize before next step..."
                    sleep 30
                    kubectl wait --for=condition=ready pod -l app=longhorn-manager \
                        -n longhorn-system --timeout=300s >> "$LOG_FILE" 2>&1
                fi
            done

            local final_version
            final_version=$(get_current_version "longhorn")
            log_success "Longhorn incremental upgrade completed: $current_version → $final_version"
            append_upgrade_history "upgrade" "longhorn" "$current_version" "$final_version" "success"
            return 0
        fi
    fi

    # Single-step upgrade (1 minor version or less)
    _longhorn_pre_upgrade_cleanup || return 1

    dry_run_guard "Helm upgrade Longhorn to v$target_version in namespace longhorn-system" && return 0

    log_warning "[WARNING] Longhorn upgrade may temporarily affect storage operations."
    log_warning "[WARNING] Ensure all volumes have recent backups/snapshots."
    if ! confirm_action "Proceed with Longhorn upgrade?"; then
        log "Longhorn upgrade cancelled by user."
        return 0
    fi

    if ! _longhorn_upgrade_step "$target_version"; then
        return 1
    fi

    local new_version
    new_version=$(get_current_version "longhorn")
    log_success "Longhorn upgraded: $current_version → $new_version"
    append_upgrade_history "upgrade" "longhorn" "$current_version" "$new_version" "success"
    return 0
}

# Internal: clean up failed Longhorn pre-upgrade jobs and Helm revisions
_longhorn_pre_upgrade_cleanup() {
    # Clean up failed Kubernetes jobs
    log "Checking for failed pre-upgrade jobs..."
    local failed_jobs
    failed_jobs=$(kubectl get jobs -n longhorn-system --no-headers 2>/dev/null | grep -v "1/1" | awk '{print $1}')

    if [[ -n "$failed_jobs" ]]; then
        log_warning "[WARNING] Found failed/incomplete jobs in longhorn-system:"
        echo "$failed_jobs" | while read -r job; do
            log_warning "  • $job"
        done
        log "Cleaning up failed jobs..."
        echo "$failed_jobs" | while read -r job; do
            kubectl delete job "$job" -n longhorn-system >> "$LOG_FILE" 2>&1
            log "  Deleted: $job"
        done
        log_success "Job cleanup complete."
    fi

    # Clean up failed Helm revisions (rollback stacked failures to last deployed)
    local failed_revisions
    failed_revisions=$(helm history longhorn -n longhorn-system --max 20 2>/dev/null | grep "failed" | wc -l)
    if [[ $failed_revisions -gt 0 ]]; then
        log_warning "[WARNING] Found $failed_revisions failed Helm revision(s). Rolling back to last successful..."
        local last_good_rev
        last_good_rev=$(helm history longhorn -n longhorn-system --max 20 2>/dev/null | grep "deployed" | tail -1 | awk '{print $1}')
        if [[ -n "$last_good_rev" ]]; then
            helm rollback longhorn "$last_good_rev" -n longhorn-system >> "$LOG_FILE" 2>&1
            log_success "Helm release rolled back to revision $last_good_rev"
        fi
    fi

    return 0
}

# Internal: perform a single Longhorn upgrade step
# Attempts with hooks first; if hooks fail, retries with --no-hooks
_longhorn_upgrade_step() {
    local step_version="$1"

    # Clean up any failed jobs/revisions first
    _longhorn_pre_upgrade_cleanup

    # Get current replica count setting from cluster (preserve it during upgrade)
    local current_replica_count
    current_replica_count=$(kubectl get settings.longhorn.io default-replica-count -n longhorn-system -o jsonpath='{.value}' 2>/dev/null)
    if [[ -z "$current_replica_count" ]]; then
        local node_count
        node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        if [[ $node_count -eq 1 ]]; then
            current_replica_count="1"
        else
            current_replica_count="2"
        fi
        log "Detected replica count: $current_replica_count (based on $node_count nodes)"
    else
        log "Current replica count: $current_replica_count"
    fi

    # Build helm upgrade command arguments
    local helm_common_args=(
        --namespace longhorn-system
        --set-string defaultSettings.defaultReplicaCount="$current_replica_count"
        --set defaultSettings.defaultDataLocality=best-effort
        --set-string defaultSettings.guaranteedInstanceManagerCPU="${LONGHORN_INSTANCE_MANAGER_CPU:-12}"
        --set-string defaultSettings.storageOverProvisioningPercentage=100
        --set-string defaultSettings.storageMinimalAvailablePercentage=15
        --wait --timeout 15m
    )

    local attempt=0
    local max_attempts=2
    local upgrade_result=1

    while [[ $attempt -lt $max_attempts && $upgrade_result -ne 0 ]]; do
        attempt=$((attempt + 1))
        local hook_flag=""

        if [[ $attempt -eq 2 ]]; then
            log_warning "[WARNING] Retrying with --no-hooks (pre-upgrade hook image may not be available)..."
            hook_flag="--no-hooks"
            # Clean up from first failed attempt
            _longhorn_pre_upgrade_cleanup
        fi

        if [[ "${UPGRADE_AIRGAPPED:-false}" == true ]]; then
            local chart_file="k8s-airgapped-files/longhorn-${step_version}.tgz"
            if [[ ! -f "$chart_file" ]]; then
                chart_file="k8s-upgrade-airgapped-files/longhorn-${step_version}.tgz"
            fi
            if [[ ! -f "$chart_file" ]]; then
                log_error "[ERROR] Longhorn chart not found: $chart_file"
                return 1
            fi
            # Load container images if available
            local img_dir="k8s-upgrade-airgapped-files/container-images"
            [[ ! -d "$img_dir" ]] && img_dir="k8s-airgapped-files/container-images"
            if [[ -d "$img_dir" ]]; then
                local longhorn_tars=()
                for img in "$img_dir"/longhorn-*.tar; do
                    [[ -f "$img" ]] && longhorn_tars+=("$img")
                done
                [[ ${#longhorn_tars[@]} -gt 0 ]] && stage_and_wait_for_import "longhorn" "${longhorn_tars[@]}"
            fi
            helm upgrade longhorn "$chart_file" \
                "${helm_common_args[@]}" $hook_flag 2>&1 | tee -a "$LOG_FILE"
        else
            # Add repo if not present
            if ! helm repo list 2>/dev/null | grep -q "longhorn"; then
                helm repo add longhorn https://charts.longhorn.io >> "$LOG_FILE" 2>&1
            fi
            helm repo update >> "$LOG_FILE" 2>&1
            helm upgrade longhorn longhorn/longhorn \
                --version "$step_version" \
                "${helm_common_args[@]}" $hook_flag 2>&1 | tee -a "$LOG_FILE"
        fi

        upgrade_result=${PIPESTATUS[0]}

        if [[ $upgrade_result -ne 0 && $attempt -eq 1 ]]; then
            # Check if it was a hook failure (worth retrying without hooks)
            if tail -20 "$LOG_FILE" 2>/dev/null | grep -q "pre-upgrade"; then
                log_warning "[WARNING] Pre-upgrade hook failed (attempt $attempt/$max_attempts)"
                continue
            else
                # Not a hook failure — don't retry
                break
            fi
        fi
    done

    if [[ $upgrade_result -ne 0 ]]; then
        log_error "[ERROR] Longhorn upgrade to v${step_version} failed."
        log_error "  Check logs: tail -50 $LOG_FILE"
        log_error "  Re-run: ./$(basename "$0") --upgrade longhorn"
        return 1
    fi

    # Wait for manager pods
    log "Waiting for Longhorn manager pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=longhorn-manager \
        -n longhorn-system --timeout=600s >> "$LOG_FILE" 2>&1

    local new_version
    new_version=$(get_current_version "longhorn")
    log_success "Longhorn step complete: → $new_version"

    # Fix StorageClass with correct parameters for node count
    fix_longhorn_default_storageclass

    return 0
}

upgrade_kubevip() {
    CURRENT_COMPONENT="kubevip"
    local target_version="${1:-$KUBEVIP_VERSION}"
    local current_version
    current_version=$(get_current_version "kubevip")

    log "═══════════════════════════════════════════"
    log "  KUBE-VIP UPGRADE"
    log "═══════════════════════════════════════════"
    log "  Current: $current_version  →  Target: v$target_version"

    local curr_clean="${current_version#v}"
    if [[ "$curr_clean" == "$target_version" ]]; then
        log_success "[SKIP] Kube-VIP is already at version $target_version"
        return 0
    fi

    dry_run_guard "kubectl set image on kube-vip-ds DaemonSet to v$target_version" && return 0

    log "Updating Kube-VIP DaemonSet image..."
    kubectl set image daemonset/kube-vip-ds \
        kube-vip="ghcr.io/kube-vip/kube-vip:v${target_version}" \
        -n kube-system >> "$LOG_FILE" 2>&1

    if [[ $? -ne 0 ]]; then
        log_error "[ERROR] Kube-VIP upgrade failed"
        append_upgrade_history "upgrade" "kubevip" "$current_version" "v$target_version" "failed"
        return 1
    fi

    # Wait for rollout
    kubectl rollout status daemonset/kube-vip-ds -n kube-system --timeout=120s >> "$LOG_FILE" 2>&1

    local new_version
    new_version=$(get_current_version "kubevip")
    log_success "Kube-VIP upgraded: $current_version → $new_version"
    append_upgrade_history "upgrade" "kubevip" "$current_version" "$new_version" "success"
    return 0
}

upgrade_rke2() {
    CURRENT_COMPONENT="rke2"
    local target_version="${1:-$RKE2_VERSION}"
    local current_version
    current_version=$(get_current_version "rke2")

    log "═══════════════════════════════════════════"
    log "  RKE2 UPGRADE"
    log "═══════════════════════════════════════════"
    log "  Current: $current_version  →  Target: v$target_version"

    # Normalize for comparison (strip v prefix, handle +rke2r1 suffix)
    local curr_clean="${current_version#v}"
    local tgt_clean="${target_version#v}"
    if [[ "$curr_clean" == "$tgt_clean" ]]; then
        log_success "[SKIP] RKE2 is already at version $target_version"
        return 0
    fi

    # Block downgrades
    local curr_base="${curr_clean%%+*}"
    local tgt_base="${tgt_clean%%+*}"
    if version_gte "$curr_base" "$tgt_base" && [[ "$curr_base" != "$tgt_base" ]]; then
        log_error "[ERROR] Downgrade not allowed: $current_version → v$target_version"
        return 1
    fi

    # Safety checks
    if ! kubectl cluster-info >> "$LOG_FILE" 2>&1; then
        log_error "[ERROR] Cannot connect to Kubernetes API. Fix cluster before upgrading."
        return 1
    fi

    local not_ready
    not_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -v " Ready" | wc -l)
    if [[ $not_ready -gt 0 ]]; then
        log_error "[ERROR] $not_ready node(s) not in Ready state. Fix before upgrading."
        kubectl get nodes
        return 1
    fi

    dry_run_guard "Upgrade RKE2 to v$target_version (cordon/drain/stop/install/start/uncordon)" && return 0

    log_warning "[WARNING] RKE2 upgrade will restart Kubernetes services."
    log_warning "[WARNING] This will cause a brief service interruption on this node."
    if ! confirm_action "Continue with RKE2 upgrade?"; then
        log "RKE2 upgrade cancelled by user."
        return 0
    fi

    local current_node
    current_node=$(hostname)

    # Cordon the node
    log "Cordoning node $current_node..."
    kubectl cordon "$current_node" >> "$LOG_FILE" 2>&1 || true

    # Drain the node
    log "Draining node $current_node (timeout 5 minutes)..."
    kubectl drain "$current_node" --ignore-daemonsets --delete-emptydir-data --timeout=300s >> "$LOG_FILE" 2>&1 || true

    # Determine node type (server vs agent) BEFORE stopping the service —
    # install.sh defaults INSTALL_RKE2_TYPE to "server" when unset, which
    # would silently misconfigure a worker's reinstall during an upgrade.
    local rke2_install_type="server"
    if systemctl is-active --quiet rke2-agent.service; then
        rke2_install_type="agent"
    fi

    # Stop RKE2 service
    log "Stopping RKE2 service..."
    systemctl stop rke2-server.service >> "$LOG_FILE" 2>&1 || \
        systemctl stop rke2-agent.service >> "$LOG_FILE" 2>&1

    # Install new version
    local rke2_install_rc=0
    if [[ "${UPGRADE_AIRGAPPED:-false}" == true ]]; then
        local artifact_dir="k8s-upgrade-airgapped-files"
        [[ ! -d "$artifact_dir" ]] && artifact_dir="k8s-airgapped-files"
        log "Installing RKE2 v${target_version} (type=$rke2_install_type) from airgapped artifacts..."
        INSTALL_RKE2_ARTIFACT_PATH="$artifact_dir" \
        INSTALL_RKE2_VERSION="v${target_version}" \
        INSTALL_RKE2_TYPE="$rke2_install_type" \
            sh "$artifact_dir/install.sh" >> "$LOG_FILE" 2>&1 || rke2_install_rc=$?
    else
        log "Downloading and installing RKE2 v${target_version} (type=$rke2_install_type)..."
        curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="v${target_version}" INSTALL_RKE2_TYPE="$rke2_install_type" sh - >> "$LOG_FILE" 2>&1 || rke2_install_rc=$?
    fi

    if [[ $rke2_install_rc -ne 0 ]]; then
        log_error "[ERROR] Failed to install RKE2 v${target_version}"
        log_warning "Attempting to restart previous version..."
        systemctl start rke2-server.service 2>/dev/null || systemctl start rke2-agent.service 2>/dev/null
        kubectl uncordon "$current_node" 2>/dev/null || true
        append_upgrade_history "upgrade" "rke2" "$current_version" "v$target_version" "failed"
        return 1
    fi

    # Start RKE2 service
    log "Starting RKE2 service..."
    systemctl start rke2-server.service >> "$LOG_FILE" 2>&1 || \
        systemctl start rke2-agent.service >> "$LOG_FILE" 2>&1

    # Wait for node to become Ready
    log "Waiting for node to become Ready..."
    local timeout=300
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if kubectl get node "$current_node" --no-headers 2>/dev/null | grep -q " Ready"; then
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        log_only "Waiting for node... ($elapsed seconds)"
    done

    # Uncordon the node
    log "Uncordoning node $current_node..."
    kubectl uncordon "$current_node" >> "$LOG_FILE" 2>&1

    # Verify
    local new_version
    new_version=$(get_current_version "rke2")
    log_success "RKE2 upgraded: $current_version → $new_version"
    append_upgrade_history "upgrade" "rke2" "$current_version" "$new_version" "success"

    # Multi-node: remind operator about other nodes
    if [[ "${NODES_NUMBER:-1}" -gt 1 ]]; then
        log_console ""
        log_warning "╔══════════════════════════════════════════════════════════════╗"
        log_warning "║  IMPORTANT: Multi-node cluster detected                      ║"
        log_warning "║                                                              ║"
        log_warning "║  This script upgraded RKE2 on the CURRENT NODE only.         ║"
        log_warning "║  You must run the upgrade on each remaining node:            ║"
        log_warning "║                                                              ║"
        log_warning "║  On each node, run:                                          ║"
        log_warning "║    ./$(basename $0) --upgrade rke2                            ║"
        log_warning "║                                                              ║"
        log_warning "║  Upgrade nodes ONE AT A TIME. Wait for each to become        ║"
        log_warning "║  Ready before proceeding to the next.                        ║"
        log_warning "╚══════════════════════════════════════════════════════════════╝"
        log_console ""
    fi

    return 0
}

upgrade_all() {
    log_console ""
    log_console "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    log_console "${GREEN}║               UPGRADING ALL COMPONENTS                        ║${NC}"
    log_console "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    log_console ""

    local failed=0

    # Show current vs target versions
    log "Upgrade Plan:"
    log "  • Helm:     $(get_current_version 'helm')  →  v$HELM_VERSION"
    log "  • Calico:   $(get_current_version 'calico')  →  v$CALICOCTL_VERSION"
    log "  • MetalLB:  $(get_current_version 'metallb')  →  v$METALLB_VERSION"
    log "  • Longhorn: $(get_current_version 'longhorn')  →  v$LONGHORN_VERSION"
    log "  • Kube-VIP: $(get_current_version 'kubevip')  →  v$KUBEVIP_VERSION"
    log "  • RKE2:     $(get_current_version 'rke2')  →  v$RKE2_VERSION"
    log ""
    log "Order: Helm → Calico → MetalLB → Longhorn → Kube-VIP → RKE2 (last)"
    log ""

    if [[ "$DRY_RUN" != true ]]; then
        log_warning "[WARNING] This will upgrade ALL infrastructure components."
        if ! confirm_action "Proceed with full upgrade?"; then
            log "Full upgrade cancelled by user."
            return 0
        fi
    fi

    log ""

    # 1. Helm (needed for chart upgrades)
    print_section_header "UPGRADING HELM" "STEP 1/6"
    upgrade_helm "$HELM_VERSION" || ((failed++))

    # 2. Calico
    print_section_header "UPGRADING CALICO" "STEP 2/6"
    upgrade_calico "$CALICOCTL_VERSION" || ((failed++))

    # 3. MetalLB
    print_section_header "UPGRADING METALLB" "STEP 3/6"
    upgrade_metallb "$METALLB_VERSION" || ((failed++))

    # 4. Longhorn
    print_section_header "UPGRADING LONGHORN" "STEP 4/6"
    upgrade_longhorn "$LONGHORN_VERSION" || ((failed++))

    # 5. Kube-VIP
    print_section_header "UPGRADING KUBE-VIP" "STEP 5/6"
    upgrade_kubevip "$KUBEVIP_VERSION" || ((failed++))

    # 6. RKE2 (last — restarts the cluster)
    print_section_header "UPGRADING RKE2" "STEP 6/6"
    upgrade_rke2 "$RKE2_VERSION" || ((failed++))

    log ""
    if [[ $failed -eq 0 ]]; then
        log_success "╔══════════════════════════════════════════════════════════════╗"
        log_success "║  ALL COMPONENT UPGRADES COMPLETED SUCCESSFULLY               ║"
        log_success "╚══════════════════════════════════════════════════════════════╝"
    else
        log_error "[ERROR] $failed component upgrade(s) failed. Check log: $LOG_FILE"
    fi

    return $failed
}

# ==================== UPGRADE DISPATCHER ====================
# ERR trap for automatic rollback during upgrades
cleanup_on_upgrade_error() {
    local exit_code=$?
    if [[ $exit_code -ne 0 && "$UPGRADE_FAILED" == "false" && -n "$BACKUP_TIMESTAMP" ]]; then
        UPGRADE_FAILED=true
        log_error "[ERROR] Upgrade failed for component: $CURRENT_COMPONENT (exit code: $exit_code)"
        log_warning "[WARNING] Initiating AUTOMATIC ROLLBACK..."
        log ""
        trap - ERR
        rollback_all "$BACKUP_TIMESTAMP"
        local rollback_status=$?
        if [[ $rollback_status -eq 0 ]]; then
            log_success "Automatic rollback completed successfully"
        else
            log_error "[ERROR] Automatic rollback encountered issues — manual intervention may be required"
        fi
        log "Backup preserved at: $BACKUP_DIR/$BACKUP_TIMESTAMP"
    fi
}

perform_upgrade() {
    check_persistent_session

    # Verify cluster connectivity
    if ! kubectl cluster-info >> "$LOG_FILE" 2>&1; then
        log_error "[ERROR] Cannot connect to Kubernetes cluster."
        log_error "[ERROR] Ensure kubeconfig is set and cluster is running."
        exit 1
    fi

    log_console ""
    log_console "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    log_console "${GREEN}║               K8s INFRASTRUCTURE UPGRADE                      ║${NC}"
    log_console "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    log_console ""

    # Pre-upgrade backup (abort if fails)
    if [[ "$DRY_RUN" != true ]]; then
        if ! backup_everything; then
            log_error "[ERROR] Pre-upgrade backup FAILED — cannot proceed"
            log_error "PLEASE CHECK THE 'node_setup.log' FILE FOR MORE DETAILS"
            exit 1
        fi
        # Set ERR trap for automatic rollback
        trap cleanup_on_upgrade_error ERR
    fi

    local result=0

    case "$UPGRADE_COMPONENT" in
        rke2)     upgrade_rke2 "$RKE2_VERSION" || result=$? ;;
        helm)     upgrade_helm "$HELM_VERSION" || result=$? ;;
        calico)   upgrade_calico "$CALICOCTL_VERSION" || result=$? ;;
        metallb)  upgrade_metallb "$METALLB_VERSION" || result=$? ;;
        longhorn) upgrade_longhorn "$LONGHORN_VERSION" || result=$? ;;
        kubevip)  upgrade_kubevip "$KUBEVIP_VERSION" || result=$? ;;
        all)      upgrade_all || result=$? ;;
    esac

    # Clear ERR trap
    trap - ERR

    return $result
}

# ==================== ROLLBACK SYSTEM ====================
restore_etcd_snapshot() {
    local snapshot_name="$1"
    local backup_timestamp="$2"
    local snapshot_path=""

    log "Restoring etcd snapshot: $snapshot_name..."

    # Try to find snapshot in backup dir first
    snapshot_path="$BACKUP_DIR/$backup_timestamp/$snapshot_name"
    if [[ ! -f "$snapshot_path" ]]; then
        # Try RKE2 default snapshot location
        snapshot_path=$(find /var/lib/rancher/rke2/server/db/snapshots -name "${snapshot_name}*" -type f 2>/dev/null | head -1)
    fi

    if [[ -z "$snapshot_path" || ! -f "$snapshot_path" ]]; then
        log_error "[ERROR] Snapshot file not found: $snapshot_name"
        return 1
    fi

    # Stop RKE2
    log "Stopping RKE2 service for etcd restore..."
    systemctl stop rke2-server 2>/dev/null || systemctl stop rke2-agent 2>/dev/null
    sleep 5

    # Restore
    log "Restoring from: $snapshot_path (this may take a moment)..."
    if rke2 server \
        --cluster-reset \
        --cluster-reset-restore-path="$snapshot_path" >> "$LOG_FILE" 2>&1; then
        # Remove the cluster-reset flag so next rke2 start operates normally
        rm -f /var/lib/rancher/rke2/server/db/reset-flag 2>/dev/null
        log_success "[OK] etcd snapshot restored"
        return 0
    else
        log_error "[ERROR] Failed to restore etcd snapshot"
        return 1
    fi
}

rollback_rke2() {
    local backup_timestamp="$1"
    local backup_bin_dir="$BACKUP_DIR/$backup_timestamp/binaries"
    local rke2_backup
    rke2_backup=$(ls -1 "$backup_bin_dir"/rke2-* 2>/dev/null | head -1)

    if [[ -n "$rke2_backup" && -f "$rke2_backup" ]]; then
        systemctl stop rke2-server 2>/dev/null || systemctl stop rke2-agent 2>/dev/null
        cp -f "$rke2_backup" /usr/local/bin/rke2
        chmod +x /usr/local/bin/rke2
        log_success "  • RKE2 binary restored from backup"
    else
        log_warning "  • No RKE2 backup found, skipping binary restore"
    fi
}

rollback_helm() {
    local backup_timestamp="$1"
    local backup_bin_dir="$BACKUP_DIR/$backup_timestamp/binaries"
    local helm_backup
    helm_backup=$(ls -1 "$backup_bin_dir"/helm-* 2>/dev/null | head -1)

    if [[ -n "$helm_backup" && -f "$helm_backup" ]]; then
        cp -f "$helm_backup" /usr/local/bin/helm
        chmod +x /usr/local/bin/helm
        log_success "  • Helm binary restored from backup"
    else
        log_warning "  • No Helm backup found, skipping"
    fi
}

rollback_calico() {
    local backup_timestamp="$1"
    local backup_bin_dir="$BACKUP_DIR/$backup_timestamp/binaries"
    local calico_backup
    calico_backup=$(ls -1 "$backup_bin_dir"/calicoctl-* 2>/dev/null | head -1)

    if [[ -n "$calico_backup" && -f "$calico_backup" ]]; then
        cp -f "$calico_backup" /usr/local/bin/calicoctl
        chmod +x /usr/local/bin/calicoctl
        log_success "  • Calicoctl binary restored from backup"
    else
        log_warning "  • No calicoctl backup found, skipping"
    fi
}

rollback_all() {
    local backup_timestamp="${1:-$BACKUP_TIMESTAMP}"

    if [[ -z "$backup_timestamp" ]]; then
        log_error "[ERROR] No backup timestamp provided for rollback"
        return 1
    fi

    local backup_path="$BACKUP_DIR/$backup_timestamp"
    if [[ ! -d "$backup_path" ]]; then
        log_error "[ERROR] Backup directory not found: $backup_path"
        return 1
    fi

    log_console ""
    log_console "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
    log_console "${RED}║               CLUSTER ROLLBACK                                ║${NC}"
    log_console "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
    log_console ""
    log "Rolling back to backup: $backup_timestamp"

    # STEP 1: Restore etcd snapshot
    local snapshot_name
    if [[ -f "$backup_path/snapshot-name.txt" ]]; then
        snapshot_name=$(cat "$backup_path/snapshot-name.txt")
    fi

    if [[ -n "$snapshot_name" ]]; then
        log "Step 1: Restoring etcd snapshot..."
        if ! restore_etcd_snapshot "$snapshot_name" "$backup_timestamp"; then
            log_error "[ERROR] etcd restore failed — manual intervention required"
            return 1
        fi
    else
        log_warning "[WARNING] No etcd snapshot found in backup — restoring binaries only"
    fi

    # STEP 2: Restore binaries
    log "Step 2: Restoring binaries..."
    rollback_rke2 "$backup_timestamp"
    rollback_helm "$backup_timestamp"
    rollback_calico "$backup_timestamp"

    # STEP 3: Start RKE2
    log "Step 3: Starting RKE2 service..."
    systemctl start rke2-server 2>/dev/null || systemctl start rke2-agent 2>/dev/null

    # STEP 4: Wait for cluster
    log "Step 4: Waiting for cluster to become ready..."
    sleep 60

    local retry=0
    local max_retries=30
    while [[ $retry -lt $max_retries ]]; do
        if kubectl get nodes &>/dev/null; then
            log_success "  • Kubernetes API is responding"
            break
        fi
        ((retry++))
        sleep 10
    done

    if [[ $retry -eq $max_retries ]]; then
        log_error "[ERROR] Cluster did not become ready after rollback"
        return 1
    fi

    # STEP 5: Uncordon nodes
    log "Step 5: Uncordoning all nodes..."
    kubectl get nodes --no-headers 2>/dev/null | awk '{print $1}' | while read -r node; do
        kubectl uncordon "$node" &>/dev/null || true
    done
    log_success "  • All nodes uncordoned"

    # STEP 6: Verify pods
    log "Step 6: Verifying system pods..."
    for ns in kube-system metallb-system longhorn-system calico-system; do
        if kubectl get namespace "$ns" &>/dev/null; then
            local total running
            total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
            running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
            log "  • $ns: $running/$total pods running"
        fi
    done

    log ""
    log_success "╔══════════════════════════════════════════════════════════════╗"
    log_success "║  ROLLBACK COMPLETED                                          ║"
    log_success "╚══════════════════════════════════════════════════════════════╝"
    log "Cluster restored to pre-upgrade state (backup: $backup_timestamp)"
    log "Backup preserved at: $backup_path"

    append_upgrade_history "rollback" "all" "N/A" "$backup_timestamp" "success"

    # Multi-node notice
    if [[ "${NODES_NUMBER:-1}" -gt 1 ]]; then
        log_console ""
        log_warning "╔══════════════════════════════════════════════════════════════╗"
        log_warning "║  IMPORTANT: Multi-node cluster                               ║"
        log_warning "║                                                              ║"
        log_warning "║  Rollback was performed on the CURRENT NODE only.            ║"
        log_warning "║  Other nodes may need binary restoration and re-join:        ║"
        log_warning "║    1. Copy backed-up binaries from $backup_path/binaries/    ║"
        log_warning "║    2. Restart rke2-server service on each node               ║"
        log_warning "║  Or re-run:  ./$(basename $0) --rollback $backup_timestamp   ║"
        log_warning "║  on each node.                                               ║"
        log_warning "╚══════════════════════════════════════════════════════════════╝"
    fi

    return 0
}

perform_rollback() {
    check_persistent_session

    local timestamp="${ROLLBACK_TIMESTAMP:-latest}"

    # Find backup directory
    if [[ "$timestamp" == "latest" ]]; then
        if [[ ! -d "$BACKUP_DIR" ]]; then
            log_error "[ERROR] No backup directory found at $BACKUP_DIR"
            exit 1
        fi
        timestamp=$(ls -1t "$BACKUP_DIR" 2>/dev/null | grep -v "history.json" | head -1)
        if [[ -z "$timestamp" ]]; then
            log_error "[ERROR] No backups found in $BACKUP_DIR"
            exit 1
        fi
        log "Using most recent backup: $timestamp"
    fi

    local backup_path="$BACKUP_DIR/$timestamp"
    if [[ ! -d "$backup_path" ]]; then
        log_error "[ERROR] Backup not found: $backup_path"
        log_error "[ERROR] Available backups:"
        ls -1t "$BACKUP_DIR" 2>/dev/null | grep -v "history.json" | head -10 | while read -r b; do
            log_error "  • $b"
        done
        exit 1
    fi

    # Show backup contents
    log "Backup contents ($backup_path):"
    [[ -f "$backup_path/snapshot-name.txt" ]] && log "  • etcd snapshot: $(cat "$backup_path/snapshot-name.txt")"
    [[ -d "$backup_path/binaries" ]] && log "  • Binaries: $(ls "$backup_path/binaries/" 2>/dev/null | tr '\n' ' ')"
    [[ -f "$backup_path/version-inventory.json" ]] && log "  • Version inventory: present"
    log ""

    log_warning "[WARNING] Rollback will restore cluster to the state before upgrade."
    log_warning "[WARNING] Any changes made after the upgrade will be LOST."
    if ! confirm_action "Proceed with rollback to $timestamp?"; then
        log "Rollback cancelled."
        exit 0
    fi

    rollback_all "$timestamp"
}

# ==================== DIAGNOSTIC BUNDLE ====================
collect_diagnostics() {
    local timestamp
    timestamp=$(date +"%Y%m%d-%H%M%S")
    local hostname_val
    hostname_val=$(hostname 2>/dev/null || echo "unknown")
    local diag_dir="/tmp/k8s-diagnostics-${hostname_val}-${timestamp}"
    local diag_archive="${diag_dir}.tar.gz"

    mkdir -p "$diag_dir"

    log_console ""
    log_console "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    log_console "${GREEN}║               GENERATING DIAGNOSTIC BUNDLE                    ║${NC}"
    log_console "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    log_console ""

    local max_parallel="${MAX_PARALLEL_DIAGNOSTICS:-8}"
    log_console "Collecting diagnostics in parallel (max ${max_parallel} concurrent tasks)..."

    # Define parallel collection tasks
    declare -a diag_pids=()

    # Task 1: System info
    (
        {
            echo "=== System Info ==="
            echo "Date: $(date)"
            echo "Hostname: $hostname_val"
            uname -a 2>/dev/null
            echo ""
            echo "=== OS Release ==="
            cat /etc/os-release 2>/dev/null
            echo ""
            echo "=== Memory ==="
            free -h 2>/dev/null
            echo ""
            echo "=== Disk ==="
            df -h 2>/dev/null
            echo ""
            echo "=== Network Interfaces ==="
            ip addr 2>/dev/null
        } > "$diag_dir/system-info.txt"
    ) &
    diag_pids+=($!)

    # Task 2: RKE2 status
    (
        systemctl status rke2-server --no-pager > "$diag_dir/rke2-server-status.txt" 2>&1 || true
        systemctl status rke2-agent --no-pager > "$diag_dir/rke2-agent-status.txt" 2>&1 || true
        if [[ -f /etc/rancher/rke2/config.yaml ]]; then
            sed -E 's/(token:).*/\1 ****REDACTED****/g' /etc/rancher/rke2/config.yaml > "$diag_dir/rke2-config.yaml" 2>/dev/null
        fi
    ) &
    diag_pids+=($!)

    # Task 3: Kubernetes state (if available)
    if command -v kubectl &>/dev/null && kubectl get nodes &>/dev/null 2>&1; then
        (
            kubectl get nodes -o wide > "$diag_dir/nodes.txt" 2>&1
            kubectl get pods -A > "$diag_dir/pods-all.txt" 2>&1
            kubectl describe nodes > "$diag_dir/nodes-describe.txt" 2>&1
            kubectl get events -A --sort-by='.lastTimestamp' > "$diag_dir/events.txt" 2>&1
            if command -v helm &>/dev/null; then
                helm list -A > "$diag_dir/helm-releases.txt" 2>&1
            fi
        ) &
        diag_pids+=($!)

        # Task 4: Pod logs per namespace (parallelized by namespace)
        for ns in kube-system metallb-system longhorn-system calico-system; do
            (
                mkdir -p "$diag_dir/logs/$ns"
                kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk '{print $1}' | while read -r pod; do
                    kubectl logs "$pod" -n "$ns" --tail=500 > "$diag_dir/logs/$ns/${pod}.log" 2>&1 || true
                done
            ) &
            diag_pids+=($!)
        done
    fi

    # Task 5: Certificate info
    (
        {
            echo "=== RKE2 API Server Certificate ==="
            local cert_path="/var/lib/rancher/rke2/server/tls/serving-kube-apiserver.crt"
            if [[ -f "$cert_path" ]] && command -v openssl &>/dev/null; then
                openssl x509 -in "$cert_path" -noout -subject -issuer -dates 2>/dev/null
            else
                echo "Certificate not found or openssl not available"
            fi
        } > "$diag_dir/certificates.txt"
    ) &
    diag_pids+=($!)

    # Task 6: Version inventory (parallel version checks)
    (
        {
            echo "=== Component Versions ==="
            # Get versions in parallel
            declare -a ver_pids=()
            declare -a ver_files=()
            for comp in rke2 helm calico metallb longhorn kubevip; do
                local vf="${UC_TMP_DIR}/diag_ver_${comp}_$$.txt"
                ver_files+=("$vf")
                ( get_current_version "$comp" > "$vf" 2>&1 ) &
                ver_pids+=($!)
            done
            for pid in "${ver_pids[@]}"; do wait "$pid" 2>/dev/null || true; done
            echo "RKE2:     $(cat "${ver_files[0]}" 2>/dev/null || echo 'unknown')"
            echo "Helm:     $(cat "${ver_files[1]}" 2>/dev/null || echo 'unknown')"
            echo "Calico:   $(cat "${ver_files[2]}" 2>/dev/null || echo 'unknown')"
            echo "MetalLB:  $(cat "${ver_files[3]}" 2>/dev/null || echo 'unknown')"
            echo "Longhorn: $(cat "${ver_files[4]}" 2>/dev/null || echo 'unknown')"
            echo "Kube-VIP: $(cat "${ver_files[5]}" 2>/dev/null || echo 'unknown')"
            rm -f "${ver_files[@]}" 2>/dev/null
        } > "$diag_dir/versions.txt"
    ) &
    diag_pids+=($!)

    # Wait for all parallel diagnostic tasks to complete
    log_console "Waiting for all diagnostic tasks to complete..."
    for pid in "${diag_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Copy script log
    [[ -f "$LOG_FILE" ]] && cp "$LOG_FILE" "$diag_dir/setup-log.txt"

    # Upgrade history
    local history_file="${BACKUP_DIR:-/var/backup/k8s-upgrades}/history.json"
    [[ -f "$history_file" ]] && cp "$history_file" "$diag_dir/upgrade-history.json"

    # Create archive
    log_console "Creating archive..."
    tar -czf "$diag_archive" -C /tmp "$(basename "$diag_dir")" 2>/dev/null
    rm -rf "$diag_dir"

    log_console ""
    log_success "Diagnostic bundle created: $diag_archive"
    log_console "Send this file to support for analysis."
    log_console ""
}

# ==================== UNINSTALL ====================
# Removes RKE2 and what this script put on the node, in three phases of
# increasing blast radius:
#   1/3  RKE2 itself (its own uninstaller) — cluster state on a server node
#   2/3  tooling and OS config this script added — additive, safe to drop
#   3/3  persistent data and OS tunings — gated behind confirm_destructive,
#        so an unattended run reports them and moves on instead of wiping them
# Deliberately NOT touched: /var/backup/k8s-upgrades (etcd snapshots — the only
# way back), the k8s-airgapped-files bundle, and the swap entries commented out
# in /etc/fstab during install.

# Remove a file/tree, honouring --dry-run. Silent when the target is already
# gone, so a second run reads as a clean confirmation rather than noise.
_uninstall_rm() {
    local target="$1" label="${2:-$1}"
    [[ -e "$target" ]] || return 0
    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] Would remove: $label"
        return 0
    fi
    if rm -rf "$target"; then
        log_success "  • Removed $label"
    else
        log_error "  • Failed to remove $label — remove it manually."
    fi
}

# Delete every line matching an extended regex from a config file, keeping a
# timestamped backup. '%' is the sed address delimiter, so patterns may contain
# '/' freely — but must not contain '%'.
_uninstall_strip_lines() {
    local file="$1" pattern="$2" label="$3"
    [[ -f "$file" ]] || return 0
    grep -qE "$pattern" "$file" 2>/dev/null || return 0
    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] Would remove $label from $file"
        return 0
    fi
    cp -p "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
    if sed -i -E "\%${pattern}%d" "$file"; then
        log_success "  • Removed $label from $file (backup kept)"
    else
        log_error "  • Failed to edit $file — remove $label manually."
    fi
}

# --- PHASE 1: RKE2 ---------------------------------------------------------
_uninstall_rke2() {
    print_section_header "REMOVING RKE2" "PHASE 1/3"

    # install.sh puts these in /usr/local/bin for the tarball method (what the
    # airgapped install uses) and /usr/bin for the RPM method.
    local killall="" uninstaller="" p
    for p in /usr/local/bin/rke2-killall.sh /usr/bin/rke2-killall.sh; do
        [[ -x "$p" ]] && { killall="$p"; break; }
    done
    for p in /usr/local/bin/rke2-uninstall.sh /usr/bin/rke2-uninstall.sh; do
        [[ -x "$p" ]] && { uninstaller="$p"; break; }
    done

    if [[ -n "$killall" ]]; then
        log "Stopping RKE2 workloads and unmounting pod volumes ($killall)..."
        if [[ "$DRY_RUN" == true ]]; then
            log "[DRY-RUN] Would run: $killall"
        elif ! run_with_spinner "Stopping RKE2 workloads" "$killall"; then
            log_warning "[WARNING] $killall reported errors — continuing (see $LOG_FILE)."
        fi
    else
        log_warning "[WARNING] rke2-killall.sh not found — stopping services directly."
        if [[ "$DRY_RUN" != true ]]; then
            systemctl stop rke2-server.service >> "$LOG_FILE" 2>&1
            systemctl stop rke2-agent.service  >> "$LOG_FILE" 2>&1
        fi
    fi

    if [[ -n "$uninstaller" ]]; then
        log "Running the RKE2 uninstaller ($uninstaller)..."
        if [[ "$DRY_RUN" == true ]]; then
            log "[DRY-RUN] Would run: $uninstaller"
        elif run_with_spinner "Uninstalling RKE2" "$uninstaller"; then
            log_success "RKE2 uninstaller completed."
        else
            log_warning "[WARNING] $uninstaller reported errors — the manual cleanup below still runs."
        fi
    else
        log_warning "[WARNING] rke2-uninstall.sh not found on this node."
        log_warning "[WARNING] Falling back to disabling the services and removing RKE2's directories by hand."
        if [[ "$DRY_RUN" != true ]]; then
            systemctl disable rke2-server.service >> "$LOG_FILE" 2>&1
            systemctl disable rke2-agent.service  >> "$LOG_FILE" 2>&1
        fi
        _uninstall_rm /usr/local/bin/rke2 "rke2 binary"
    fi

    # Whatever the uninstaller left behind, plus the files this script wrote
    # into RKE2's own directories.
    _uninstall_rm /etc/rancher/rke2       "/etc/rancher/rke2 (config.yaml, kubeconfig)"
    _uninstall_rm /var/lib/rancher/rke2   "/var/lib/rancher/rke2 (etcd data, staged images)"
    _uninstall_rm /usr/lib/systemd/system/rke2-server.env "rke2-server proxy environment"
    _uninstall_rm /usr/lib/systemd/system/rke2-agent.env  "rke2-agent proxy environment"
    _uninstall_rm /etc/default/rke2-server "/etc/default/rke2-server"
    _uninstall_rm /etc/crictl.yaml         "/etc/crictl.yaml"

    [[ "$DRY_RUN" != true ]] && systemctl daemon-reload >> "$LOG_FILE" 2>&1
    log_success "RKE2 removal complete."
}

# --- PHASE 2: tooling and OS configuration this script added ---------------
_uninstall_script_artifacts() {
    print_section_header "REMOVING TOOLING & CONFIGURATION" "PHASE 2/3"

    # Binaries installed by this script
    _uninstall_rm /usr/bin/calicoctl       "calicoctl (/usr/bin)"
    _uninstall_rm /usr/local/bin/calicoctl "calicoctl (/usr/local/bin)"
    _uninstall_rm /usr/local/bin/helm      "helm"

    # Kernel / IO / module tuning dropped in by the install
    _uninstall_rm /etc/sysctl.d/99-uc-performance.conf   "UC kernel tuning (sysctl.d)"
    _uninstall_rm /etc/udev/rules.d/60-io-scheduler.rules "I/O scheduler udev rule"
    _uninstall_rm /etc/modules-load.d/nf_conntrack.conf   "nf_conntrack module autoload"
    _uninstall_rm /etc/modules-load.d/iscsi.conf          "iscsi_tcp module autoload"

    # NIC tuning: the POST_UP_SCRIPT reference must go before the script it
    # points at, so wicked never runs a path that no longer exists.
    local nic_script="/etc/sysconfig/network/scripts/${INTERFACE}-ethtool.sh"
    _uninstall_strip_lines "/etc/sysconfig/network/ifcfg-${INTERFACE}" \
        "POST_UP_SCRIPT=.*${INTERFACE}-ethtool" "NIC tuning POST_UP_SCRIPT"
    _uninstall_rm "$nic_script" "NIC tuning script for ${INTERFACE}"

    # /etc/hosts entry added when a proxy is configured
    if [[ -n "$VIP" ]]; then
        _uninstall_strip_lines /etc/hosts "^${VIP}[[:space:]]+mastervip" "VIP host entry"
    fi
    _uninstall_strip_lines /etc/hosts "^# Added by cluster setup script" "setup-script marker"

    # Shell environment written into root's .bashrc
    _uninstall_strip_lines "$HOME/.bashrc" \
        "(KUBECONFIG=/etc/rancher/rke2/rke2.yaml|/var/lib/rancher/rke2/bin|alias k='kubectl'|kubectl completion bash|complete -F __start_kubectl k)" \
        "kubectl environment and aliases"

    log_success "Tooling and configuration removal complete."
    log "Open shells still have the old KUBECONFIG/PATH exported — log out and back in."
}

# --- PHASE 3: persistent data and OS tunings (guarded) ---------------------
_uninstall_persistent_data() {
    print_section_header "PERSISTENT DATA & OS TUNINGS" "PHASE 3/3"

    if [[ -d /var/lib/longhorn ]]; then
        local lh_size
        lh_size=$(du -sh /var/lib/longhorn 2>/dev/null | awk '{print $1}')
        log_warning "[WARNING] /var/lib/longhorn holds Longhorn replica data (${lh_size:-unknown})."
        log_warning "[WARNING] Deleting it destroys every volume replica stored on this node."
        if confirm_destructive "Delete /var/lib/longhorn and all replica data on this node?"; then
            _uninstall_rm /var/lib/longhorn "/var/lib/longhorn (replica data)"
        fi
    fi

    if confirm_destructive "Revert the OS tunings (limits.conf, kernel.pid_max, fstab noatime)?"; then
        _uninstall_strip_lines /etc/security/limits.conf \
            "^\*[[:space:]]+(soft|hard)[[:space:]]+(nproc|nofile|memlock|stack)[[:space:]]" \
            "nproc/nofile/memlock/stack limits"
        _uninstall_strip_lines /etc/sysctl.conf "^kernel.pid_max = 4194304$" "kernel.pid_max override"

        # Strip noatime from XFS entries only, preserving column alignment.
        if [[ -f /etc/fstab ]] && awk '$1 !~ /^#/ && $3 == "xfs" && $4 ~ /noatime/' /etc/fstab | grep -q .; then
            if [[ "$DRY_RUN" == true ]]; then
                log "[DRY-RUN] Would strip noatime from XFS entries in /etc/fstab"
            else
                cp -p /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
                sed -i -E '/^[^#]/ { /[[:space:]]xfs[[:space:]]/ { s/,noatime//g; s/noatime,//g; s/([[:space:]])noatime([[:space:]])/\1defaults\2/g } }' /etc/fstab
                log_success "  • Stripped noatime from XFS entries in /etc/fstab (backup kept)"
            fi
        fi
        log "Reverted tunings apply on next boot; sysctl values stay live until then."
    fi
}

perform_uninstall() {
    check_persistent_session

    log_console ""
    log_console "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
    log_console "${RED}║               UNINSTALL RKE2 & CLUSTER TOOLING                ║${NC}"
    log_console "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
    log_console ""
    log "Node: $(hostname 2>/dev/null) — mode: ${NODE_TYPE:-not specified}"
    log ""
    log_warning "[WARNING] This removes RKE2 from THIS node only."
    log_warning "[WARNING] On a control-plane node that destroys its etcd data."
    log_warning "[WARNING] Kept regardless: $BACKUP_DIR (etcd snapshots) and the airgapped bundle."
    log ""

    if ! confirm_action "Remove RKE2 and this script's configuration from this node?"; then
        log "Uninstall cancelled."
        exit 0
    fi

    _uninstall_rke2
    _uninstall_script_artifacts
    _uninstall_persistent_data

    log_console ""
    log_success "╔══════════════════════════════════════════════════════════════╗"
    log_success "║  UNINSTALL COMPLETED                                         ║"
    log_success "╚══════════════════════════════════════════════════════════════╝"
    log_console ""
    log_console "${YELLOW}Follow-up on the remaining cluster:${NC}"
    log_console "  • From a surviving control-plane node, drop this node's object:"
    log_console "      ${GREEN}kubectl delete node $(hostname 2>/dev/null)${NC}"
    log_console "  • If this was a control-plane node, also remove its etcd member"
    log_console "    so the cluster does not keep trying to reach it."
    log_console ""
    log_console "${YELLOW}Not reverted (deliberately):${NC}"
    log_console "  • Swap stays disabled — re-enable with: ${GREEN}swapon -a${NC} after"
    log_console "    uncommenting the swap line in /etc/fstab."
    log_console "  • iscsid / irqbalance / nfs-client packages stay installed."
    log_console "  • ${GREEN}$BACKUP_DIR${NC} (etcd snapshots and upgrade history)."
    log_console ""
    log_console "A reboot is recommended before reinstalling on this node."
    log_console ""
}

# ==================== POST-INSTALL SMOKE TEST ====================
run_smoke_test() {
    log_console ""
    log_console "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    log_console "${YELLOW}  POST-INSTALL SMOKE TEST${NC}"
    log_console "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    log ""

    local passed=0
    local failed=0

    # Test 1: PVC provisioning (Longhorn)
    log "Test 1: Longhorn PVC provisioning..."
    local pvc_yaml="/tmp/smoke-test-pvc-$$.yaml"
    cat > "$pvc_yaml" <<'EOFPVC'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: smoke-test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
EOFPVC
    if kubectl apply -f "$pvc_yaml" >> "$LOG_FILE" 2>&1; then
        local pvc_timeout=60
        local pvc_elapsed=0
        while [[ $pvc_elapsed -lt $pvc_timeout ]]; do
            local pvc_status
            pvc_status=$(kubectl get pvc smoke-test-pvc -n default -o jsonpath='{.status.phase}' 2>/dev/null)
            if [[ "$pvc_status" == "Bound" ]]; then
                log_success "  ✓ PVC provisioning works (Longhorn)"
                ((passed++))
                break
            fi
            sleep 5
            pvc_elapsed=$((pvc_elapsed + 5))
        done
        if [[ $pvc_elapsed -ge $pvc_timeout ]]; then
            log_warning "  ✗ PVC did not become Bound within ${pvc_timeout}s"
            ((failed++))
        fi
        kubectl delete pvc smoke-test-pvc -n default >> "$LOG_FILE" 2>&1
    else
        log_warning "  ✗ Failed to create test PVC"
        ((failed++))
    fi
    rm -f "$pvc_yaml"

    # Test 2: LoadBalancer IP allocation (MetalLB)
    log "Test 2: MetalLB LoadBalancer IP allocation..."
    local svc_yaml="/tmp/smoke-test-svc-$$.yaml"
    cat > "$svc_yaml" <<'EOFSVC'
apiVersion: v1
kind: Service
metadata:
  name: smoke-test-lb
  namespace: default
spec:
  type: LoadBalancer
  ports:
    - port: 80
      targetPort: 80
  selector:
    app: smoke-test-nonexistent
EOFSVC
    if kubectl apply -f "$svc_yaml" >> "$LOG_FILE" 2>&1; then
        local lb_timeout=60
        local lb_elapsed=0
        while [[ $lb_elapsed -lt $lb_timeout ]]; do
            local ext_ip
            ext_ip=$(kubectl get svc smoke-test-lb -n default -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
            if [[ -n "$ext_ip" ]]; then
                log_success "  ✓ LoadBalancer IP allocated: $ext_ip (MetalLB)"
                ((passed++))
                break
            fi
            sleep 5
            lb_elapsed=$((lb_elapsed + 5))
        done
        if [[ $lb_elapsed -ge $lb_timeout ]]; then
            log_warning "  ✗ LoadBalancer IP not assigned within ${lb_timeout}s"
            ((failed++))
        fi
        kubectl delete svc smoke-test-lb -n default >> "$LOG_FILE" 2>&1
    else
        log_warning "  ✗ Failed to create test LoadBalancer service"
        ((failed++))
    fi
    rm -f "$svc_yaml"

    # Test 3: Cluster DNS resolution
    log "Test 3: Cluster DNS resolution..."

    # Detect available busybox image (check for common airgapped tags first)
    local busybox_image=""
    for tag in "1.35-uclibc" "1.36" "1.35" "latest"; do
        if crictl images 2>/dev/null | grep -q "busybox.*${tag}"; then
            busybox_image="busybox:${tag}"
            log_only "Found busybox image: $busybox_image"
            break
        fi
    done

    if [[ -z "$busybox_image" ]]; then
        log_warning "  - Skipped DNS test (no busybox image found in cluster)"
    elif kubectl run smoke-test-dns --image="$busybox_image" --restart=Never \
        --command -- nslookup kubernetes.default >> "$LOG_FILE" 2>&1; then
        sleep 15
        local dns_status
        dns_status=$(kubectl get pod smoke-test-dns -n default -o jsonpath='{.status.phase}' 2>/dev/null)
        if [[ "$dns_status" == "Succeeded" ]]; then
            log_success "  ✓ Cluster DNS resolution works"
            ((passed++))
        else
            log_warning "  ✗ DNS test pod status: $dns_status"
            ((failed++))
        fi
        kubectl delete pod smoke-test-dns -n default >> "$LOG_FILE" 2>&1
    else
        log_warning "  ✗ Failed to create DNS test pod"
        ((failed++))
    fi

    log ""
    if [[ $failed -eq 0 ]]; then
        log_success "Smoke test: $passed/$((passed + failed)) tests passed ✓"
    else
        log_warning "Smoke test: $passed/$((passed + failed)) tests passed, $failed warning(s)"
        log_warning "Failed tests are warnings only — cluster may still be functional."
    fi
    log ""
}

# Main function
# Helm, MetalLB, Calico pool and Longhorn on an existing cluster, followed by
# the checks and the smoke test. Called by node3 (single-master and triple
# installs) and by "--airgapped stack" (3 masters + workers). Every step skips
# what is already installed, so it is safe to re-run after a failure.
install_cluster_stack() {
    install_helm_airgapped
    check_helm_installed
    wait_for_nginx_ingress
    install_metallb_airgapped
    configure_metallb_ip_pool
    configure_calico_ip_pool
    install_longhorn_airgapped
    sleep 30
    check_pods_ready "longhorn-system" || exit 1
    create_longhorn_log_storageclass
    check_longhorn
    check_metallb_ip_pool
    check_calico_ip_pool
    log_success "Script is completed! Please check the logs file: $LOG_FILE for more info."
    log_success "Congratulations! You have successfully set up your Kubernetes cluster with RKE2, Calico CNI, MetalLB, and Longhorn!"
    log_success "You can now deploy your applications and services on the cluster."
    log_success "To apply the updated environment settings, please log out and log back in!"
    run_smoke_test
    offer_airgapped_cleanup
}

# ha-workers install order: node1 -> node2 -> node3 -> worker1..N -> "stack" on node3.
# Tells the operator what to run next. $1 = node3 | worker, $2 = worker number.
print_stack_next_steps() {
    local after="$1" worker_num="${2:-0}" w ip
    local stack_cmd="cd ${SCRIPT_DIR} && ./$(basename "$0") --airgapped stack"

    log_console ""
    log_console "${YELLOW}╔═══════════════════════════════════════════════════════════════╗${NC}"
    log_console "${YELLOW}║  NEXT STEPS — 3 masters + ${WORKERS_NUMBER} worker(s)${NC}"
    log_console "${YELLOW}╚═══════════════════════════════════════════════════════════════╝${NC}"
    if [[ "$after" == "node3" ]]; then
        log_console "  All masters are installed. Helm, MetalLB and Longhorn are NOT installed yet:"
        log_console "  masters are tainted, so they can only run once the workers have joined."
        log_console ""
        log_console "  ${GREEN}1.${NC} Install the workers, one by one:"
        for ((w=1; w<=WORKERS_NUMBER; w++)); do
            ip="WORKER${w}"
            log_console "       worker${w} (${!ip}):  ./$(basename "$0") --airgapped worker${w}"
        done
        log_console "  ${GREEN}2.${NC} After the LAST worker (worker${WORKERS_NUMBER}), come back to THIS node (node3, ${NODE3}) and run:"
        log_console "       ${GREEN}${stack_cmd}${NC}"
    elif (( worker_num < WORKERS_NUMBER )); then
        ip="WORKER$((worker_num + 1))"
        log_console "  worker${worker_num} of ${WORKERS_NUMBER} done."
        log_console "  ${GREEN}Next:${NC} install worker$((worker_num + 1)) (${!ip}):  ./$(basename "$0") --airgapped worker$((worker_num + 1))"
        log_console "  When all ${WORKERS_NUMBER} workers are installed, run on node3 (${NODE3}):  ${stack_cmd}"
    else
        log_console "  This was the LAST worker (worker${worker_num} of ${WORKERS_NUMBER})."
        log_console "  ${GREEN}FINAL STEP:${NC} log in to node3 (${NODE3}) and run:"
        log_console "       ${GREEN}${stack_cmd}${NC}"
        log_console "  It installs Helm, MetalLB and Longhorn, then runs the checks and the smoke test."
    fi
    log_console ""
}

main() {
    # Anchor the working directory to the script's own directory. Roughly 40
    # paths below are written as ./k8s-airgapped-files/... — relative to the
    # CWD, not to the script — so invoking the script from anywhere else made
    # them resolve against the wrong directory. Everything the script reads is
    # documented as living next to it, so this makes the code match the docs
    # and the run independent of where the operator happened to be standing.
    if ! cd "$SCRIPT_DIR"; then
        log_error "[ERROR] Cannot change directory to $SCRIPT_DIR. Exiting."
        exit 1
    fi
    log_only "[INFO] Working directory set to $SCRIPT_DIR"

    # Check script location, working directory and /var disk space first
    [[ "$ARGUMENT_TYPE" != "--info" ]] && check_script_location

    # Extract airgapped archive
    if [[ "$ARGUMENT_TYPE" == "--airgapped" || "$ARGUMENT_TYPE" == "--scale-airgapped" ]]; then
        log "Airgapped mode selected. Checking for airgapped archive..."
        extract_airgapped_archive
    fi

    # Add this section in the main() function before existing logic
    if [[ "$ARGUMENT_TYPE" == "--import" && "$NODE_TYPE" == "uc" ]]; then
        log "UC Images Import Mode Selected"
        # ha-workers: masters are tainted and never run UC pods — importing the
        # UC images there only fills their (smaller) disks.
        if [[ "$(get_deployment_profile)" == "ha-workers" ]] && systemctl is-active --quiet rke2-server.service; then
            log_warning "[WARNING] This is a control-plane node in a 3-master + workers cluster (WORKERS_NUMBER=$WORKERS_NUMBER)."
            log_warning "[WARNING] UC pods cannot run on control-plane nodes. Run '--import uc' on the worker nodes only."
            exit 0
        fi
        # Check if ctr command is available
        if ! command -v ctr &>/dev/null; then
            log_error "[ERROR] ctr command not found. Please ensure containerd tools are installed."
            exit 1
        fi
        # Prompt for number of Media Servers to import.
        # Unattended: take MS_COUNT_IMPORT from config.env (default 1).
        local ms_input
        if [[ "$INTERACTIVE" != true ]]; then
            ms_input="${MS_COUNT_IMPORT:-1}"
            if [[ ! "$ms_input" =~ ^[1-4]$ ]]; then
                log_error "[ERROR] MS_COUNT_IMPORT ('$ms_input') must be a number between 1 and 4."
                exit 1
            fi
            log "[INFO] Unattended run — importing $ms_input Media Server(s) (MS_COUNT_IMPORT)."
        else
        while true; do
            echo ""
            echo "┌──────────────────────────────────────────────────────────────────────────┐"
            echo "│  How many Media Servers do you want to import?                           │"
            echo "│    1 → ms1                                                               │"
            echo "│    2 → ms1, ms2                                                          │"
            echo "│    3 → ms1, ms2, ms3                                                     │"
            echo "│    4 → ms1, ms2, ms3, ms4  (all)                                         │"
            echo "└──────────────────────────────────────────────────────────────────────────┘"
            read -r -p "  Enter number of Media Servers to import [1]: " ms_input
            ms_input="${ms_input:-1}"
            if [[ "$ms_input" =~ ^[1-4]$ ]]; then
                break
            else
                log_error "[ERROR] Invalid input '${ms_input}'. Please enter a number between 1 and 4."
            fi
        done
        fi
        MS_COUNT_IMPORT="$ms_input"
        local ms_list=""
        for ((i=1; i<=ms_input; i++)); do ms_list+="ms${i} "; done
        log "[INFO] Will import ${ms_input} Media Server(s): ${ms_list% }"
        # Execute UC images import
        import_uc_images
        log_success "UC images import completed successfully!"
        exit 0
    fi

    if [[ "$NODE_TYPE" == "single" ]]; then
        print_section_header "SYSTEM PREPARATION" "PHASE 1/6"
        preflight_checks
        check_limits_conf
        set_pid_max
        set_stack_size
        configure_kernel_tuning
        configure_nic_tuning
        install_irqbalance_airgapped
        configure_io_scheduler
        [[ "$OPTIMIZE_FILESYSTEM" == "true" ]] && optimize_filesystem
        check_node_ip
        check_firewall
        configure_hosts

        print_section_header "RKE2 KUBERNETES INSTALLATION" "PHASE 2/6"
        log "Installing RKE2 in airgapped mode..."
        install_rke2_airgapped
        verify_kubeconfig
        check_kubectl
        configure_crictl
        check_kubernetes_cluster_health
        retrieve_token

        print_section_header "SYSTEM DEPENDENCIES" "PHASE 3/6"
        log "Installing system packages in airgapped mode..."
        install_nfs_client_airgapped
        install_kernel_airgapped
        install_iscsi_airgapped
        enable_and_start_iscsi
        install_jq_airgapped
        install_ux_tools_airgapped

        print_section_header "KUBERNETES TOOLS" "PHASE 4/6"
        install_calicoctl_airgapped
        install_aws_cli_airgapped

        if check_nodes_ready "$NODES_NUMBER"; then
            configure_kube_vip

            print_section_header "HELM & NETWORK SETUP" "PHASE 5/6"
            install_helm_airgapped
            check_helm_installed
            wait_for_nginx_ingress
            install_metallb_airgapped
            configure_metallb_ip_pool
            configure_calico_ip_pool

            print_section_header "STORAGE INSTALLATION" "PHASE 6/6"
            install_longhorn_airgapped
            sleep 20
            check_pods_ready "longhorn-system" || exit 1
            create_longhorn_log_storageclass
            check_longhorn
            check_metallb_ip_pool
            check_calico_ip_pool

            print_final_summary
            run_smoke_test
            offer_airgapped_cleanup
        else
            log_error "Node readiness check failed. Exiting script"
            exit 1
        fi
    fi


    if [[ "$NODE_TYPE" == "node1" || "$NODE_TYPE" == "node2" || "$NODE_TYPE" == "node3" ]]; then
        print_section_header "SYSTEM PREPARATION" "PHASE 1/5"
        preflight_checks
        check_limits_conf
        set_pid_max
        set_stack_size
        configure_kernel_tuning
        configure_nic_tuning
        install_irqbalance_airgapped
        configure_io_scheduler
        [[ "$OPTIMIZE_FILESYSTEM" == "true" ]] && optimize_filesystem
        check_node_ip
        check_firewall
        configure_hosts

        print_section_header "RKE2 KUBERNETES INSTALLATION" "PHASE 2/5"
        log "Installing RKE2 in airgapped mode on $NODE_TYPE..."
        install_rke2_airgapped
        verify_kubeconfig
        check_kubectl
        configure_crictl
        check_kubernetes_cluster_health
        configure_kube_vip
        retrieve_token

        print_section_header "SYSTEM DEPENDENCIES" "PHASE 3/5"
        log "Installing system packages in airgapped mode on $NODE_TYPE..."
        install_nfs_client_airgapped
        install_kernel_airgapped
        install_iscsi_airgapped
        enable_and_start_iscsi
        install_jq_airgapped
        install_ux_tools_airgapped
        # Helm on every master (not only node3), so helm works on node1/2/3.
        # Releases live in the cluster, so every master sees the same ones.
        install_helm_airgapped
        check_helm_installed

        if [[ "$NODE_TYPE" == "node1" || "$NODE_TYPE" == "node2" ]]; then
            print_final_summary
            run_smoke_test
            offer_airgapped_cleanup
        fi
    fi

    # Update Longhorn replica count to 2 when scaling to node3 (cluster now has 3 nodes)
    if [[ "$ARGUMENT_TYPE" == "--scale-airgapped" && "$NODE_TYPE" == "node3" ]]; then
        log "Scaling complete: updating Longhorn default replica count from 1 to 2..."
        kubectl -n longhorn-system patch settings.longhorn.io default-replica-count \
            --type=merge -p '{"value":"2"}' >> "$LOG_FILE" 2>&1 \
            && log_success "Longhorn default replica count updated to 2." \
            || log_error "[WARNING] Could not update Longhorn replica count. Check cluster connectivity."

        # Also fix the StorageClass to use 2 replicas and best-effort
        fix_longhorn_default_storageclass

        print_final_summary
        run_smoke_test
        offer_airgapped_cleanup
    fi

    # Full stack install for node3 (airgapped only)
    if [[ "$ARGUMENT_TYPE" == "--airgapped" && "$NODE_TYPE" == "node3" ]]; then
        log "Installing calicoctl and AWS CLI in airgapped mode..."
        install_calicoctl_airgapped
        if ! check_nodes_ready "$NODES_NUMBER"; then
            log_error "Node readiness check failed. Exiting script"
            exit 1
        fi
        if [[ "$(get_deployment_profile)" == "ha-workers" ]]; then
            # Masters are tainted, so ingress, MetalLB, Longhorn and the smoke
            # test can only run once the workers have joined. node3 finishes
            # here; the stack is installed last with "--airgapped stack".
            log_success "node3 installation completed — all $NODES_NUMBER masters are Ready."
            print_stack_next_steps node3
        else
            install_cluster_stack
        fi
    fi

    # Final step of a 3 masters + workers install: run on node3 after the last worker
    if [[ "$ARGUMENT_TYPE" == "--airgapped" && "$NODE_TYPE" == "stack" ]]; then
        if ! systemctl is-active --quiet rke2-server.service; then
            log_error "[ERROR] '--airgapped stack' must run on a master node (node3) with RKE2 server running."
            exit 1
        fi
        print_section_header "CLUSTER STACK INSTALLATION" "FINAL STEP"
        install_calicoctl_airgapped
        local expected_nodes=$((NODES_NUMBER + WORKERS_NUMBER))
        log "Waiting for $NODES_NUMBER masters + $WORKERS_NUMBER workers to be Ready (timeout: ${WORKER_JOIN_TIMEOUT:-600}s)..."
        if ! check_nodes_ready "$expected_nodes" "${WORKER_JOIN_TIMEOUT:-600}"; then
            log_error "[ERROR] Not all workers are Ready. Install the missing worker(s) (--airgapped workerN), then re-run: ./$(basename "$0") --airgapped stack"
            exit 1
        fi
        install_cluster_stack
    fi

    # ==================== WORKER NODE INSTALLATION ====================
    if is_valid_worker_type "$NODE_TYPE"; then
        local worker_num="${NODE_TYPE//worker/}"
        log "Starting worker node $worker_num installation..."

        print_section_header "SYSTEM PREPARATION" "PHASE 1/3"
        preflight_checks
        check_limits_conf
        set_pid_max
        set_stack_size
        configure_kernel_tuning
        configure_nic_tuning
        install_irqbalance_airgapped
        configure_io_scheduler
        [[ "$OPTIMIZE_FILESYSTEM" == "true" ]] && optimize_filesystem
        check_node_ip
        check_firewall
        configure_hosts

        print_section_header "RKE2 AGENT INSTALLATION" "PHASE 2/3"
        log "Installing RKE2 Agent in airgapped mode on $NODE_TYPE..."
        install_rke2_agent_airgapped
        # Workers run the same containerd socket as a server, so crictl needs the
        # same endpoint here. Without it crictl probes the default endpoints and
        # the image verification in import_uc_images() fails on worker nodes.
        configure_crictl

        print_section_header "SYSTEM DEPENDENCIES" "PHASE 3/3"
        log "Installing system packages in airgapped mode on $NODE_TYPE..."
        install_nfs_client_airgapped
        install_kernel_airgapped
        install_iscsi_airgapped
        enable_and_start_iscsi
        install_jq_airgapped
        install_ux_tools_airgapped

        log_success "Worker node $NODE_TYPE installation completed!"
        log_success "The worker node should join the cluster within a few minutes."
        log_success "Verify on a master node with: kubectl get nodes"
        log_success "To apply the updated environment settings, please log out and log back in!"
        if [[ "$ARGUMENT_TYPE" == "--airgapped" && "$(get_deployment_profile)" == "ha-workers" ]]; then
            print_stack_next_steps worker "$worker_num"
        fi
        offer_airgapped_cleanup
    fi
}

# ==================== EARLY-EXIT MODE HANDLERS ====================
# These must be placed after all function definitions so that show_help,
# check_versions, collect_diagnostics, perform_upgrade, and perform_rollback
# are available when called.

if [[ "$ARGUMENT_TYPE" == "--help" ]]; then
    show_help
    exit 0
fi

if [[ "$ARGUMENT_TYPE" == "--check" ]]; then
    check_versions
    exit 0
fi

if [[ "$ARGUMENT_TYPE" == "--collect" ]]; then
    collect_diagnostics
    exit 0
fi

if [[ "$ARGUMENT_TYPE" == "--export-worker-kubeconfig" ]]; then
    export_worker_kubeconfig
    exit $?
fi

if [[ "$ARGUMENT_TYPE" == "--upgrade" ]]; then
    perform_upgrade
    exit $?
fi

if [[ "$ARGUMENT_TYPE" == "--rollback" ]]; then
    perform_rollback
    exit $?
fi

if [[ "$ARGUMENT_TYPE" == "--uninstall" ]]; then
    perform_uninstall
    exit $?
fi

main
