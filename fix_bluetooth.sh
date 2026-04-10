#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo --preserve-env=PATH "$0" "$@"
fi

MOUNT_DIR=""
SKIP_INSTALL=0
ADAPTER_MAC=""
DEVICE_MAC=""
INTERACTIVE=0
WRITE_BLUEZ_INFO=1
RESTART_BLUETOOTH=1
BLUEZ_BASE_DIR="/var/lib/bluetooth"
FOUND_ADAPTER_MAC=""
FOUND_PAIRING_KEY=""

usage() {
  cat <<'EOF'
Usage:
  ./fix_bluetooth.sh [options]

Options:
  -m, --mount-dir DIR    Mounted Windows root directory (required)
  --interactive          Open interactive chntpw shell instead of auto mode
  -a, --adapter-mac MAC  Bluetooth adapter MAC key (optional, 12 hex chars)
  -d, --device-mac MAC   Paired device MAC value name (required in auto mode)
  --write-bluez-info     Write found key into BlueZ info file (default)
  --no-write-bluez-info  Do not write key to BlueZ info file
  --restart-bluetooth    Restart bluetooth service after write (default)
  --no-restart-bluetooth Do not restart bluetooth service after write
  --bluez-dir DIR        BlueZ base dir (default: /var/lib/bluetooth)
  --skip-install         Do not auto-install chntpw
  -h, --help             Show this help

What this script does:
  1) Ensures chntpw is available (installs via your distro package manager when needed)
  2) Uses your already-mounted Windows directory
  3) Runs non-interactively by default (auto commands + exit)
  4) If adapter MAC is omitted, auto-searches all adapter keys
  5) Opens interactive shell only when --interactive is provided
  6) Writes extracted key to BlueZ info by default
  7) Restarts bluetooth service by default after write

Note:
  - If not run as root, the script auto re-runs itself with sudo.
EOF
}

log() {
  printf '[*] %s\n' "$*"
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
      -a|--adapter-mac)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        ADAPTER_MAC="$2"
        shift 2
        ;;
      -d|--device-mac)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        DEVICE_MAC="$2"
        shift 2
        ;;
      --write-bluez-info)
        WRITE_BLUEZ_INFO=1
        shift
        ;;
      --no-write-bluez-info)
        WRITE_BLUEZ_INFO=0
        shift
        ;;
      --restart-bluetooth)
        RESTART_BLUETOOTH=1
        shift
        ;;
      --no-restart-bluetooth)
        RESTART_BLUETOOTH=0
        shift
        ;;
      --bluez-dir)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        BLUEZ_BASE_DIR="$2"
        shift 2
        ;;
      --interactive)
        INTERACTIVE=1
        shift
        ;;
      --skip-install)
        SKIP_INSTALL=1
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

normalize_mac() {
  local raw="$1"
  local normalized
  normalized="$(printf '%s' "$raw" | tr -d '[:space:]:-' | tr '[:upper:]' '[:lower:]')"
  if [[ ! "$normalized" =~ ^[0-9a-f]{12}$ ]]; then
    die "Invalid MAC format: $raw (example accepted form: 84:0F:2A:D3:A5:31)"
  fi
  printf '%s\n' "$normalized"
}

mac_to_colon_upper() {
  local normalized
  normalized="$(normalize_mac "$1")"
  printf '%s:%s:%s:%s:%s:%s\n' \
    "${normalized:0:2}" "${normalized:2:2}" "${normalized:4:2}" \
    "${normalized:6:2}" "${normalized:8:2}" "${normalized:10:2}" | tr '[:lower:]' '[:upper:]'
}

