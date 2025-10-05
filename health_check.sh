#!/usr/bin/env sh
# ui_tests_health_check.sh — POSIX shell (works in bash, zsh, dash)
set -eu

# ------------------------------- usage --------------------------------
usage() {
  cat <<'USAGE'
Usage:
  ui_tests_health_check.sh [options]

Options:
  --sdk-root <path>            Override ANDROID_HOME/ANDROID_SDK_ROOT autodetect.
  --java-vendor <regex>        Require Java vendor/distribution to match this regex
                               (e.g. "Corretto|Temurin|Zulu|Oracle").
  --java-version <x.y.z>       Require exact Java runtime version (e.g. 17.0.8).
  --min-build-tools <ver>      Minimum Build-Tools version (e.g. 34.0.0).
  --platform-api <api>[,...]   Require one or more Android platform API levels
                               to be installed (e.g. 33 or 34). May repeat.
  --help, -h                   Show this help and exit.

Notes:
- Exits non-zero if any REQUIRED checks fail. Warnings do not affect exit code.
- Licenses are ALWAYS checked. If missing, this fails.
USAGE
}

# ------------------------------ state ---------------------------------
REQ_PLATFORM_APIS=""
SDK_ROOT_OVERRIDE=""
JAVA_VENDOR_RE=""
JAVA_VERSION_EXACT=""
MIN_BUILD_TOOLS=""

ERRORS=""
WARNINGS=""

# ----------------------------- logging --------------------------------
is_tty=0; [ -t 1 ] && is_tty=1
if [ "$is_tty" -eq 1 ]; then
  c_bold="$(printf '\033[1m')"; c_red="$(printf '\033[31m')"
  c_grn="$(printf '\033[32m')"; c_yel="$(printf '\033[33m')"
  c_cyan="$(printf '\033[36m')"; c_rst="$(printf '\033[0m')"
else
  c_bold=""; c_red=""; c_grn=""; c_yel=""; c_cyan=""; c_rst=""
fi

say()  { printf "%s\n" "$*"; }
info() { say "${c_cyan}INFO${c_rst}  $*"; }
ok()   { say "${c_grn}OK${c_rst}    $*"; }
warn() { WARNINGS="${WARNINGS}• $*\n"; say "${c_yel}WARN${c_rst}  $*"; }
fail() { ERRORS="${ERRORS}• $*\n"; say "${c_red}FAIL${c_rst}  $*"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# semver compare: echo 1 if A>=B else 0
semver_ge() {
  A="$1"; B="$2"
  a1=$(printf "%s" "$A" | awk -F. '{print $1+0}')
  a2=$(printf "%s" "$A" | awk -F. '{print ($2=="")?0:$2+0}')
  a3=$(printf "%s" "$A" | awk -F. '{print ($3=="")?0:$3+0}')
  b1=$(printf "%s" "$B" | awk -F. '{print $1+0}')
  b2=$(printf "%s" "$B" | awk -F. '{print ($2=="")?0:$2+0}')
  b3=$(printf "%s" "$B" | awk -F. '{print ($3=="")?0:$3+0}')
  if [ "$a1" -gt "$b1" ] || { [ "$a1" -eq "$b1" ] && [ "$a2" -gt "$b2" ]; } || \
     { [ "$a1" -eq "$b1" ] && [ "$a2" -eq "$b2" ] && [ "$a3" -ge "$b3" ]; }; then
    echo 1
  else
    echo 0
  fi
}

# append CSV or single value(s) to a space-separated list var (by name)
append_values() {
  varname="$1"; values="$2"
  # turn commas into spaces, strip extra spaces
  vals=$(printf "%s" "$values" | tr ',' ' ' | tr -s ' ')
  # shellcheck disable=SC2086
  eval "current=\${$varname-}"
  if [ -n "$current" ]; then
    eval "$varname=\"\$current \$vals\""
  else
    eval "$varname=\"\$vals\""
  fi
}

# ---------------------------- arg parsing ------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --platform-api)
      [ $# -ge 2 ] || { say "Error: --platform-api requires a value"; usage; exit 2; }
      append_values REQ_PLATFORM_APIS "$2"; shift 2;;
    --platform-api=*)  append_values REQ_PLATFORM_APIS "${1#*=}"; shift;;
    --sdk-root)        [ $# -ge 2 ] || { say "Error: --sdk-root requires a value"; usage; exit 2; }
                       SDK_ROOT_OVERRIDE="$2"; shift 2;;
    --sdk-root=*)      SDK_ROOT_OVERRIDE="${1#*=}"; shift;;
    --java-vendor)     [ $# -ge 2 ] || { say "Error: --java-vendor requires a value"; usage; exit 2; }
                       JAVA_VENDOR_RE="$2"; shift 2;;
    --java-vendor=*)   JAVA_VENDOR_RE="${1#*=}"; shift;;
    --java-version)    [ $# -ge 2 ] || { say "Error: --java-version requires a value"; usage; exit 2; }
                       JAVA_VERSION_EXACT="$2"; shift 2;;
    --java-version=*)  JAVA_VERSION_EXACT="${1#*=}"; shift;;
    --min-build-tools) [ $# -ge 2 ] || { say "Error: --min-build-tools requires a value"; usage; exit 2; }
                       MIN_BUILD_TOOLS="$2"; shift 2;;
    --min-build-tools=*) MIN_BUILD_TOOLS="${1#*=}"; shift;;
    --help|-h)         usage; exit 0;;
    --) shift; break;;
    *)  say "Unknown option: $1"; usage; exit 2;;
  esac
