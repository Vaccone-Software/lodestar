#!/bin/bash
# The whole suite in a virtual Mac of our own (tools/vm, on Apple's
# Virtualization framework): its own window server, screen and keys, so the
# tests that make a panel key or draw a picture never take the person's.
#
#   scripts/vm-test.sh                   run scripts/test.sh in the guest
#   scripts/vm-test.sh --fresh           start again from the base image
#   scripts/vm-test.sh --import <dir>    take a provisioned bundle as the base
#   TEST_SHARDS=4 scripts/vm-test.sh     test.sh's own settings pass through
#
# The base (~/.local/share/lodestar-vm/base) is a macOS 27 bundle with Xcode,
# an account `admin` that logs in by itself, and Remote Login on: the
# Setup Assistant answered once, the only step that is not ours. Runs use a
# copy-on-write clone of it, `test`, kept between runs so its build is warm;
# --fresh throws it away. The guest gets 6 cores and 8 GB unless
# LODESTAR_VM_CPUS / LODESTAR_VM_MEMORY_GB say otherwise, and runs only for
# the length of the suite.
#
# Results come back to .build/vm-test-results (junit.xml and the shard logs).
# The exit code is the suite's.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VM_HOME=${LODESTAR_VM_HOME:-$HOME/.local/share/lodestar-vm}
BASE=$VM_HOME/base
WORK=$VM_HOME/test
KEY=$VM_HOME/id_ed25519
KNOWN=$VM_HOME/known_hosts
TOOL=$ROOT/tools/vm/.build/release/lodestar-vm
CPUS=${LODESTAR_VM_CPUS:-6}
MEMORY=${LODESTAR_VM_MEMORY_GB:-8}
# The image's account. The guest is reachable only from this Mac (NAT), and
# the password is used once, to put this Mac's key in its place.
GUEST_USER=admin
GUEST_PASSWORD=admin

say() { printf '%s\n' "$*" >&2; }
mkdir -p "$VM_HOME"

# The runner, built and signed with the one entitlement the framework asks for.
if [ ! -x "$TOOL" ] || [ -n "$(find "$ROOT/tools/vm/Sources" "$ROOT/tools/vm/Package.swift" -newer "$TOOL" 2>/dev/null)" ]; then
    (cd "$ROOT/tools/vm" && swift build -c release >/dev/null)
    codesign --force --sign - --entitlements "$ROOT/tools/vm/vm.entitlements" "$TOOL" 2>/dev/null
fi

case "${1:-}" in
--import)
    [ -n "${2:-}" ] && [ -f "$2/config.json" ] || { say "usage: scripts/vm-test.sh --import <bundle dir>"; exit 64; }
    [ -e "$BASE" ] && { say "✕ $BASE already exists: remove it first"; exit 1; }
    "$TOOL" clone "$2" "$BASE" >/dev/null
    say "base: $BASE"
    exit 0 ;;
--fresh)
    rm -rf "$WORK"
    shift ;;
esac

[ -f "$BASE/config.json" ] || { say "✕ no base image at $BASE (scripts/vm-test.sh --import <bundle dir>)"; exit 1; }
[ -d "$WORK" ] || "$TOOL" clone "$BASE" "$WORK" >/dev/null
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C lodestar-vm -f "$KEY"

LOG=$VM_HOME/run.log
"$TOOL" run "$WORK" --cpus "$CPUS" --memory-gb "$MEMORY" >"$LOG" 2>&1 &
VM_PID=$!
IP=
SSH_OPTS=(-i "$KEY" -o UserKnownHostsFile="$KNOWN" -o StrictHostKeyChecking=accept-new
          -o ConnectTimeout=5 -o ServerAliveInterval=15 -o LogLevel=ERROR)
guest() { ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$GUEST_USER@$IP" "$@"; }
stop() {
    if [ -n "$IP" ]; then guest 'sudo shutdown -h now' >/dev/null 2>&1 || true; fi
    for _ in $(seq 60); do kill -0 "$VM_PID" 2>/dev/null || return 0; sleep 1; done
    kill -TERM "$VM_PID" 2>/dev/null || true
    wait "$VM_PID" 2>/dev/null || true
}
trap stop EXIT

say "booting the guest ($CPUS cores, $MEMORY GB)"
for _ in $(seq 180); do
    kill -0 "$VM_PID" 2>/dev/null || { say "✕ the guest stopped:"; cat "$LOG" >&2; exit 1; }
    IP=$("$TOOL" ip "$WORK" 2>/dev/null || true)
    if [ -n "$IP" ] && nc -z -G 2 "$IP" 22 2>/dev/null; then break; fi
    IP=; sleep 1
done
[ -n "$IP" ] || { say "✕ the guest never answered on port 22"; exit 1; }

# This Mac's key, once, with the image's password.
if ! guest true 2>/dev/null; then
    ASKPASS=$(mktemp "$VM_HOME/askpass.XXXXXX")
    printf '#!/bin/sh\necho %s\n' "$GUEST_PASSWORD" >"$ASKPASS"
    chmod 700 "$ASKPASS"
    SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY=none \
        ssh "${SSH_OPTS[@]}" -o PreferredAuthentications=password,keyboard-interactive "$GUEST_USER@$IP" \
        'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys' <"$KEY.pub"
    rm -f "$ASKPASS"
    guest true || { say "✕ the guest refused this Mac's key"; exit 1; }
fi

say "copying the tree to $IP"
rsync -a --delete --exclude .build --exclude .git --exclude '.swiftpm' \
    -e "ssh ${SSH_OPTS[*]}" "$ROOT/" "$GUEST_USER@$IP:lodestar/"

# test.sh's settings, as they were given here.
ENVS=()
for name in $(compgen -e | grep -E '^TEST_'); do ENVS+=("$name=$(printf %q "${!name}")"); done

say "running the suite in the guest"
set +e
guest "cd lodestar && ${ENVS[*]+${ENVS[*]}} scripts/test.sh $(printf '%q ' "$@")"
STATUS=$?
set -e

mkdir -p "$ROOT/.build/vm-test-results"
rsync -a -e "ssh ${SSH_OPTS[*]}" "$GUEST_USER@$IP:lodestar/.build/test-results/" "$ROOT/.build/vm-test-results/" 2>/dev/null || true
rsync -a -e "ssh ${SSH_OPTS[*]}" "$GUEST_USER@$IP:lodestar/.build/test-shards/" "$ROOT/.build/vm-test-results/shards/" 2>/dev/null || true
say "results: $ROOT/.build/vm-test-results"
exit $STATUS
