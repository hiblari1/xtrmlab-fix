#!/usr/bin/env bash
#
# zxw-keyboard-fix.sh
#
# Makes ZXWMicroChip / Zifriend keyboards (USB 5566:0008) work on Linux.
#
# These boards enumerate but fail to read their configuration descriptor:
#
#   usb 1-6: New USB device found, idVendor=5566, idProduct=0008
#   usb 1-6: unable to read config index 0 descriptor/start: -71
#   usb 1-6: can't read configurations, error -71
#
# -71 is -EPROTO. The firmware mishandles the 9-byte "how big is your config
# descriptor" request that Linux sends before the full read. Windows asks for
# 255 bytes in one go and never trips it.
#
# The fix is the USB core quirk set DELAY_INIT | NO_LPM | DEVICE_QUALIFIER
# ("gki"), applied via the usbcore.quirks kernel parameter, plus an udev rule
# that keeps the device out of runtime autosuspend.
#
# Usage:  sudo ./zxw-keyboard-fix.sh [options]
#         ./zxw-keyboard-fix.sh --check
#
# License: MIT
#
set -euo pipefail

PROG=${0##*/}

VID=5566
PID=0008
FLAGS=gki
MODE=install

RULE=/etc/udev/rules.d/99-zxw-keyboard.rules
GRUB_LOG=/tmp/zxw-keyboard-fix-grub.log

die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
log()  { printf '  %s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*" >&2; }

usage() {
	cat <<'EOF'
Fix ZXWMicroChip / Zifriend keyboards (5566:0008) on Linux.

Options:
  -u, --uninstall     remove the quirk, the udev rule and the cmdline entry
  -c, --check         print the current state, change nothing
      --vid VID       override vendor id  (default 5566)
      --pid PID       override product id (default 0008)
      --flags FLAGS   override quirk flags (default gki)
  -h, --help          this text

What it changes:
  * /sys/module/usbcore/parameters/quirks      runtime, until next unplug
  * /etc/udev/rules.d/99-zxw-keyboard.rules    power/control=on
  * GRUB_CMDLINE_LINUX_DEFAULT + grub.cfg      persistent
  * /boot/loader/entries/*.conf                persistent (systemd-boot/BLS)
  * /etc/kernel/cmdline                        persistent (UKI / kernel-install)

Why "gki":
  g = USB_QUIRK_DELAY_INIT        wait for the keyboard's MCU to boot
  k = USB_QUIRK_NO_LPM            no USB 2.0 link power management
  i = USB_QUIRK_DEVICE_QUALIFIER  skip the device qualifier request

The letters are parsed by the kernel since long before 5.15. "r"
(USB_QUIRK_WINDOWS_CONFIG_REQ_SIZE) needs 7.2+ and is an alternative if
"gki" alone does not enumerate the board.
EOF
}

# Parsed state ------------------------------------------------------------

QUIRK=
PARAM=
PARAM_RE=

set_names() {
	QUIRK="${VID}:${PID}:${FLAGS}"
	PARAM="usbcore.quirks=${QUIRK}"
	PARAM_RE=${PARAM//./\\.}
}

# Helpers -----------------------------------------------------------------

need_root() {
	[[ $EUID -eq 0 ]] && return 0
	command -v sudo >/dev/null 2>&1 || die "run this as root"
	local self
	self=$(readlink -f "$0")
	exec sudo -- "$self" "$@"
}

write_runtime() {
	local f=/sys/module/usbcore/parameters/quirks
	[[ -e $f ]] || { warn "usbcore quirks parameter not found"; return 1; }
	[[ -w $f ]] || { warn "cannot write $f"; return 1; }

	local cur new
	cur=$(<"$f")
	if [[ $cur == *"$QUIRK"* ]]; then
		ok "runtime quirk already set"
		return 0
	fi
	new=$cur
	[[ -n $new ]] && new+=,
	new+=$QUIRK
	printf '%s' "$new" > "$f"
	ok "runtime quirk set to $new"
}

clear_runtime() {
	local f=/sys/module/usbcore/parameters/quirks
	[[ -w $f ]] || return 0
	local cur
	cur=$(<"$f")
	[[ -z $cur ]] && return 0

	local -a parts
	local e out=
	IFS=',' read -ra parts <<< "$cur"
	for e in "${parts[@]}"; do
		[[ $e == "$QUIRK" ]] && continue
		out+="${out:+,}$e"
	done
	printf '%s' "$out" > "$f"
}

write_udev() {
	local line
	mkdir -p "${RULE%/*}"
	line="ACTION==\"add\", SUBSYSTEM==\"usb\", ATTR{idVendor}==\"${VID}\", ATTR{idProduct}==\"${PID}\", ATTR{power/control}=\"on\""
	printf '%s\n' "$line" > "$RULE"
	ok "udev rule written to $RULE"

	if command -v udevadm >/dev/null 2>&1; then
		udevadm control --reload-rules 2>/dev/null || true
		udevadm trigger --subsystem-match=usb --attr-match="idVendor=${VID}" 2>/dev/null || true
		ok "udev rules reloaded"
	else
		warn "udevadm not found; rule will apply on next boot"
	fi
}

remove_udev() {
	[[ -f $RULE ]] || return 0
	rm -f "$RULE"
	ok "removed $RULE"
	if command -v udevadm >/dev/null 2>&1; then
		udevadm control --reload-rules 2>/dev/null || true
	fi
}

grub_edit() {
	local f=/etc/default/grub
	[[ -f $f ]] || return 1

	if grep -qF "$PARAM" "$f"; then
		ok "grub: already present"
	else
		if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f"; then
			sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $PARAM\"|" "$f"
		else
			printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$PARAM" >> "$f"
		fi
		if grep -qF "$PARAM" "$f"; then
			ok "grub: added to GRUB_CMDLINE_LINUX_DEFAULT"
		else
			warn "grub: could not edit $f, add '$PARAM' by hand"
			return 0
		fi
	fi
	grub_regen
}

grub_regen() {
	local out= cmd=
	[[ -f /boot/grub2/grub.cfg ]] && out=/boot/grub2/grub.cfg
	[[ -z $out && -f /boot/grub/grub.cfg ]] && out=/boot/grub/grub.cfg
	[[ -z $out ]] && return 0

	if command -v grub-mkconfig >/dev/null 2>&1; then
		cmd=grub-mkconfig
	elif command -v grub2-mkconfig >/dev/null 2>&1; then
		cmd=grub2-mkconfig
	else
		warn "grub: $cmd not found, run grub-mkconfig -o $out yourself"
		return 0
	fi

	if "$cmd" -o "$out" >"$GRUB_LOG" 2>&1; then
		if grep -qF "$PARAM" "$out"; then
			ok "grub: regenerated $out"
		else
			warn "grub: $out has no '$PARAM', check $GRUB_LOG"
		fi
	else
		warn "grub: '$cmd -o $out' failed, see $GRUB_LOG"
	fi
}

grub_undo() {
	local f=/etc/default/grub
	[[ -f $f ]] || return 0
	grep -qF "$PARAM" "$f" || return 0
	sed -i "s| $PARAM_RE||g" "$f"
	ok "grub: removed from $f"
	grub_regen
}

bls_edit() {
	local dir=/boot/loader/entries
	[[ -d $dir ]] || return 1

	local f n=0
	shopt -s nullglob
	for f in "$dir"/*.conf; do
		grep -qF "$PARAM" "$f" && continue
		if grep -q '^options ' "$f"; then
			sed -i "s|^options \(.*\)\$|options \1 $PARAM|" "$f"
		else
			printf 'options %s\n' "$PARAM" >> "$f"
		fi
		n=$((n + 1))
	done
	shopt -u nullglob

	[[ $n -eq 0 ]] && ok "systemd-boot: already present" || ok "systemd-boot: patched $n entries"
}

bls_undo() {
	local dir=/boot/loader/entries
	[[ -d $dir ]] || return 0

	local f n=0
	shopt -s nullglob
	for f in "$dir"/*.conf; do
		grep -qF "$PARAM" "$f" || continue
		sed -i "s| $PARAM_RE||g" "$f"
		n=$((n + 1))
	done
	shopt -u nullglob

	[[ $n -eq 0 ]] && return 0
	ok "systemd-boot: cleaned $n entries"
}

kernel_cmdline_edit() {
	local f=/etc/kernel/cmdline
	[[ -f $f ]] || return 1
	if grep -qF "$PARAM" "$f"; then
		ok "kernel/cmdline: already present"
		return 0
	fi
	local cur
	cur=$(<"$f")
	printf '%s %s\n' "$cur" "$PARAM" > "$f"
	ok "kernel/cmdline: appended (rebuild your UKI to apply)"
}

kernel_cmdline_undo() {
	local f=/etc/kernel/cmdline
	[[ -f $f ]] || return 0
	grep -qF "$PARAM" "$f" || return 0
	sed -i "s| $PARAM_RE||g" "$f"
	ok "kernel/cmdline: cleaned"
}

report_device() {
	local d found=0 vid pid
	for d in /sys/bus/usb/devices/*; do
		[[ -f $d/idVendor ]] || continue
		vid=$(<"$d/idVendor")
		pid=$(<"$d/idProduct")
		[[ $vid == "$VID" && $pid == "$PID" ]] || continue
		found=1
		ok "$(basename "$d") attached, power/control=$(<"$d/power/control")"
	done
	[[ $found -eq 1 ]] || log "keyboard not attached right now"
}

check_state() {
	echo "device:  ${VID}:${PID}"
	echo "param:   ${PARAM}"
	echo

	echo "boot cmdline:"
	if grep -qF "$PARAM" /proc/cmdline; then
		echo "  present"
	else
		echo "  missing (persisted but not booted yet, or not installed)"
	fi

	echo "runtime:"
	local f=/sys/module/usbcore/parameters/quirks
	if [[ -r $f ]]; then
		echo "  $(<"$f")"
	else
		echo "  parameter not readable"
	fi

	echo "udev:"
	[[ -f $RULE ]] && echo "  rule installed" || echo "  rule missing"

	echo "device:"
	report_device
}

# Actions -----------------------------------------------------------------

do_install() {
	echo "zxw-keyboard-fix: ${VID}:${PID} flags=${FLAGS}"
	echo
	write_runtime || true
	write_udev
	kernel_cmdline_edit || true
	bls_edit || true
	grub_edit || true
	echo
	report_device
	echo
	echo "Replug the keyboard, or reboot, for the cmdline change to apply."
	echo "Then verify with:  grep -o '$PARAM' /proc/cmdline"
}

do_uninstall() {
	echo "zxw-keyboard-fix: removing ${VID}:${PID} flags=${FLAGS}"
	echo
	grub_undo || true
	bls_undo || true
	kernel_cmdline_undo || true
	remove_udev
	clear_runtime || true
	echo
	echo "Reboot to drop the kernel parameter."
}

main() {
	local -a orig=("$@")

	while [[ $# -gt 0 ]]; do
		case $1 in
			-u|--uninstall) MODE=uninstall ;;
			-c|--check)     MODE=check ;;
			-h|--help)      usage; exit 0 ;;
			--vid)          VID=${2:?"--vid needs a value"}; shift ;;
			--pid)          PID=${2:?"--pid needs a value"}; shift ;;
			--flags)        FLAGS=${2:?"--flags needs a value"}; shift ;;
			*)              die "unknown argument: $1 (try --help)" ;;
		esac
		shift
	done

	set_names

	if [[ $MODE != check ]]; then
		need_root "${orig[@]}"
	fi

	case $MODE in
		install)   do_install ;;
		uninstall) do_uninstall ;;
		check)     check_state ;;
	esac
}

main "$@"