ensure_chntpw() {
  if command -v chntpw >/dev/null 2>&1; then
    return
  fi

  if [[ "$SKIP_INSTALL" -eq 1 ]]; then
    die "chntpw is not installed and --skip-install was provided"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    log "Installing chntpw via apt"
    apt-get update
    apt-get install -y chntpw
  elif command -v dnf >/dev/null 2>&1; then
    log "Installing chntpw via dnf"
    dnf install -y chntpw
  elif command -v yum >/dev/null 2>&1; then
    log "Installing chntpw via yum"
    yum install -y chntpw
  elif command -v pacman >/dev/null 2>&1; then
    log "Installing chntpw via pacman"
    pacman -Sy --noconfirm chntpw
  elif command -v zypper >/dev/null 2>&1; then
    log "Installing chntpw via zypper"
    zypper --non-interactive install chntpw
  elif command -v apk >/dev/null 2>&1; then
    log "Installing chntpw via apk"
    apk add --no-cache chntpw
  elif command -v xbps-install >/dev/null 2>&1; then
    log "Installing chntpw via xbps-install"
    xbps-install -Sy chntpw
  else
    die "Could not detect a supported package manager. Please install chntpw manually and rerun."
  fi

  if ! command -v chntpw >/dev/null 2>&1; then
    die "Installation command completed but chntpw is still unavailable"
  fi
}

validate_mount_dir() {
  [[ -n "$MOUNT_DIR" ]] || die "You must pass --mount-dir <path>"
  [[ -d "$MOUNT_DIR" ]] || die "Mount directory does not exist: $MOUNT_DIR"
}

validate_mode_args() {
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    if [[ -n "$ADAPTER_MAC" || -n "$DEVICE_MAC" ]]; then
      warn "Ignoring --adapter-mac/--device-mac because --interactive was provided"
    fi
    return
  fi

  [[ -n "$DEVICE_MAC" ]] || die "Missing --device-mac (required in default non-interactive mode)"

  DEVICE_MAC="$(normalize_mac "$DEVICE_MAC")"
  if [[ -n "$ADAPTER_MAC" ]]; then
    ADAPTER_MAC="$(normalize_mac "$ADAPTER_MAC")"
  fi

  if [[ "$WRITE_BLUEZ_INFO" -eq 1 ]]; then
    [[ -n "$BLUEZ_BASE_DIR" ]] || die "--bluez-dir cannot be empty"
  fi
}

find_config_dir() {
  local lower="$MOUNT_DIR/Windows/System32/config"
  local upper="$MOUNT_DIR/WINDOWS/System32/config"

  if [[ -d "$lower" ]]; then
    printf '%s\n' "$lower"
    return
  fi

  if [[ -d "$upper" ]]; then
    printf '%s\n' "$upper"
    return
  fi

  die "Could not find Windows registry config directory under $MOUNT_DIR"
}

print_chntpw_instructions() {
  cat <<'EOF'

Inside chntpw console, run:

cd ControlSet001\Services\BTHPORT\Parameters\Keys
ls

# If ControlSet001 doesn't exist, try:
# cd CurrentControlSet\Services\BTHPORT\Parameters\Keys

# On some Windows 7 setups, try lowercase "services":
# cd ControlSet001\services\BTHPORT\Parameters\Keys

# Then:
# - cd into your Bluetooth adapter MAC key (for example aa1122334455)
# - run ls to list device MAC entries
# - run hex <device-mac-entry-name>
#   example: hex 001f20eb4c9a

# The first 16 bytes (XX XX ... XX) are the pairing key.
EOF
}

list_adapter_keys() {
  local config_dir="$1"
  local -a key_paths=(
    'ControlSet001\Services\BTHPORT\Parameters\Keys'
    'CurrentControlSet\Services\BTHPORT\Parameters\Keys'
    'ControlSet001\services\BTHPORT\Parameters\Keys'
  )
  local path
  for path in "${key_paths[@]}"; do
    (
      cd "$config_dir"
      printf '%s\n' \
        "cd \\$path" \
        'ls' \
        'q' \
        'n' | sudo chntpw -e SYSTEM
    )
  done | grep -Eoi '<[0-9a-f]{12}>' | tr -d '<>' | tr '[:upper:]' '[:lower:]' | sort -u
}

