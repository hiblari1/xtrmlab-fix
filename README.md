# zxw-keyboard-fix

Fix for **ZXWMicroChip / Zifriend keyboards** that enumerate but never work on
Linux — the `5566:0008` family (ZA63, ZA68, and the SAMA / Gamestop / Cyberlinx
rebrands).

## The symptom

The keyboard shows up in the boot menu and on Windows, but Linux gives you:

```
usb 1-6: new full-speed USB device number 5 using xhci_hcd
usb 1-6: device descriptor read/64, error -71
usb 1-6: New USB device found, idVendor=5566, idProduct=0008
usb 1-6: unable to read config index 0 descriptor/start: -71
usb 1-6: can't read configurations, error -71
usb usb1-port6: attempt power cycle
usb usb1-port6: unable to enumerate USB device
```

`-71` is `-EPROTO`. `lsusb` may catch a glimpse of `5566:0008` and then lose it.

## Why it happens

The device descriptor reads fine. The **configuration** descriptor does not.
Linux reads it in two steps: first a 9-byte header to learn the total length,
then the full descriptor. Windows asks for 255 bytes in one request. This
firmware chokes on the 9-byte read and returns a protocol error.

It is a firmware bug, not a missing driver. No HID driver is ever involved, so
`usbhid.quirks` does nothing here — the failure happens before interfaces are
probed.

## The fix

The USB core has a per-device quirk interface. These boards need:

| flag | quirk | why |
|---|---|---|
| `g` | `USB_QUIRK_DELAY_INIT` | waits 2s after port reset for the MCU to boot |
| `k` | `USB_QUIRK_NO_LPM` | disables USB 2.0 link power management |
| `i` | `USB_QUIRK_DEVICE_QUALIFIER` | skips the device qualifier request |

```
usbcore.quirks=5566:0008:gki
```

`g` is the load-bearing one — the keyboard's firmware reboots on every port
reset, and Linux's fast retry loop keeps catching it mid-boot. `gki` is what the
community fix uses, and it works.

## Usage

```bash
git clone https://github.com/<you>/zxw-keyboard-fix
cd zxw-keyboard-fix
sudo ./zxw-keyboard-fix.sh
```

Then replug the keyboard (or reboot). To check without changing anything:

```bash
./zxw-keyboard-fix.sh --check
```

To undo:

```bash
sudo ./zxw-keyboard-fix.sh --uninstall
```

## What the script changes

- `/sys/module/usbcore/parameters/quirks` — applies the quirk immediately, no
  replug needed for the next enumeration
- `/etc/udev/rules.d/99-zxw-keyboard.rules` — pins `power/control=on` so the
  device is never runtime-suspended
- `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub` + `grub-mkconfig` — the
  persistent path on GRUB systems
- `/boot/loader/entries/*.conf` — the persistent path on systemd-boot / BLS
- `/etc/kernel/cmdline` — the persistent path for UKI / `kernel-install` setups

It is idempotent: running it twice does not duplicate anything.

## Which bootloader

The script patches whatever it finds rather than trying to guess. On most
systems only one of those paths exists, and the others are skipped silently.

| distro / setup | path used |
|---|---|
| Arch, Debian, Ubuntu, openSUSE (GRUB) | `/etc/default/grub` |
| Arch (systemd-boot) | `/boot/loader/entries/*.conf` |
| Fedora (BLS) | `/boot/loader/entries/*.conf` + `/etc/kernel/cmdline` |
| UKI setups | `/etc/kernel/cmdline` (rebuild the image yourself) |

If your bootloader isn't covered, add `usbcore.quirks=5566:0008:gki` to the
kernel command line by hand.

## Other flags

- `r` — `USB_QUIRK_WINDOWS_CONFIG_REQ_SIZE`, reads the config descriptor with a
  255-byte request exactly like Windows does. Requires kernel **7.2+** (absent
  in 7.1). This is a direct hit on the failing code path, and a good fallback
  if `gki` alone isn't enough: `--flags r` or `--flags gkir`.

The letter-flag syntax itself is not new — it is present at least as far back
as 4.19, so `gki` works on anything you're likely to install.
- `b` — `USB_QUIRK_RESET_RESUME`, only if the board survives enumeration but
  breaks across suspend/resume.

## Tested

- Arch Linux, kernel `7.2.11-arch1-1`, device `5566:0008` (ZXW-KEYBOARD)

## Known remaining issue

On the board tested here, wired mode can still hang after ~5 minutes of idle:
the firmware stops answering its interrupt endpoint, `usbhid` queues a reset,
and the board does not survive it. It then needs a **physical unplug** — a warm
reboot does not cut USB VBUS, so the hung MCU keeps its state across reboots.

That is a firmware problem, not a kernel one. This script makes the keyboard
enumerate and work; it cannot stop the firmware from falling over later. Try a
different cable/port first, then the vendor's sleep-disable key combo or a
firmware update.

## License

MIT