done

# --------------------------- helpers/checks ----------------------------
detect_sdk_root() {
  if [ -n "$SDK_ROOT_OVERRIDE" ]; then printf "%s" "$SDK_ROOT_OVERRIDE"; return; fi
  if [ -n "${ANDROID_SDK_ROOT-}" ]; then printf "%s" "$ANDROID_SDK_ROOT"; return; fi
  if [ -n "${ANDROID_HOME-}" ]; then printf "%s" "$ANDROID_HOME"; return; fi
  for p in "$HOME/Android/Sdk" "/usr/lib/android-sdk" "/opt/android-sdk" "/opt/android-sdk-linux"; do
    [ -d "$p" ] && { printf "%s" "$p"; return; }
  done
  printf ""
}

detect_java_details() {
  if ! have_cmd java; then
    fail "Java not found in PATH."; echo "||"; return
  fi
  banner="$(java -version 2>&1 || true)"
  props="$(java -XshowSettings:properties -version 2>&1 || true)"
  vendor="$(printf "%s" "$props" | awk -F'= ' '/^[[:space:]]*java\.vendor = /{print $2; exit}')"
  fullv="$(printf "%s" "$props" | awk -F'= ' '/^[[:space:]]*java\.runtime\.version = /{print $2; exit}')"
  [ -n "$fullv" ] || fullv="$(printf "%s" "$banner" | awk -F'[\" ]' '/version/{print $3; exit}')"

  vend_guess="$vendor"
  if [ -z "$vend_guess" ]; then
    lower="$(printf "%s" "$banner" | tr 'A-Z' 'a-z')"
    case "$lower" in
      *corretto*) vend_guess="Corretto" ;;
      *temurin*)  vend_guess="Temurin" ;;
      *zulu*)     vend_guess="Zulu" ;;
      *oracle*)   vend_guess="Oracle" ;;
      *ibm\ semeru*) vend_guess="Semeru" ;;
      *azul*)     vend_guess="Azul" ;;
      *)          vend_guess="Unknown" ;;
    esac
  fi
  printf "%s|%s|%s" "$fullv" "$vend_guess" "$(printf "%s" "$banner" | tr '\n' '\\')"
}