run_non_interactive_for_adapter() {
  local config_dir="$1"
  local adapter="$2"
  local -a key_paths=(
    'ControlSet001\Services\BTHPORT\Parameters\Keys'
    'CurrentControlSet\Services\BTHPORT\Parameters\Keys'
    'ControlSet001\services\BTHPORT\Parameters\Keys'
  )
  local path
  local output
  local pairing_key
  local pairing_key_compact

  log "Trying adapter: $adapter"
  for path in "${key_paths[@]}"; do
    output="$(
      cd "$config_dir"
      printf '%s\n' \
        "cd \\$path" \
        "cd $adapter" \
        "hex $DEVICE_MAC" \
        'q' \
        'n' | sudo chntpw -e SYSTEM
    2>&1)"

    if grep -qi "Value <$DEVICE_MAC>" <<<"$output"; then
      printf '%s\n' "$output"
      log "Matched in path: $path"
      pairing_key="$(awk '
        /^[[:space:]]*:00000([[:space:]]|$)/ {
          key = ""
          for (i = 2; i <= NF; i++) {
            if ($i ~ /^[0-9A-Fa-f]{2}$/) {
              key = key (key ? " " : "") tolower($i)
            } else {
              break
            }
          }
          if (key != "") {
            print key
            exit
          }
        }
      ' <<<"$output")"

      if [[ -z "$pairing_key" ]]; then
        pairing_key="$(grep -Eo '([0-9A-Fa-f]{2}[[:space:]]+){15}[0-9A-Fa-f]{2}' <<<"$output" | head -n 1 | tr '[:upper:]' '[:lower:]' | xargs || true)"
      fi

      if [[ -n "$pairing_key" ]]; then
        pairing_key_compact="${pairing_key// /}"
        log "Device $DEVICE_MAC value: $pairing_key_compact"
        FOUND_ADAPTER_MAC="$adapter"
        FOUND_PAIRING_KEY="$pairing_key_compact"
        return 0
      fi

      warn "Matched device $DEVICE_MAC but failed to parse pairing key bytes in path: $path"
    fi
  done

  warn "Device MAC $DEVICE_MAC not found under adapter $adapter"
  return 1
}

