#!/usr/bin/env bash
# The network configuration a fresh Arch install needs before Kallos is usable
# on a network you did not set up yourself — and the one place it is written
# down.
#
# Kallos speaks **iwd** for Wi-Fi (`net.connman.iwd`, see kallosd/src/sys/wifi.rs
# and the note in scripts/deps.sh), but iwd only associates. Addressing and name
# resolution are systemd-networkd and systemd-resolved, and nothing in this tree
# set either of them up until now. This does.
#
# **Optional, and never run by `./kallos up`.** Like scripts/boot.sh it edits
# /etc, so it is a thing you run deliberately, once, on a machine you want to
# behave like ours. It is safe inside `arch-chroot /mnt`: unit enablement still
# works there, and everything that needs a running systemd is skipped.
#
# What it changes, and why:
#
#   networkd/resolved/iwd enabled   iwd associates; networkd gets the lease;
#                           resolved answers. All three or none.
#   20-{ethernet,wlan,wwan}.network   DHCP for en*/wl*/ww*, with the route
#                           metrics 100/600/700 so ethernet beats Wi-Fi beats
#                           WWAN. **Only written when /etc/systemd/network has
#                           no .network file at all** — Arch ships none (nothing
#                           under /usr/lib/systemd/network matches a normal
#                           interface), so enabling networkd without these
#                           leaves the machine with no DHCP whatsoever.
#   /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf
#                           Arch's `filesystem` package ships a REAL FILE here,
#                           and that permanently defeats systemd's own tmpfiles
#                           rule: `L` refuses to replace an existing file, and
#                           the pacman hook runs tmpfiles without --boot, so the
#                           line never fires. resolved then sits in `foreign`
#                           mode and its own stub is never consulted.
#   /etc/tmpfiles.d/systemd-resolve.conf   The same link as an `L+` rule, which
#                           DOES replace an existing file. So if a package ever
#                           puts the real file back, the symlink heals itself
#                           at the next boot instead of silently breaking DNS.
#   10-captive-portal.conf  FallbackDNS= (empty), DNSOverTLS=no, DNSSEC=no.
#                           Captive portals black-hole traffic to public
#                           resolvers, so with the compiled-in fallback list
#                           every lookup spends minutes cycling UDP+EDNS0 ->
#                           UDP -> TCP against 9.9.9.9/1.1.1.1/8.8.8.8 and the
#                           login page never loads. Empty means: use the
#                           DHCP-provided server, or fail fast. Never hang.
#
# Two things it deliberately does NOT do:
#
#   * touch an existing .network file, or an existing resolved drop-in that this
#     script did not write. Both are somebody's configuration.
#   * run anywhere near NetworkManager or dhcpcd. If either is enabled it bails:
#     this script knows one stack, and half of two stacks is a dead machine.
#
# Usage: scripts/net.sh [check|apply|revert]   (default: check)
#   YES=1     don't prompt
#   ETC=<dir> operate on a fixture instead of /etc (unit actions are then only
#             reported, never run)
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-check}"
case "$mode" in
	check|apply|revert) ;;
	*) echo "!! usage: scripts/net.sh [check|apply|revert]" >&2; exit 2 ;;
esac

etc="${ETC:-/etc}"
bak=".bak-kallos"
mark="# Written by kallos: scripts/net.sh"
say() { printf '   %s\n' "$*"; }
act() { printf '>> %s\n' "$*"; }

# A fixture is not the machine: never sudo into it, and never let unit
# enablement escape into the real system while pointed at one.
system=0; [ "$etc" = /etc ] && system=1
# A running systemd manager we can restart things through. Absent in a chroot,
# where `systemctl enable` still works (it only writes symlinks) but nothing
# else does.
live=0; [ "$system" = 1 ] && [ -d /run/systemd/system ] && live=1

netdir="$etc/systemd/network"
resolv="$etc/resolv.conf"
dropin="$etc/systemd/resolved.conf.d/10-captive-portal.conf"
tmpfile="$etc/tmpfiles.d/systemd-resolve.conf"
stub=../run/systemd/resolve/stub-resolv.conf
units=(systemd-networkd systemd-resolved iwd)

