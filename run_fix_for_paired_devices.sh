#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo --preserve-env=PATH "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACT_SCRIPT="$SCRIPT_DIR/fix_bluetooth.sh"

MOUNT_DIR=""
BLUEZ_DIR="/var/lib/bluetooth"
USE_ALL_KNOWN=0
USE_CONNECTED_ONLY=0
SKIP_INSTALL=0
NO_WRITE_BLUEZ_INFO=0
NO_RESTART_BLUETOOTH=0
LAST_RUN_MODIFIED=0
LAST_RUN_MODIFIED_FILES=0
LAST_RUN_UNCHANGED_FILES=0
LAST_RUN_STATUS=""
LAST_RUN_ERROR=""
VERBOSE="${VERBOSE:-0}"
COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_RESET='\033[0m'

usage() {
  cat <<'EOF'
Usage:
  ./run_fix_for_paired_devices.sh [options]

Options:
  -m, --mount-dir DIR      Mounted Windows root directory (required)
  --connected-only         Use only currently connected device MACs
  --all-known              Use all known device MACs from /var/lib/bluetooth
  --bluez-dir DIR          BlueZ base dir (default: /var/lib/bluetooth)
  --skip-install           Pass through to extract script
  --no-write-bluez-info    Pass through to extract script
  --no-restart-bluetooth   Do not restart bluetooth at end of batch
  -h, --help               Show this help

Default behavior:
  - Collect paired Bluetooth device MAC addresses (via bluetoothctl)
  - Run fix_bluetooth.sh once per discovered MAC
  - Restart bluetooth once at end if any info file was modified

Note:
  - If not run as root, the script auto re-runs itself with sudo.
EOF
}

log() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    printf '[*] %s\n' "$*"
  fi
}

warn() {
  printf '[!] %s\n' "$*" >&2
}

die() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--mount-dir)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        MOUNT_DIR="$2"
        shift 2
        ;;
      --connected-only)
        USE_CONNECTED_ONLY=1
        shift
        ;;
      --all-known)
        USE_ALL_KNOWN=1
        shift
        ;;
      --bluez-dir)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        BLUEZ_DIR="$2"
        shift 2
        ;;
      --skip-install)
        SKIP_INSTALL=1
        shift
        ;;
      --no-write-bluez-info)
        NO_WRITE_BLUEZ_INFO=1
        shift
        ;;
      --no-restart-bluetooth)
        NO_RESTART_BLUETOOTH=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

validate_inputs() {
  [[ -n "$MOUNT_DIR" ]] || die "You must pass --mount-dir <path>"
  [[ -d "$MOUNT_DIR" ]] || die "Mount directory does not exist: $MOUNT_DIR"
  [[ -f "$EXTRACT_SCRIPT" ]] || die "Extractor script not found: $EXTRACT_SCRIPT"
  [[ -d "$BLUEZ_DIR" ]] || warn "BlueZ directory not found: $BLUEZ_DIR"
}

extract_macs_from_text() {
  grep -Eo '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | tr '[:lower:]' '[:upper:]' | sort -u
}

get_connected_macs() {
  if ! command -v bluetoothctl >/dev/null 2>&1; then
    warn "bluetoothctl not found; cannot query connected devices"
    return 0
  fi

  local found=0

  local connected_output
  connected_output="$(bluetoothctl devices Connected 2>/dev/null || true)"
  if [[ -n "$connected_output" ]]; then
    found=1
    printf '%s\n' "$connected_output" | extract_macs_from_text
    return 0
  fi

  local all_devices
  all_devices="$(bluetoothctl devices 2>/dev/null || true)"
  if [[ -z "$all_devices" ]]; then
    return 0
  fi

  local mac
  while IFS= read -r mac; do
    if bluetoothctl info "$mac" 2>/dev/null | grep -qi '^\s*Connected:\s*yes'; then
      found=1
      printf '%s\n' "$mac"
    fi
  done < <(printf '%s\n' "$all_devices" | extract_macs_from_text)

  if [[ "$found" -eq 0 ]]; then
    return 0
  fi
}

get_paired_macs() {
  if ! command -v bluetoothctl >/dev/null 2>&1; then
    warn "bluetoothctl not found; cannot query paired devices"
    return 0
  fi

  local paired_output
  paired_output="$(bluetoothctl paired-devices 2>/dev/null || true)"
  if [[ -z "$paired_output" ]]; then
    paired_output="$(bluetoothctl devices Paired 2>/dev/null || true)"
  fi
  if [[ -n "$paired_output" ]]; then
    printf '%s\n' "$paired_output" | extract_macs_from_text
    return 0
  fi

  local all_devices
  all_devices="$(bluetoothctl devices 2>/dev/null || true)"
  if [[ -z "$all_devices" ]]; then
    return 0
  fi

  local mac
  while IFS= read -r mac; do
    if bluetoothctl info "$mac" 2>/dev/null | grep -qi '^\s*Paired:\s*yes'; then
      printf '%s\n' "$mac"
    fi
  done < <(printf '%s\n' "$all_devices" | extract_macs_from_text)
}

get_all_known_macs() {
  if [[ ! -d "$BLUEZ_DIR" ]]; then
    return 0
  fi

  sudo find "$BLUEZ_DIR" -mindepth 2 -maxdepth 2 -type d 2>/dev/null \
    | awk -F/ '{print $NF}' \
    | grep -E '^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$' \
    | tr '[:lower:]' '[:upper:]' \
    | sort -u
}