check_java() {
  details="$(detect_java_details)"
  fullv="$(printf "%s" "$details" | cut -d'|' -f1)"
  vend="$(printf "%s" "$details" | cut -d'|' -f2)"
  banner_esc="$(printf "%s" "$details" | cut -d'|' -f3)"

  if [ -z "$fullv" ]; then
    fail "Unable to detect Java runtime version."
    return
  fi

  if [ -n "$JAVA_VENDOR_RE" ]; then
    # Use grep -E on a combined string of vendor + banner
    if ! printf "%s\n" "$vend $banner_esc" | grep -Ei -- "$JAVA_VENDOR_RE" >/dev/null 2>&1; then
      fail "Java vendor mismatch. Wanted /$JAVA_VENDOR_RE/, got '$vend'."
    else
      ok "Java vendor matches /$JAVA_VENDOR_RE/ ($vend)."
    fi
  else
    ok "Java vendor detected: $vend"
  fi

  if [ -n "$JAVA_VERSION_EXACT" ]; then
    if [ "$fullv" = "$JAVA_VERSION_EXACT" ]; then
      ok "Java version matches $JAVA_VERSION_EXACT."
    else
      fail "Java version mismatch. Wanted $JAVA_VERSION_EXACT, got $fullv."
    fi
  else
    ok "Java runtime version detected: $fullv"
  fi
}

check_gradle_wrapper() {
  if [ -x "./gradlew" ]; then
    ok "Gradle wrapper present (./gradlew)."
  elif have_cmd gradle; then
    warn "Gradle wrapper missing; using system 'gradle' may cause CI inconsistencies."
  else
    fail "Neither ./gradlew nor 'gradle' found."
  fi
}

check_sdk_root() {
  SDK_ROOT="$(detect_sdk_root)"
  if [ -z "${SDK_ROOT:-}" ]; then
    fail "Android SDK root not found. Set ANDROID_SDK_ROOT or ANDROID_HOME, or pass --sdk-root."
    return
  fi
  if [ ! -d "$SDK_ROOT" ]; then
    fail "SDK root path does not exist: $SDK_ROOT"
    return
  fi
  ok "Android SDK root: $SDK_ROOT"
}

check_tools_presence() {
  adb_bin="$SDK_ROOT/platform-tools/adb"
  emulator_bin="$SDK_ROOT/emulator/emulator"

  # sdkmanager/avdmanager may be in PATH or in cmdline-tools/*/bin
  sdkmanager_bin="$(command -v sdkmanager 2>/dev/null || true)"
  avdmanager_bin="$(command -v avdmanager 2>/dev/null || true)"
  if [ -z "$sdkmanager_bin" ] || [ -z "$avdmanager_bin" ]; then
    if [ -d "$SDK_ROOT/cmdline-tools" ]; then
      latest="$(ls -1 "$SDK_ROOT/cmdline-tools" 2>/dev/null | grep -v '^bin$' | sort | tail -n1 || true)"
      if [ -n "$latest" ] && [ -x "$SDK_ROOT/cmdline-tools/$latest/bin/sdkmanager" ]; then
        sdkmanager_bin="$SDK_ROOT/cmdline-tools/$latest/bin/sdkmanager"
        avdmanager_bin="$SDK_ROOT/cmdline-tools/$latest/bin/avdmanager"
      fi
    fi
  fi

  [ -x "$adb_bin" ]       && ok "adb present ($adb_bin)"           || fail "Missing platform-tools/adb under SDK."
  [ -x "$emulator_bin" ]  && ok "emulator present ($emulator_bin)" || fail "Missing emulator under SDK."
  [ -n "$sdkmanager_bin" ]&& ok "sdkmanager found ($sdkmanager_bin)" || fail "sdkmanager not found (install cmdline-tools)."
  [ -n "$avdmanager_bin" ]&& ok "avdmanager found ($avdmanager_bin)" || fail "avdmanager not found (install cmdline-tools)."
}

check_platform_tools_version() {
  vfile="$SDK_ROOT/platform-tools/source.properties"
  if [ -f "$vfile" ]; then
    ver="$(grep '^Pkg.Revision=' "$vfile" 2>/dev/null | cut -d= -f2 || true)"
    [ -n "$ver" ] && ok "platform-tools version $ver" || warn "platform-tools present but version unknown."
  else
    warn "platform-tools source.properties not found; version unknown."
  fi
}