# ---- privilege ------------------------------------------------------------
# Only the writes are privileged, and only when they land in the real /etc.
run() {
	if [ "$system" = 0 ] || [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}
# Write stdin to $1, creating its directory. Files are 0644, dirs 0755.
write() {
	run install -d -m0755 "$(dirname "$1")"
	run tee "$1" >/dev/null
	run chmod 0644 "$1"
}
# Did WE write this file? Only then may revert remove it.
ours() { [ -f "$1" ] && head -1 "$1" | grep -qF "$mark"; }

# ---- the file bodies ------------------------------------------------------
# Transcribed from the Arch wiki's three examples, comments and all. The route
# metrics are NetworkManager's own defaults (nm_device_get_route_metric_default),
# which is why ethernet/Wi-Fi/WWAN come out in that order.

net_body() {  # $1 = ethernet|wlan|wwan
	echo "$mark"
	case "$1" in
		ethernet) cat <<'EOF'
[Match]
# Matching with "Type=ether" causes issues with containers because it also matches virtual Ethernet interfaces (veth*).
# See https://bugs.archlinux.org/task/70892
# Instead match by globbing the network interface name.
Name=en*
Name=eth*

[Link]
RequiredForOnline=routable

[Network]
DHCP=yes
MulticastDNS=yes

# systemd-networkd does not set per-interface-type default route metrics
# https://github.com/systemd/systemd/issues/17698
# Explicitly set route metric, so that Ethernet is preferred over Wi-Fi and Wi-Fi is preferred over mobile broadband.
[DHCPv4]
RouteMetric=100

[IPv6AcceptRA]
RouteMetric=100
EOF
		;;
		wlan) cat <<'EOF'
[Match]
Name=wl*

[Link]
RequiredForOnline=routable

[Network]
DHCP=yes
MulticastDNS=yes

# See 20-ethernet.network for why these metrics are here. Wi-Fi sits between
# ethernet (100) and mobile broadband (700).
[DHCPv4]
RouteMetric=600

[IPv6AcceptRA]
RouteMetric=600
EOF
		;;
		wwan) cat <<'EOF'
[Match]
Name=ww*

[Link]
RequiredForOnline=routable

[Network]
DHCP=yes

# See 20-ethernet.network. Mobile broadband is the last resort.
[DHCPv4]
RouteMetric=700

[IPv6AcceptRA]
RouteMetric=700
EOF
		;;
	esac
}

dropin_body() {
	echo "$mark"
	cat <<'EOF'
# Make name resolution behave sanely behind captive portals.
[Resolve]
# Captive portals silently BLACK-HOLE traffic to public resolvers. With the
# compiled-in fallback list, resolved spends minutes cycling UDP+EDNS0 -> UDP ->
# TCP against 9.9.9.9/1.1.1.1/8.8.8.8 and every lookup just hangs. Empty means:
# use the DHCP-provided server, or fail fast with SERVFAIL. Never hang.
FallbackDNS=

# Pin these off. Both are currently the default, but if a future systemd flips
# DNSOverTLS to opportunistic, portal login breaks again in the same silent way.
DNSOverTLS=no
DNSSEC=no
EOF
}

tmpfile_body() {
	echo "$mark"
	cat <<'EOF'
# systemd ships this same line as `L!`, which never fires: `L` refuses to
# replace an existing file, Arch's `filesystem` package ships /etc/resolv.conf
# as a real one, and the pacman hook runs tmpfiles without --boot so the `!`
# line is skipped anyway. `L+` replaces. The symlink then heals itself if a
# package ever puts the real file back.
L+ /etc/resolv.conf - - - - ../run/systemd/resolve/stub-resolv.conf
EOF
}

# ---- preflight ------------------------------------------------------------

if [ "$system" = 1 ] && command -v systemctl >/dev/null; then
	for u in NetworkManager dhcpcd; do
		if systemctl is-enabled --quiet "$u" 2>/dev/null; then
			echo "!! $u is enabled — this script only knows iwd + systemd-networkd" >&2
			echo "   + systemd-resolved, and running both stacks is worse than either." >&2
			echo "   Disable it first, or apply the settings by hand: they are all" >&2
			echo "   listed at the top of this file." >&2
			exit 1
		fi
	done
