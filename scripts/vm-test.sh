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
# an account `admin` that logs in by itself, passwordless sudo and Remote
# Login: the Setup Assistant answered once, the one step that is not ours.
# Cirrus Labs' Xcode images (macos-golden-gate-xcode) also grant
# Accessibility, so the real-window tests run there as at the desk; what the
# guest cannot do is in Tests/allowed-skips.txt, place `vm`. Runs use a
# copy-on-write clone of the base, `test`, kept between runs so its build is
# warm; --fresh throws it away. The guest gets 6 cores and 12 GB unless
# LODESTAR_VM_CPUS / LODESTAR_VM_MEMORY_GB say otherwise, and runs only for
# the length of the suite. One run at a time.
#
# Results come back to .build/vm-test-results (junit.xml and the shard logs),
# emptied first, so nothing there is from an earlier run. The exit code is
# the suite's.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VM_HOME=${LODESTAR_VM_HOME:-$HOME/.local/share/lodestar-vm}
BASE=$VM_HOME/base
WORK=$VM_HOME/test
KEY=$VM_HOME/id_ed25519
KNOWN=$VM_HOME/known_hosts
TOOL=$ROOT/tools/vm/.build/release/lodestar-vm
CPUS=${LODESTAR_VM_CPUS:-6}
MEMORY=${LODESTAR_VM_MEMORY_GB:-12}
RESULTS=$ROOT/.build/vm-test-results
# The image's account. The guest is reachable only from this Mac (NAT), and
# the password is used once, to put this Mac's key in its place.
GUEST_USER=admin
GUEST_PASSWORD=admin

say() { printf '%s\n' "$*" >&2; }
mkdir -p "$VM_HOME"

# One run at a time: two would boot the same clone.
LOCK=$VM_HOME/lock
if ! mkdir "$LOCK" 2>/dev/null; then
    holder=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then say "✕ a run is already going (pid $holder)"; exit 1; fi
    rm -rf "$LOCK" && mkdir "$LOCK"
fi
echo $$ >"$LOCK/pid"
VM_PID=
IP=
ASKPASS=
cleanup() {
    [ -n "$ASKPASS" ] && rm -f "$ASKPASS"
    if [ -n "$VM_PID" ]; then
        [ -n "$IP" ] && guest 'sudo -n shutdown -h now' >/dev/null 2>&1 || true
        for _ in $(seq 60); do kill -0 "$VM_PID" 2>/dev/null || break; sleep 1; done
        kill -TERM "$VM_PID" 2>/dev/null || true
        wait "$VM_PID" 2>/dev/null || true
    fi
    rm -rf "$LOCK"
}
trap cleanup EXIT

# The runner, built and signed with the one entitlement the framework asks
# for, every time: signing is cheap, and a binary built by hand has none.
(cd "$ROOT/tools/vm" && swift build -c release >/dev/null)
codesign --force --sign - --entitlements "$ROOT/tools/vm/vm.entitlements" "$TOOL"
codesign -d --entitlements - "$TOOL" 2>/dev/null | grep -c com.apple.security.virtualization >/dev/null \
    || { say "✕ the runner is not signed with com.apple.security.virtualization"; exit 1; }

case "${1:-}" in
--import)
    [ -n "${2:-}" ] && [ -f "$2/config.json" ] || { say "usage: scripts/vm-test.sh --import <bundle dir>"; exit 64; }
    [ -e "$BASE" ] && { say "✕ $BASE already exists: remove it first"; exit 1; }
    "$TOOL" clone "$2" "$BASE" >/dev/null
    rm -rf "$WORK" "$KNOWN"   # a new base is a new machine, with a new host key
    say "base: $BASE"
    exit 0 ;;
--fresh)
    rm -rf "$WORK" "$KNOWN"
    shift ;;
esac

[ -f "$BASE/config.json" ] || { say "✕ no base image at $BASE (scripts/vm-test.sh --import <bundle dir>)"; exit 1; }
[ -f "$WORK/config.json" ] || { rm -rf "$WORK"; "$TOOL" clone "$BASE" "$WORK" >/dev/null; }
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C lodestar-vm -f "$KEY"

SSH_OPTS=(-i "$KEY" -o UserKnownHostsFile="$KNOWN" -o StrictHostKeyChecking=accept-new
          -o ConnectTimeout=5 -o ServerAliveInterval=15 -o LogLevel=ERROR)