get_device_name() {
  local mac="$1"
  local name=""

  if command -v bluetoothctl >/dev/null 2>&1; then
    name="$(bluetoothctl info "$mac" 2>/dev/null | sed -n 's/^\s*Name:\s*//p' | head -n 1)"
    if [[ -z "$name" ]]; then
      name="$(bluetoothctl info "$mac" 2>/dev/null | sed -n 's/^\s*Alias:\s*//p' | head -n 1)"
    fi
  fi

  if [[ -z "$name" ]]; then
    name="$mac"
  fi

  printf '%s\n' "$name"
}

run_for_mac() {
  local mac="$1"
  local -a cmd=(bash "$EXTRACT_SCRIPT" --mount-dir "$MOUNT_DIR" --device-mac "$mac" --bluez-dir "$BLUEZ_DIR")
  local output
  local summary_line
  local modified
  local unchanged

  if [[ "$SKIP_INSTALL" -eq 1 ]]; then
    cmd+=(--skip-install)
  fi
  if [[ "$NO_WRITE_BLUEZ_INFO" -eq 1 ]]; then
    cmd+=(--no-write-bluez-info)
  fi

  cmd+=(--no-restart-bluetooth)

  log "Running extractor for device: $mac"
  LAST_RUN_MODIFIED=0
  LAST_RUN_MODIFIED_FILES=0
  LAST_RUN_UNCHANGED_FILES=0
  LAST_RUN_STATUS="unknown"
  LAST_RUN_ERROR=""

  if ! output="$("${cmd[@]}" 2>&1)"; then
    LAST_RUN_STATUS="failed"
    LAST_RUN_ERROR="$(grep -E '^\[[x!]\]' <<<"$output" | tail -n 1 || true)"
    [[ -n "$LAST_RUN_ERROR" ]] || LAST_RUN_ERROR="extractor failed"
    return 1
  fi

  summary_line="$(grep -E '^BLUEZ_WRITE_SUMMARY ' <<<"$output" | tail -n 1 || true)"
  if [[ -n "$summary_line" ]]; then
    modified="$(sed -n 's/.*modified=\([0-9][0-9]*\).*/\1/p' <<<"$summary_line")"
    unchanged="$(sed -n 's/.*unchanged=\([0-9][0-9]*\).*/\1/p' <<<"$summary_line")"
    if [[ -n "$modified" ]]; then
      LAST_RUN_MODIFIED_FILES="$modified"
      if [[ "$modified" -gt 0 ]]; then
        LAST_RUN_MODIFIED=1
        LAST_RUN_STATUS="modified"
      else
        LAST_RUN_STATUS="unchanged"
      fi
    fi
    if [[ -n "$unchanged" ]]; then
      LAST_RUN_UNCHANGED_FILES="$unchanged"
    fi
  elif [[ "$NO_WRITE_BLUEZ_INFO" -eq 1 ]]; then
    LAST_RUN_STATUS="skipped-write"
  else
    LAST_RUN_STATUS="no-summary"
  fi
}

restart_bluetooth_once() {
  if [[ "$NO_RESTART_BLUETOOTH" -eq 1 ]]; then
    return
  fi

  log "Restarting bluetooth service once at end"
  if sudo systemctl restart bluetooth; then
    log "Bluetooth service restarted"
  elif sudo service bluetooth restart; then
    log "Bluetooth service restarted (service command)"
  else
    warn "Could not restart bluetooth service automatically"
  fi
}

main() {
  parse_args "$@"
  validate_inputs

  local -a macs=()

  if [[ "$USE_ALL_KNOWN" -eq 1 ]]; then
    log "Collecting all known device MACs from $BLUEZ_DIR"
    mapfile -t macs < <(get_all_known_macs)
  elif [[ "$USE_CONNECTED_ONLY" -eq 1 ]]; then
    log "Collecting currently connected Bluetooth device MACs"
    mapfile -t macs < <(get_connected_macs)
    if [[ ${#macs[@]} -eq 0 ]]; then
      warn "No connected devices found; falling back to paired devices"
      mapfile -t macs < <(get_paired_macs)
    fi
  else
    log "Collecting paired Bluetooth device MACs"
    mapfile -t macs < <(get_paired_macs)
    if [[ ${#macs[@]} -eq 0 ]]; then
      warn "No paired devices found; falling back to all known devices"
      mapfile -t macs < <(get_all_known_macs)
    fi
  fi

  [[ ${#macs[@]} -gt 0 ]] || die "No Bluetooth device MAC addresses found"
  log "Found ${#macs[@]} device(s)"

  local mac
  local device_name
  local failures=0
  local modified_devices=0
  local modified_files_total=0
  local -a modified_device_list=()
  for mac in "${macs[@]}"; do
    device_name="$(get_device_name "$mac")"

    if ! run_for_mac "$mac"; then
      printf '[*] Device %s (%s): %bFAILED%b\n' "$mac" "$device_name" "$COLOR_RED" "$COLOR_RESET"
      failures=$((failures + 1))
      continue
    fi

    if [[ "$LAST_RUN_MODIFIED" -eq 1 ]]; then
      printf '[*] Device %s (%s): %bSUCCESS%b\n' "$mac" "$device_name" "$COLOR_GREEN" "$COLOR_RESET"
      modified_devices=$((modified_devices + 1))
      modified_files_total=$((modified_files_total + LAST_RUN_MODIFIED_FILES))
      modified_device_list+=("$mac")
    fi
  done

  if [[ "$modified_devices" -gt 0 ]]; then
    restart_bluetooth_once
  fi

  if [[ "$failures" -gt 0 ]]; then
    die "Completed with $failures failure(s)"
  fi
}

main "$@"