write_key_to_bluez_info() {
  [[ -n "$FOUND_PAIRING_KEY" ]] || return 0

  local device_colon
  local -a info_paths=()
  local info_path
  local tmp_in
  local tmp_out
  local fallback_info_path
  local fallback_info_dir

  device_colon="$(mac_to_colon_upper "$DEVICE_MAC")"
  log "Searching BlueZ info files for device $device_colon under $BLUEZ_BASE_DIR"
  mapfile -t info_paths < <(sudo find "$BLUEZ_BASE_DIR" -type f -path "*/$device_colon/info" 2>/dev/null || true)

  if [[ ${#info_paths[@]} -eq 0 ]]; then
    if [[ -n "$FOUND_ADAPTER_MAC" ]]; then
      fallback_info_dir="$BLUEZ_BASE_DIR/$(mac_to_colon_upper "$FOUND_ADAPTER_MAC")/$device_colon"
      fallback_info_path="$fallback_info_dir/info"
      log "No existing device info found; creating fallback: $fallback_info_path"
      sudo mkdir -p "$fallback_info_dir"
      info_paths=("$fallback_info_path")
    else
      warn "No matching BlueZ info file found for $device_colon"
      return 0
    fi
  fi

  local updated_count=0
  local unchanged_count=0
  for info_path in "${info_paths[@]}"; do
    log "Writing key to $info_path"

    tmp_in="$(mktemp)"
    tmp_out="$(mktemp)"

    if sudo test -f "$info_path"; then
      sudo cat "$info_path" > "$tmp_in"
    else
      : > "$tmp_in"
    fi

    awk -v key="$FOUND_PAIRING_KEY" '
      BEGIN {
        in_linkkey = 0
        saw_linkkey = 0
        wrote_key = 0
      }
      {
        if ($0 ~ /^\[LinkKey\]$/) {
          saw_linkkey = 1
          in_linkkey = 1
          print
          next
        }

        if ($0 ~ /^\[/ && $0 !~ /^\[LinkKey\]$/) {
          if (in_linkkey && !wrote_key) {
            print "Key=" key
            wrote_key = 1
          }
          in_linkkey = 0
        }

        if (in_linkkey && $0 ~ /^Key=/) {
          if (!wrote_key) {
            print "Key=" key
            wrote_key = 1
          }
          next
        }

        print
      }
      END {
        if (!saw_linkkey) {
          print ""
          print "[LinkKey]"
          print "Key=" key
          print "Type=4"
          print "PINLength=0"
        } else if (in_linkkey && !wrote_key) {
          print "Key=" key
        }
      }
    ' "$tmp_in" > "$tmp_out"

    if sudo test -f "$info_path" && cmp -s "$tmp_in" "$tmp_out"; then
      unchanged_count=$((unchanged_count + 1))
      log "No change needed for $info_path"
      rm -f "$tmp_in" "$tmp_out"
      continue
    fi

    sudo install -m 600 "$tmp_out" "$info_path"
    rm -f "$tmp_in" "$tmp_out"
    updated_count=$((updated_count + 1))
  done

  log "BlueZ info summary for $device_colon: modified=$updated_count unchanged=$unchanged_count"
  printf 'BLUEZ_WRITE_SUMMARY device=%s modified=%d unchanged=%d\n' "$device_colon" "$updated_count" "$unchanged_count"
}

restart_bluetooth_service() {
  if [[ "$RESTART_BLUETOOTH" -eq 0 ]]; then
    return
  fi

  log "Restarting bluetooth service"
  if sudo systemctl restart bluetooth; then
    log "Bluetooth service restarted"
  elif sudo service bluetooth restart; then
    log "Bluetooth service restarted (service command)"
  else
    warn "Could not restart bluetooth service automatically"
  fi
}

run_non_interactive() {
  local config_dir="$1"
  local adapters=()

  log "Running chntpw in non-interactive mode"
  log "Device MAC value: $DEVICE_MAC"
  log "Trying ControlSet001, CurrentControlSet, and lowercase services fallbacks"

  if [[ -n "$ADAPTER_MAC" ]]; then
    adapters=("$ADAPTER_MAC")
    log "Using provided adapter key: $ADAPTER_MAC"
  else
    log "No adapter MAC provided; discovering adapter keys"
    mapfile -t adapters < <(list_adapter_keys "$config_dir")
    [[ ${#adapters[@]} -gt 0 ]] || die "No adapter keys found under BTHPORT\\Parameters\\Keys"
    log "Found ${#adapters[@]} adapter key(s)"
  fi

  local adapter
  local found=0
  for adapter in "${adapters[@]}"; do
    if run_non_interactive_for_adapter "$config_dir" "$adapter"; then
      found=1
      break
    fi
  done

  if [[ "$found" -eq 0 ]]; then
    die "No matching device key found for $DEVICE_MAC in any tested adapter/path"
  fi
}

run_interactive() {
  local config_dir="$1"
  log "Opening chntpw registry editor for SYSTEM hive (interactive mode)"
  print_chntpw_instructions
  echo
  (cd "$config_dir" && sudo chntpw -e SYSTEM)
}

run_chntpw() {
  local config_dir="$1"
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    run_interactive "$config_dir"
    return
  fi

  run_non_interactive "$config_dir"
}

main() {
  parse_args "$@"
  ensure_chntpw
  validate_mount_dir
  validate_mode_args

  local config_dir
  config_dir="$(find_config_dir)"
  run_chntpw "$config_dir"

  if [[ "$INTERACTIVE" -eq 0 && "$WRITE_BLUEZ_INFO" -eq 1 ]]; then
    write_key_to_bluez_info
    restart_bluetooth_service
  fi
}

main "$@"