# rsync's -e takes one string: each option quoted in it.
RSH="ssh$(printf ' %q' "${SSH_OPTS[@]}")"
guest() { ssh -n "${SSH_OPTS[@]}" -o BatchMode=yes "$GUEST_USER@$IP" "$@"; }

"$TOOL" run "$WORK" --cpus "$CPUS" --memory-gb "$MEMORY" >"$VM_HOME/run.log" 2>&1 &
VM_PID=$!

say "booting the guest ($CPUS cores, $MEMORY GB)"
for _ in $(seq 180); do
    kill -0 "$VM_PID" 2>/dev/null || { say "✕ the guest stopped:"; cat "$VM_HOME/run.log" >&2; exit 1; }
    IP=$("$TOOL" ip "$WORK" 2>/dev/null || true)
    if [ -n "$IP" ] && nc -z -G 2 "$IP" 22 2>/dev/null; then break; fi
    IP=; sleep 1
done
[ -n "$IP" ] || { say "✕ the guest never answered on port 22"; exit 1; }

# This Mac's key, once, with the image's password.
if ! guest true 2>/dev/null; then
    ASKPASS=$(mktemp "$VM_HOME/askpass.XXXXXX")
    printf '#!/bin/sh\necho %q\n' "$GUEST_PASSWORD" >"$ASKPASS"
    chmod 700 "$ASKPASS"
    SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY=none \
        ssh "${SSH_OPTS[@]}" -o PreferredAuthentications=password,keyboard-interactive "$GUEST_USER@$IP" \
        'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys' <"$KEY.pub" \
        || { say "✕ the guest did not take this Mac's key with the image's password"; exit 1; }
    rm -f "$ASKPASS"; ASKPASS=
    guest true || { say "✕ the guest refused this Mac's key"; exit 1; }
fi

# Port 22 answers before the account has logged in, and a test that opens a
# window needs that login's window server: wait for the console to be the
# account's and its GUI session to exist.
for _ in $(seq 120); do
    guest '[ "$(stat -f %Su /dev/console)" = "$(id -un)" ] && launchctl print gui/$(id -u) >/dev/null 2>&1' && break
    sleep 1
done
guest '[ "$(stat -f %Su /dev/console)" = "$(id -un)" ]' || { say "✕ the guest's account never logged in at the console"; exit 1; }

say "copying the tree to $IP"
rsync -a --delete --exclude .build --exclude .git --exclude .swiftpm -e "$RSH" "$ROOT/" "$GUEST_USER@$IP:lodestar/"

# MLX compiles its kernels with Metal's compiler, which Xcode downloads apart
# (as CI does).
guest 'xcodebuild -showComponent MetalToolchain 2>/dev/null | grep -c "Status: installed" >/dev/null \
    || xcodebuild -downloadComponent MetalToolchain >/dev/null' \
    || { say "✕ the Metal toolchain could not be installed in the guest"; exit 1; }

# test.sh's settings, as they were given here, and the place it runs in.
ENVS=LODESTAR_VM=1
for name in $(compgen -e | grep -E '^TEST_' || true); do ENVS+=" $name=$(printf %q "${!name}")"; done
ARGS=
[ $# -gt 0 ] && ARGS=$(printf ' %q' "$@")

rm -rf "$RESULTS"
say "running the suite in the guest"
set +e
# Awake for the whole run: a display that sleeps or locks mid-suite takes the
# key window from the tests.
guest "cd lodestar && caffeinate -dimsu env $ENVS scripts/test.sh$ARGS"
STATUS=$?
set -e

mkdir -p "$RESULTS"
rsync -a -e "$RSH" "$GUEST_USER@$IP:lodestar/.build/test-results/" "$RESULTS/" 2>/dev/null || true
rsync -a -e "$RSH" "$GUEST_USER@$IP:lodestar/.build/test-shards/" "$RESULTS/shards/" 2>/dev/null || true
if [ ! -f "$RESULTS/junit.xml" ]; then
    say "✕ no results came back from the guest (exit $STATUS)"
    [ "$STATUS" -eq 0 ] && STATUS=1
fi
say "results: $RESULTS"
exit "$STATUS"