fi
[ "$system" = 1 ] || say "note: ETC=$etc — a fixture; unit actions are reported, not run"

# ---- revert ---------------------------------------------------------------

if [ "$mode" = revert ]; then
	n=0 removed_net=0
	# The symlink first: a backup beside it is the real file we displaced, and
	# cp -a over a live symlink would write straight through it into /run.
	if [ -e "$resolv$bak" ]; then
		act "restoring $resolv"
		run rm -f "$resolv"
		run cp -a "$resolv$bak" "$resolv"
		run rm -f "$resolv$bak"
		n=$((n + 1))
	elif [ -L "$resolv" ]; then
		say "$resolv: no backup — we created this symlink from nothing, leaving it"
		say "  (removing it would leave the machine with no resolver at all)"
	fi
	for f in "$netdir"/20-ethernet.network "$netdir"/20-wlan.network \
	         "$netdir"/20-wwan.network "$dropin" "$tmpfile"; do
		if [ -e "$f$bak" ]; then
			act "restoring $f"
			run cp -a "$f$bak" "$f"; run rm -f "$f$bak"
			n=$((n + 1))
		elif ours "$f"; then
			act "removing $f"
			run rm -f "$f"
			case "$f" in *.network) removed_net=1 ;; esac
			n=$((n + 1))
		elif [ -e "$f" ]; then
			say "leaving $f — not ours (no marker line)"
		fi
	done
	[ "$n" -gt 0 ] || { say "nothing to revert"; exit 0; }
	# Directories we may have created on the way in. Never forced: one that
	# still holds somebody else's drop-in stays.
	for d in "$etc/systemd/resolved.conf.d" "$etc/tmpfiles.d"; do
		[ -d "$d" ] && run rmdir --ignore-fail-on-non-empty "$d" || true
	done
	if [ "$live" = 1 ]; then
		act "restarting systemd-resolved"
		run systemctl restart systemd-resolved || true
	fi
	if [ "$removed_net" = 1 ] && [ "$system" = 1 ] &&
	   systemctl is-enabled --quiet systemd-networkd 2>/dev/null &&
	   ! compgen -G "$netdir/*.network" >/dev/null; then
		echo
		say "WARNING: $netdir is now empty and systemd-networkd is still enabled,"
		say "  so nothing will request a DHCP lease. That was the state before"
		say "  apply; if it is not what you want:"
		say "    sudo systemctl disable --now systemd-networkd"
	fi
	echo
	act "reverted $n item(s)"
	say "services are left enabled — this script cannot know which ones it turned on"
	exit 0
fi

# ---- report ---------------------------------------------------------------

todo=0
todo_units=() todo_net=0 todo_resolv=0 todo_tmpfile=0 todo_dropin=0

echo "== services =="
if ! command -v systemctl >/dev/null; then
	say "SKIP  no systemctl — not a systemd machine; nothing below applies"
	exit 1
fi
for u in "${units[@]}"; do
	if [ "$system" = 0 ]; then
		say "SKIP  $u (fixture)"
	elif systemctl is-enabled --quiet "$u" 2>/dev/null; then
		say "OK    $u enabled"
	elif [ "$(systemctl is-enabled "$u" 2>&1 || true)" = not-found ]; then
		say "MISS  $u is not installed  -> scripts/deps.sh install"
	else
		say "TODO  enable $u"
		todo_units+=("$u"); todo=1
	fi
done

echo "== addressing =="
if compgen -G "$netdir/*.network" >/dev/null; then
	say "OK    $(compgen -G "$netdir/*.network" | wc -l) .network file(s) in $netdir — left alone"
else
	say "TODO  no .network files in $netdir — networkd would hand out no leases"
	say "      writing 20-{ethernet,wlan,wwan}.network (DHCP for en*/wl*/ww*)"
	todo_net=1; todo=1
fi

