#!/usr/bin/env bash
#
# resource_check.sh - what the OrbStack VM was given, and how much of it this
# project is actually using.
#
# Usage:
#   ./docs/resource_check.sh              # defaults to the 'platform' cluster
#   ./docs/resource_check.sh mycluster    # or name one
#   NO_COLOR=1 ./docs/resource_check.sh   # plain output
#
# Colour is disabled automatically when stdout is not a terminal, so piping to
# a file or a pager gives clean text.
#
# See docs/resource_check.md for the individual commands this rolls up, and for
# the gotchas (sparse disk images, the zsh word-splitting trap).

set -uo pipefail

CLUSTER="${1:-platform}"
ORB_DATA="$HOME/Library/Group Containers/HUAQ24HBR6.dev.orbstack"

# ---------------------------------------------------------------------------
# Colour. Off when piped, off when NO_COLOR is set (https://no-color.org).
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
  CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'
else
  BOLD=''; DIM=''; RESET=''; CYAN=''; GREEN=''; YELLOW=''; RED=''
fi

# ---------------------------------------------------------------------------
# Preflight. Every number below is wrong if the tooling is pointed at Docker
# Desktop instead of OrbStack, and that failure is silent, so check first.
# ---------------------------------------------------------------------------
daemon=$(docker info --format '{{.Name}}' 2>/dev/null)
if [ -z "$daemon" ]; then
  printf '%sCannot reach a Docker daemon.%s Is OrbStack running?\n' "$RED" "$RESET" >&2
  exit 1
fi
if [ "$daemon" != "orbstack" ]; then
  printf '%sWarning:%s docker daemon is %s%s%s, not orbstack.\n' \
    "$YELLOW" "$RESET" "$BOLD" "$daemon" "$RESET" >&2
  printf '  Run %sdocker context use orbstack%s first, or these numbers describe the wrong VM.\n\n' \
    "$DIM" "$RESET" >&2
fi

ids=$(docker ps -q --filter "name=k3d-$CLUSTER")
if [ -z "$ids" ]; then
  printf '%sk3d-%s has no running containers.%s Start it with %sgmake resume%s.\n' \
    "$YELLOW" "$CLUSTER" "$RESET" "$BOLD" "$RESET"
  exit 0
fi

# ---------------------------------------------------------------------------
# Gather. Each of these is one of the individual commands from the md doc.
# ---------------------------------------------------------------------------
ncpu=$(docker info --format '{{.NCPU}}')
mem=$(docker info --format '{{.MemTotal}}')
disk=$(docker exec "k3d-$CLUSTER-server-0" df -B1 / | tail -1)
rss=$(ps ax -o rss=,comm= | grep "OrbStack Helper" | awk '{print $1}')

# du, not ls: the VM image is sparse, so ls -lh reports ~460G apparent.
hostdisk=$(du -sk "$ORB_DATA" 2>/dev/null | cut -f1)
hostmem=$(sysctl -n hw.memsize)

# The volume the OrbStack data actually sits on, which on APFS is the data
# volume, not /. Fields: total, used, avail (all in KiB).
hostvol=$(df -k "$ORB_DATA" | tail -1)

# ---------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------
echo "$ids" \
| xargs docker stats --no-stream --format '{{.CPUPerc}}|{{.MemPerc}}' \
| awk -F'|' \
    -v ncpu="$ncpu" -v mem="$mem" -v disk="$disk" -v rss="$rss" \
    -v hd="$hostdisk" -v hostmem="$hostmem" -v hostvol="$hostvol" \
    -v cluster="$CLUSTER" \
    -v B="$BOLD" -v D="$DIM" -v R="$RESET" -v C="$CYAN" \
    -v G="$GREEN" -v Y="$YELLOW" -v E="$RED" '
  # green under 60%, amber to 85%, red above. Same scale everywhere so the
  # colour means the same thing in every row.
  function hue(p) { return (p >= 85) ? E : (p >= 60) ? Y : G }
  function row(label, total, used, pct) {
    printf "%s%-8s%s %14s %16s   %s%7.1f%%%s\n", C, label, R, total, used, hue(pct), pct, R
  }
  function gib(bytes) { return sprintf("%.2f GiB", bytes/1073741824) }

  { gsub(/%/, ""); c += $1; m += $2 }

  END {
    split(disk,    d, /[ \t]+/); dtot = d[2];  dused = d[3]
    split(hostvol, h, /[ \t]+/); htot = h[2];  hused = h[3];  hfree = h[4]   # KiB
    k = 1048576   # KiB per GiB

    dpct = dused / dtot * 100
    printf "\n%sOrbStack VM%s  %sallocated vs in use, cluster k3d-%s%s\n\n", B, R, D, cluster, R
    printf "%s%-8s %14s %16s %10s%s\n", D, "", "ALLOCATED", "IN USE", "USED", R
    row("CPU",    ncpu " cores", sprintf("%.2f cores", c/100),  c/ncpu)
    row("Memory", gib(mem),      gib(m/100*mem),                m)
    row("Disk",   gib(dtot),     gib(dused),                    dpct)

    rpct = rss/1024 / (hostmem/1048576) * 100
    hpct = hd / htot * 100
    printf "\n%sCost to macOS%s  %swhat OrbStack takes from the host%s\n\n", B, R, D, R
    printf "%s%-8s %14s %16s %10s%s\n", D, "", "HOST TOTAL", "ORBSTACK", "SHARE", R
    row("RAM",  gib(hostmem), sprintf("%.2f GiB", rss/k),  rpct)
    row("Disk", gib(htot*1024), sprintf("%.2f GiB", hd/k), hpct)

    # Headroom matters more than the OrbStack share: a nearly full disk is what
    # actually stops the VM growing, and its image grows on demand.
    #
    # Use the same arithmetic df uses, used/(used+avail), NOT used/total. On
    # APFS the three do not reconcile, because total includes purgeable and
    # reserved space you cannot actually write to. Dividing by total understates
    # how full the disk is and overstates free space by tens of GiB.
    #
    # NB: no apostrophes anywhere in this awk program. It is wrapped in single
    # quotes by the shell, so one straight quote ends the script.
    hostpct = hused / (hused + hfree) * 100
    printf "\n%shost volume is %s%.0f%%%s%s full, %.1f GiB actually free%s\n\n", \
      D, hue(hostpct), hostpct, R, D, hfree/k, R
  }'
