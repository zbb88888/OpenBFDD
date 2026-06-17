#!/usr/bin/env bash
#
# smoke-multihop.sh - Local loopback smoke test for OpenBFDD multi-hop support.
#
# Brings up two bfdd-beacon instances on loopback alias addresses and has each
# one open an active session to the other. It verifies, by capturing traffic,
# that:
#   * single-hop mode uses UDP port 3784
#   * multi-hop mode (--multihop) uses UDP port 4784
#   * sessions reach the "Up" state in both modes
#
# This is a control-plane smoke test on a single host. It does NOT validate the
# real network path to the Huawei switch; it only proves the daemon's port/TTL
# behaviour is correct.
#
# Linux only (uses `ip addr` and is typically run as root). Requires the built
# bfdd-beacon and bfdd-control binaries, plus tcpdump.
#
set -euo pipefail

# ---- Configuration ---------------------------------------------------------
BEACON="${BEACON:-./bfdd-beacon}"
CONTROL="${CONTROL:-./bfdd-control}"

# Two loopback alias addresses to act as the two "systems".
IP_A="${IP_A:-127.10.0.1}"
IP_B="${IP_B:-127.10.0.2}"

# Control channels (one per beacon instance).
CTRL_A="${CTRL_A:-127.0.0.1:9101}"
CTRL_B="${CTRL_B:-127.0.0.1:9102}"

# Capture interface (loopback).
CAP_IF="${CAP_IF:-lo}"

# How long to wait for the session to come Up, in seconds.
UP_TIMEOUT="${UP_TIMEOUT:-15}"

# ---- Internal state --------------------------------------------------------
WORKDIR="$(mktemp -d)"
ADDED_IP_A=0
ADDED_IP_B=0
PID_A=""
PID_B=""
TCPDUMP_PID=""

log()  { printf '[smoke] %s\n' "$*"; }
fail() { printf '[smoke][FAIL] %s\n' "$*" >&2; exit 1; }

cleanup() {
  set +e
  [ -n "$TCPDUMP_PID" ] && kill "$TCPDUMP_PID" 2>/dev/null
  [ -n "$PID_A" ] && kill "$PID_A" 2>/dev/null
  [ -n "$PID_B" ] && kill "$PID_B" 2>/dev/null
  # Best effort: remove loopback aliases we added.
  [ "$ADDED_IP_A" = "1" ] && ip addr del "${IP_A}/32" dev "$CAP_IF" 2>/dev/null
  [ "$ADDED_IP_B" = "1" ] && ip addr del "${IP_B}/32" dev "$CAP_IF" 2>/dev/null
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

require() {
  command -v "$1" >/dev/null 2>&1 || fail "required tool '$1' not found in PATH"
}

ensure_ip() {
  local ip="$1"
  if ! ip addr show dev "$CAP_IF" | grep -q "inet ${ip}/"; then
    log "adding loopback alias ${ip}/32 on ${CAP_IF}"
    ip addr add "${ip}/32" dev "$CAP_IF"
    return 0   # signal that we added it
  fi
  return 1     # already present, do not remove later
}

wait_for_up() {
  local ctrl="$1" deadline=$((SECONDS + UP_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "$CONTROL" --control="$ctrl" status 2>/dev/null | grep -qiE '\bUp\b'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

run_mode() {
  # $1 = mode label (single|multi); $2 = expected port; $3 = extra beacon args
  local mode="$1" expect_port="$2" extra="$3"
  local pcap="${WORKDIR}/${mode}.pcap"

  log "=== mode=${mode} (expect UDP port ${expect_port}) ==="

  # Start capture for the expected port on loopback.
  tcpdump -i "$CAP_IF" -w "$pcap" -U "udp port ${expect_port}" >/dev/null 2>&1 &
  TCPDUMP_PID=$!
  sleep 1

  # Start the two beacon instances. --nofork so we can track PIDs; logs to files.
  "$BEACON" --nofork $extra --listen="$IP_A" --control="$CTRL_A" \
      >"${WORKDIR}/beacon_a_${mode}.log" 2>&1 &
  PID_A=$!
  "$BEACON" --nofork $extra --listen="$IP_B" --control="$CTRL_B" \
      >"${WORKDIR}/beacon_b_${mode}.log" 2>&1 &
  PID_B=$!
  sleep 2

  # Each side opens an active session to the other.
  "$CONTROL" --control="$CTRL_A" connect "$IP_A" "$IP_B" >/dev/null 2>&1 \
      || fail "[$mode] 'connect' on A failed"
  "$CONTROL" --control="$CTRL_B" connect "$IP_B" "$IP_A" >/dev/null 2>&1 \
      || fail "[$mode] 'connect' on B failed"

  log "[$mode] waiting up to ${UP_TIMEOUT}s for session Up..."
  if wait_for_up "$CTRL_A"; then
    log "[$mode] session reached Up"
  else
    log "[$mode] WARNING: session did not reach Up within ${UP_TIMEOUT}s (status below)"
    "$CONTROL" --control="$CTRL_A" status 2>/dev/null | sed 's/^/[status] /' || true
  fi

  sleep 2
  kill "$PID_A" 2>/dev/null; PID_A=""
  kill "$PID_B" 2>/dev/null; PID_B=""
  kill "$TCPDUMP_PID" 2>/dev/null; wait "$TCPDUMP_PID" 2>/dev/null; TCPDUMP_PID=""

  # Verify packets were seen on the expected port and NOT on the other one.
  local other_port=3784
  [ "$expect_port" = "3784" ] && other_port=4784

  local n_expect n_other
  n_expect="$(tcpdump -nr "$pcap" "udp port ${expect_port}" 2>/dev/null | wc -l | tr -d ' ')"
  n_other="$(tcpdump -nr "$pcap" "udp port ${other_port}"  2>/dev/null | wc -l | tr -d ' ')"

  log "[$mode] packets on ${expect_port}=${n_expect}, on ${other_port}=${n_other}"
  [ "$n_expect" -gt 0 ] || fail "[$mode] expected traffic on port ${expect_port}, saw none"
  [ "$n_other" -eq 0 ]  || fail "[$mode] unexpected traffic on port ${other_port}"

  log "[$mode] OK"
}

# ---- Main ------------------------------------------------------------------
[ "$(uname -s)" = "Linux" ] || fail "this smoke test is Linux-only (uses 'ip addr')"
[ "$(id -u)" = "0" ] || log "note: not running as root; adding loopback aliases / tcpdump may fail"

require tcpdump
require ip
[ -x "$BEACON" ]  || fail "beacon binary not found/executable: $BEACON (build first, or set BEACON=)"
[ -x "$CONTROL" ] || fail "control binary not found/executable: $CONTROL (build first, or set CONTROL=)"

ensure_ip "$IP_A" && ADDED_IP_A=1 || true
ensure_ip "$IP_B" && ADDED_IP_B=1 || true

# 1) Single-hop regression: must use port 3784.
run_mode "single" 3784 ""

# 2) Multi-hop: must use port 4784.
run_mode "multi" 4784 "--multihop"

log "ALL CHECKS PASSED"