echo "== resolv.conf =="
if [ -L "$resolv" ]; then
	say "OK    symlink -> $(readlink "$resolv")"
elif [ -e "$resolv" ]; then
	say "TODO  is a $(stat -c '%F' "$resolv"), not a symlink — resolved stays in"
	say "      'foreign' mode and its stub is never consulted"
	todo_resolv=1; todo=1
else
	say "TODO  missing — link it to the resolved stub"
	todo_resolv=1; todo=1
fi
if [ -e "$tmpfile" ]; then
	say "OK    $tmpfile (the symlink heals itself)"
else
	say "TODO  add $tmpfile — an L+ rule, so a package cannot undo the symlink"
	todo_tmpfile=1; todo=1
fi

echo "== resolver =="
if [ -e "$dropin" ]; then
	say "OK    $(basename "$dropin") present"
else
	say "TODO  add $(basename "$dropin") — FallbackDNS= so portals never hang"
	todo_dropin=1; todo=1
fi

if [ "$live" = 1 ] && command -v resolvectl >/dev/null; then
	echo "== live state =="
	rmode=$(resolvectl status 2>/dev/null | sed -n 's/^ *resolv.conf mode: *//p' | head -1)
	[ "$rmode" = stub ] && say "OK    resolved reports mode 'stub'" \
	                    || say "TODO  resolved reports mode '${rmode:-unknown}' (want 'stub')"
	if resolvectl status 2>/dev/null | grep -q 'Fallback DNS Servers'; then
		say "TODO  fallback servers still configured — lookups will hang behind a portal"
	else
		say "OK    no fallback servers configured"
	fi
	resolvectl dns 2>/dev/null | sed 's/^/   per-link: /' || true
fi

if [ "$mode" = check ]; then
	echo
	[ "$todo" = 0 ] && act "nothing to do" || act "run: scripts/net.sh apply"
	exit 0
fi

# ---- apply ----------------------------------------------------------------

[ "$todo" = 0 ] && { echo; act "already applied; nothing to do"; exit 0; }

if [ -z "${YES:-}" ]; then
	echo
	echo "   This edits $etc: unit enablement, DHCP config, and the resolver."
	echo "   scripts/net.sh revert puts it back."
	read -r -p "   Apply? [y/N] " a
	case "$a" in y|Y|yes|YES) ;; *) echo ">> aborted"; exit 1 ;; esac
fi

echo
for u in ${todo_units[@]+"${todo_units[@]}"}; do
	act "enabling $u"
	run systemctl enable "$u"
	[ "$live" = 1 ] && run systemctl start "$u" || true
done

if [ "$todo_net" = 1 ]; then
	for n in ethernet wlan wwan; do
		act "$netdir/20-$n.network"
		net_body "$n" | write "$netdir/20-$n.network"
	done
	[ "$live" = 1 ] && run systemctl restart systemd-networkd || true
fi

if [ "$todo_resolv" = 1 ]; then
	if [ -e "$resolv" ] && [ ! -L "$resolv" ]; then
		[ -e "$resolv$bak" ] || run cp -a "$resolv" "$resolv$bak"
		act "backed up the static $resolv"
	fi
	# Relative target: correct both in a chroot and on the booted system.
	act "$resolv -> $stub"
	run ln -sfn "$stub" "$resolv"
fi

if [ "$todo_tmpfile" = 1 ]; then
	act "$tmpfile"
	tmpfile_body | write "$tmpfile"
fi

if [ "$todo_dropin" = 1 ]; then
	act "$dropin"
	dropin_body | write "$dropin"
fi

if [ "$live" = 1 ]; then
	act "restarting systemd-resolved"
	run systemctl restart systemd-resolved
	sleep 1
	rmode=$(resolvectl status 2>/dev/null | sed -n 's/^ *resolv.conf mode: *//p' | head -1)
	[ "$rmode" = stub ] && say "resolv.conf mode: stub" \
	                    || say "resolv.conf mode: ${rmode:-unknown} — expected 'stub'; check the drop-in"
fi

echo
act "applied"
say "originals kept alongside as *$bak; scripts/net.sh revert puts them back"
