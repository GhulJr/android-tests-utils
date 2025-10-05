#!/usr/bin/env bash
set -Eeu -o pipefail   # -E lets ERR trap fire inside functions/subshells

# ========================== Pretty logging ==========================
# Colors if TTY and not disabled by NO_COLOR
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  c_bold=$'\033[1m'; c_dim=$'\033[2m'
  c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_cyan=$'\033[36m'
  c_rst=$'\033[0m'
else
  c_bold=""; c_dim=""; c_red=""; c_grn=""; c_yel=""; c_cyan=""; c_rst=""
fi

ts() { date +"%Y-%m-%d %H:%M:%S"; }
log()   { printf "%s %s\n" "$(ts)" "$*"; }
INFO()  { log "${c_cyan}INFO${c_rst}  $*"; }
OK()    { log "${c_grn}OK${c_rst}    $*"; }
WARN()  { log "${c_yel}WARN${c_rst}  $*"; }
FAIL()  { log "${c_red}FAIL${c_rst}  $*"; }
STEP()  { printf "\n%s %s\n" "$(ts)" "${c_bold}── $* ─────────────────────────────────────────${c_rst}"; }

# ============================ Usage/help ============================
usage() {
  cat <<'USAGE'

Usage:
  run_ui_tests.sh --avd <name> [options]

Required:
  --avd <name>                 AVD name to launch.

Optional:
  --log-dir <dir>              Directory for logs (default: logs)
  --help, -h                   Show this help and exit

Notes:
- Unknown flags will cause an error (explicit is better for CI).

USAGE
}

# ============================ Defaults/state ============================
current_time="$(date +%Y-%m-%d_%H-%M-%S)"
cleanup_ran=false
log_file=""
avd_name=""
log_dir="logs"
emulator_pid=""
script_start=${SECONDS}

# ============================ Traps/handlers ============================
on_err() {
  local line=$1
  FAIL "Error at line ${line} (cmd: ${BASH_COMMAND})."
}

on_exit() {
  # Idempotent cleanup
  $cleanup_ran && return || cleanup_ran=true

  STEP "Cleanup"
  # Remove touch input indicator from emulator (best effort)
  if command -v adb >/dev/null 2>&1; then
    adb -e shell settings put system show_touches 0 >/dev/null 2>&1 || true
  fi

  # Kill emulator if it is still running
  if command -v adb >/dev/null 2>&1 && adb -e get-state >/dev/null 2>&1; then
    INFO "Killing emulator…"
    adb -e emu kill >/dev/null 2>&1 || true

    INFO "Waiting for emulator to shut down (60s)…"
    local end=$((SECONDS+60))
    while adb -e get-state >/dev/null 2>&1; do
      (( SECONDS >= end )) && { WARN "Timeout waiting for shutdown."; break; }
      sleep 1
    done
    OK "Emulator is down."
  else
    INFO "No emulator running."
  fi

  local elapsed=$((SECONDS - script_start))
  OK "Cleanup done. Total time: ${elapsed}s"
}

on_sig() {
  WARN "Received termination signal, exiting…"
  # Return 130 to indicate interrupted by signal; EXIT trap will run
  exit 130
}

trap 'on_err $LINENO' ERR
trap on_exit EXIT
trap on_sig INT TERM

# ======================= Small utility functions =======================
require_avd() {
  if [[ -z "${avd_name:-}" ]]; then
    FAIL "Missing required option: --avd"
    usage
    exit 2
  fi
}

ensure_avd_exists() {
  if emulator -list-avds | grep -qx -- "${avd_name}"; then
    OK "AVD '${avd_name}' exists."
  else
    FAIL "AVD '${avd_name}' not found."
    INFO "Available AVDs:"
    emulator -list-avds || true
    printf '\n'
    exit 1
  fi
}

launch_emulator() {
  STEP "Launch emulator"
  INFO "Starting emulator '${avd_name}' (logs → ${log_file})"
  emulator \
    -avd "${avd_name}" \
    -no-snapshot \
    > "${log_file}" 2>&1 &
  emulator_pid=$!
  OK "Emulator PID: ${emulator_pid}"
}

wait_till_fully_booted() {
  # Args: timeout_seconds
  local timeout_seconds="${1:-60}"
  local end=$((SECONDS+timeout_seconds))
  STEP "Wait for boot"
  INFO "Waiting for emulator '${avd_name}' to report sys.boot_completed=1 (timeout: ${timeout_seconds}s)…"

  until adb -e shell getprop sys.boot_completed 2>/dev/null | grep -qm1 1; do
    # Also fail if the emulator process died during boot
    if [[ -n "${emulator_pid}" ]] && ! kill -0 "${emulator_pid}" 2>/dev/null; then
      FAIL "Emulator process ${emulator_pid} exited during boot."
      INFO "Last 50 lines from emulator log:"
      tail -n 50 "${log_file}" || true
      exit 1
    fi
    (( SECONDS >= end )) && {
      FAIL "Timeout waiting for emulator '${avd_name}' to fully boot."
      INFO "Last 50 lines from emulator log:"
      tail -n 50 "${log_file}" || true
      exit 1
    }
    sleep 1
  done
  OK "Emulator fully booted."
}

set_show_touches() {
  # Args: 0|1
  local value="${1:-1}"
  # Best-effort; don't fail the script if unavailable
  STEP "Enable touch indicators"
  if adb -e shell settings put system show_touches "${value}" >/dev/null 2>&1; then
    OK "Show touches set to ${value}."
  else
    WARN "Could not set show_touches=${value} (ignored)."
  fi
}

# ============================ Arg parsing ============================
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --avd)
        [[ $# -ge 2 ]] || { FAIL "Error: --avd requires a value"; usage; exit 2; }
        avd_name="$2"; shift 2;;
      --avd=*) avd_name="${1#*=}"; shift;;

      --log-dir)
        [[ $# -ge 2 ]] || { FAIL "Error: --log-dir requires a value"; usage; exit 2; }
        log_dir="$2"; shift 2;;
      --log-dir=*) log_dir="${1#*=}"; shift;;

      --help|-h) usage; exit 0;;
      --) shift; break;;
      *)
        FAIL "Unknown option: $1"
        usage
        exit 2
        ;;
    esac
  done
}

# =============================== Main ===============================
main() {
  STEP "Argument parsing"
  parse_args "$@"
  require_avd

  STEP "Prepare environment"
  mkdir -p "${log_dir}"
  ensure_avd_exists

  log_file="${log_dir}/${current_time}.log"
  INFO "Script log file: ${c_bold}${log_file}${c_rst}"

  launch_emulator
  wait_till_fully_booted 60
  set_show_touches 1

  STEP "Run UI tests"
  INFO "Executing: ./gradlew connectedDebugAndroidTest"
  ./gradlew connectedDebugAndroidTest
  OK "Gradle connected tests finished."
}

main "$@"