# find latest build-tools by comparing versions ourselves (POSIX-safe)
latest_build_tools_version() {
  dir="$SDK_ROOT/build-tools"
  best=""
  for d in "$dir"/*; do
    [ -d "$d" ] || continue
    v="$(basename "$d")"
    if [ -z "$best" ]; then best="$v"; else
      if [ "$(semver_ge "$v" "$best")" -eq 1 ]; then best="$v"; fi
    fi
  done
  printf "%s" "$best"
}

check_build_tools() {
  dir="$SDK_ROOT/build-tools"
  if [ ! -d "$dir" ]; then fail "No Build-Tools installed under $dir."; return; fi
  latest="$(latest_build_tools_version)"
  if [ -z "$latest" ]; then
    fail "Build-Tools directory exists but empty."
    return
  fi
  ok "Build-Tools installed (latest: $latest)"
  if [ -n "$MIN_BUILD_TOOLS" ] && [ "$(semver_ge "$latest" "$MIN_BUILD_TOOLS")" -ne 1 ]; then
    fail "Build-Tools $latest < required $MIN_BUILD_TOOLS."
  fi
}

check_platforms() {
  dir="$SDK_ROOT/platforms"
  if [ ! -d "$dir" ]; then fail "No Android platforms installed under $dir."; return; fi
  installed_apis="$(ls -1 "$dir" 2>/dev/null | sed -n 's/^android-\([0-9][0-9]*\)$/\1/p' | sort -n || true)"
  if [ -z "$installed_apis" ]; then
    fail "No API levels present in $dir."
    return
  fi
  ok "Installed Android APIs: $(printf "%s" "$installed_apis" | tr '\n' ' ' | sed 's/ $//')"

  # verify required ones
  for api in $REQ_PLATFORM_APIS; do
    if printf "%s\n" "$installed_apis" | grep -qx "$api"; then
      ok "Required platform API $api is installed."
    else
      fail "Required platform API $api is NOT installed (expected $dir/android-$api)."
    fi
  done
}

check_licenses() {
  licdir="$SDK_ROOT/licenses"
  if [ ! -d "$licdir" ]; then
    fail "SDK licenses directory missing ($licdir). Run: yes | sdkmanager --licenses"
    return
  fi
  have_android=0; [ -s "$licdir/android-sdk-license" ] && have_android=1
  have_preview=0; [ -s "$licdir/android-sdk-preview-license" ] && have_preview=1

  if [ "$have_android" -eq 1 ]; then ok "android-sdk-license present."
  else fail "android-sdk-license missing. Run: yes | sdkmanager --licenses"; fi

  if [ "$have_preview" -eq 1 ]; then ok "android-sdk-preview-license present."
  else warn "android-sdk-preview-license missing (OK unless using preview SDKs)."; fi
}

# ------------------------------- main ---------------------------------
main() {
  info "Starting Android UI tests health check…"

  check_java
  check_gradle_wrapper
  check_sdk_root

  if [ -n "${SDK_ROOT:-}" ] && [ -d "$SDK_ROOT" ]; then
    check_tools_presence
    check_platform_tools_version
    check_build_tools
    check_platforms
    check_licenses
  fi

  say ""
  say "${c_bold}Summary:${c_rst}"
  if [ -n "$ERRORS" ]; then
    printf "  ${c_red}%s${c_rst}\n" "REQUIRED checks failed:"
    printf "    %b" "$ERRORS"
  else
    printf "  ${c_grn}%s${c_rst}\n" "All REQUIRED checks passed."
  fi
  if [ -n "$WARNINGS" ]; then
    printf "  ${c_yel}%s${c_rst}\n" "Warnings:"
    printf "    %b" "$WARNINGS"
  fi
  say ""
  if [ -n "$ERRORS" ]; then
    say "${c_red}Health check FAILED.${c_rst}"; exit 1
  else
    say "${c_grn}Health check PASSED.${c_rst}"
  fi
}

main "$@"
