# Dual-Boot Bluetooth Fix with `chntpw`

These scripts help fix Bluetooth pairing issues in dual-boot setups by reading pairing keys from Windows and updating Linux BlueZ device info.

## ⚠️ IMPORTANT WARNING (READ FIRST)

> **MAKE SURE THE BLUETOOTH DEVICE HAS BEEN PAIRED AT LEAST ONCE IN BOTH WINDOWS AND LINUX BEFORE RUNNING THESE SCRIPTS.**
>
> If the device is not already known on both sides, the required key/device entries may not exist and the fix will fail.


## Files

- `fix_bluetooth.sh`: Main script
- `run_fix_for_paired_devices.sh`: Batch runner for paired/connected/all known devices

## Batch run for multiple devices

Run fix for paired Bluetooth devices (default):

```bash
./run_fix_for_paired_devices.sh --mount-dir /media/sahil/Acer
```

Use connected devices only:

```bash
./run_fix_for_paired_devices.sh --mount-dir /media/sahil/Acer --connected-only
```

Run fix for all known devices in BlueZ:

```bash
./run_fix_for_paired_devices.sh --mount-dir /media/sahil/Acer --all-known
```

Pass-through toggles:

```bash
./run_fix_for_paired_devices.sh --mount-dir /media/sahil/Acer --no-write-bluez-info
./run_fix_for_paired_devices.sh --mount-dir /media/sahil/Acer --no-restart-bluetooth
./run_fix_for_paired_devices.sh --mount-dir /media/sahil/Acer --bluez-dir /var/lib/bluetooth
```

## Quick start

```bash
cd /home/sahil/Desktop/re-link-bluetooth
chmod +x ./fix_bluetooth.sh
./fix_bluetooth.sh --mount-dir /mnt/c
```

Non-interactive mode (no manual `chntpw` typing):

```bash
./fix_bluetooth.sh \
	--mount-dir /mnt/c \
	--device-mac 001f20eb4c9a
```

Non-interactive mode with explicit adapter key:

```bash
./fix_bluetooth.sh \
	--mount-dir /mnt/c \
	--adapter-mac aa1122334455 \
	--device-mac 001f20eb4c9a
```

Non-interactive mode (default: extract + write `info` + restart bluetooth):

```bash
./fix_bluetooth.sh \
	--mount-dir /media/sahil/Acer \
	--device-mac 84:0F:2A:D3:A5:31
```

Interactive mode (manual `chntpw` shell):

```bash
./fix_bluetooth.sh --mount-dir /mnt/c --interactive
```

The script will:

1. Install `chntpw` (unless `--skip-install` is used)
2. Use your already-mounted Windows directory
3. Run `chntpw` commands automatically by default (requires `--device-mac`)
4. Auto-search all adapter keys when `--adapter-mac` is omitted
5. Write key into BlueZ `info` by default
6. Restart Bluetooth service by default
7. Open interactive mode only when `--interactive` is provided

## Common options

```bash
./fix_bluetooth.sh --mount-dir /mnt/c --interactive
./fix_bluetooth.sh --mount-dir /mnt/windows --interactive
./fix_bluetooth.sh --mount-dir /mnt/c --device-mac 001f20eb4c9a
./fix_bluetooth.sh --mount-dir /mnt/c --adapter-mac aa1122334455 --device-mac 001f20eb4c9a
./fix_bluetooth.sh --mount-dir /mnt/c --device-mac 84:0F:2A:D3:A5:31 --no-write-bluez-info
./fix_bluetooth.sh --mount-dir /mnt/c --device-mac 84:0F:2A:D3:A5:31 --no-restart-bluetooth
./fix_bluetooth.sh --mount-dir /mnt/c --device-mac 84:0F:2A:D3:A5:31 --bluez-dir /var/lib/bluetooth
./fix_bluetooth.sh --mount-dir /mnt/c --interactive --skip-install
```

## Notes

- MAC inputs like `84:0F:2A:D3:A5:31` are accepted; the script strips `:` and lowercases automatically.
- By default, the script updates `Key=` in `[LinkKey]` inside `/var/lib/bluetooth/<ADAPTER>/<DEVICE>/info`.
- During write, it searches `/var/lib/bluetooth` for `*/<DEVICE>/info` and updates matching file(s), instead of relying only on adapter path.
- Use `--no-write-bluez-info` to skip file updates.
- By default, the script restarts the `bluetooth` service after updating the file.
- Use `--no-restart-bluetooth` to skip service restart.
- If mounting fails and Windows was hibernated, fully shut down Windows and disable Fast Startup, then try again.
- If `ControlSet001` is missing in `chntpw`, use `CurrentControlSet`.
- On some Windows 7 systems, path segment `services` may be lowercase.

To locate the correct Windows partition and mount it yourself first, you can use:

```bash
sudo lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT,LABEL
sudo mkdir -p /mnt/c
sudo mount -o rw /dev/<NAME> /mnt/c
```
