#!/usr/bin/env bash
set -Eeu -o pipefail   # -E lets ERR trap fire inside functions/subshells

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

# -------- defaults --------

current_time="$(date +%Y-%m-%d_%H-%M-%S)"
cleanup_ran=false
log_file=""
avd_name=""
log_dir="logs"
emulator_pid=""

# -------- helpers --------

on_err() {
  local line=$1
  echo "Error at line ${line} (cmd: ${BASH_COMMAND})." >&2
}

# TODO: cleanup from here should be moved to separate file
on_exit() {
  echo "Script finished. Running cleanup..."
  $cleanup_ran && return || cleanup_ran=true

  # Remove touch input indicator from emulator
  adb -e shell settings put system show_touches 0 || true

  # Kill emulator if it is still running
  if adb -e get-state >/dev/null 2>&1; then
    echo "Killing emulator..."
    adb -e emu kill || true

    echo "Waiting for emulator to shut down..."
    end=$((SECONDS+60))
    while adb -e get-state >/dev/null 2>&1; do
      (( SECONDS >= end )) && { echo "Timeout waiting for shutdown."; break; }
      sleep 1
    done
    echo "Emulator is down."
  else
    echo "No emulator running."
  fi

  echo "Cleanup done."
}

on_sig() {
  echo "Received termination signal, exiting..." >&2
  exit 130  # triggers EXIT trap
}

trap 'on_err $LINENO' ERR
trap on_exit EXIT
trap on_sig INT TERM

# -------- extracted utility functions --------

require_avd() {
  if [[ -z "${avd_name:-}" ]]; then
    echo "Error: --avd is required."
    usage
    exit 2
  fi
}

ensure_avd_exists() {
  if emulator -list-avds | grep -q "^${avd_name}$"; then
    echo "'${avd_name}' exists!"
  else
    echo "'${avd_name}' not found. Available AVDs:"
    emulator -list-avds || true
    printf '\n'
    exit 1
  fi
}

launch_emulator() {
  echo "Launching emulator."
  emulator \
    -avd "${avd_name}" \
    -no-snapshot \
    > "${log_file}" 2>&1 &
  emulator_pid=$!
  echo "Emulator PID: ${emulator_pid}"
}

wait_till_fully_booted() {
  # Args: timeout_seconds
  local timeout_seconds="${1:-60}"
  local end=$((SECONDS+timeout_seconds))
  echo "Waiting for emulator '${avd_name}' to be fully booted..."

  until adb -e shell getprop sys.boot_completed | grep -qm1 1; do
    # Also fail if the emulator process died during boot
    if [[ -n "${emulator_pid}" ]] && ! kill -0 "${emulator_pid}" 2>/dev/null; then
      echo "Emulator process ${emulator_pid} exited during boot."
      echo "Last lines from log:"
      tail -n 50 "${log_file}" || true
      exit 1
    fi
    (( SECONDS >= end )) && {
      echo "Timeout waiting for emulator '${avd_name}' to be fully booted."
      exit 1
    }
    sleep 5
  done
  echo "Emulator fully booted!"
}

set_show_touches() {
  # Args: 0|1
  local value="${1:-1}"
  # Best-effort; don't fail the script if unavailable
  adb -e shell settings put system show_touches "${value}" || true
}

# -------- arg parsing --------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --avd)
      [[ $# -ge 2 ]] || { echo "Error: --avd requires a value"; usage; exit 2; }
      avd_name="$2"; shift 2;;
    --avd=*) avd_name="${1#*=}"; shift;;

    --log-dir)
      [[ $# -ge 2 ]] || { echo "Error: --log-dir requires a value"; usage; exit 2; }
      log_dir="$2"; shift 2;;
    --log-dir=*) log_dir="${1#*=}"; shift;;

    --help|-h) usage; exit 0;;
    --) shift; break;;
    *)
      echo "Unknown option: $1"
      usage
      exit 2
      ;;
  esac
done

# -------- main --------

require_avd
mkdir -p "${log_dir}"
ensure_avd_exists

log_file="${log_dir}/${current_time}.log"
echo "Logs: '${log_file}'."

launch_emulator
wait_till_fully_booted 60

set_show_touches 1

# Run tests; if they fail, ERR trap + EXIT trap ensure cleanup
./gradlew connectedDebugAndroidTest
