#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export MOCK_ROOT=$TMP/mock
export DRE_CONFIG_FILE=$TMP/config DRE_STATE_DIR=$TMP/state DRE_LOCK_FILE=$TMP/lock
export PATH=$ROOT/tests/mocks:$PATH
export DOCKER_HOST=tcp://unwanted:2375 DOCKER_CONTEXT=unwanted DOCKER_API_VERSION=0.0
passed=0
fail() { echo "FAIL: $*" >&2; cat "$TMP/output" >&2; exit 1; }
fresh() {
    rm -rf "$MOCK_ROOT" "$DRE_STATE_DIR"
    mkdir -p "$MOCK_ROOT/filter" "$MOCK_ROOT/mangle"
    cp "$ROOT/config/docker-restricted-egress" "$DRE_CONFIG_FILE"
    printf '%s\n' '-A FORWARD -j DOCKER-USER' '-A FORWARD -j ACCEPT' > "$MOCK_ROOT/filter/FORWARD"
    printf '%s\n' '-A DOCKER-USER -m comment --comment existing-rule -j RETURN' > "$MOCK_ROOT/filter/DOCKER-USER"
    : > "$MOCK_ROOT/mangle/FORWARD"
    : > "$MOCK_ROOT/log"
}
fw() { bash -c 'source "$1/src/firewall"; run "$2"' bash "$ROOT" "$1" > "$TMP/output" 2>&1; }
ok() { if ! fw "$1"; then fail "expected success: $1"; fi; }
bad() { if fw "$1"; then fail "expected failure: $1"; fi; }
guarded() { [[ $(< "$MOCK_ROOT/mangle/FORWARD") == *'docker-restricted-egress:guard'* ]] || fail 'guard missing'; }
open_guard() { [[ $(< "$MOCK_ROOT/mangle/FORWARD") != *'docker-restricted-egress:guard'* ]] || fail 'guard not released'; }
contains() { [[ $(< "$1") == *"$2"* ]] || fail "missing '$2' in $1"; }
absent() { [[ ! -e $1 ]] || fail "unexpected file: $1"; }
pass() { passed=$((passed + 1)); printf 'ok %d - %s\n' "$passed" "$*"; }

fresh
rm "$MOCK_ROOT/filter/DOCKER-USER"
ok guard
guarded
absent "$MOCK_ROOT/network"
pass 'guard works before Docker chains and network exist'

fresh
ok apply
open_guard
contains "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS" '-d 10.0.0.0/8 -j REJECT'
contains "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS" '-d 172.16.0.0/12 -j REJECT'
contains "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS" '-d 192.168.0.0/16 -j REJECT'
contains "$MOCK_ROOT/filter/DOCKER-USER" '-i br-restricted ! -o br-restricted'
contains "$MOCK_ROOT/filter/DOCKER-USER" 'existing-rule'
cp "$MOCK_ROOT/filter/DOCKER-USER" "$TMP/expected-jump"
cp "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS" "$TMP/expected-policy"
ok apply
cmp "$TMP/expected-jump" "$MOCK_ROOT/filter/DOCKER-USER"
cmp "$TMP/expected-policy" "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS"
pass 'apply is idempotent, keeps existing rules, excludes same bridge, ignores Docker context'

printf 'BLOCK_CIDRS="169.254.0.0/16\n100.64.0.0/10"\n' >> "$DRE_CONFIG_FILE"
ok apply
contains "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS" '-d 100.64.0.0/10'
[[ $(< "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS") != *'10.0.0.0/8'* ]]
open_guard
pass 'reload replaces old policy and supports multiline CIDRs'

ok stop
guarded
absent "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS"
[[ -f $MOCK_ROOT/network ]]
ok stop
[[ $(wc -l < "$MOCK_ROOT/mangle/FORWARD") == 1 ]]
ok apply
open_guard
pass 'stop retains network and guard; repeated stop and restart work'

for setting in 'BRIDGE=br-other' 'NETWORK=other-net' 'SUBNET=172.31.0.0/24' 'CHAIN=OTHER-POLICY'; do
    fresh; ok apply
    printf '%s\n' "$setting" >> "$DRE_CONFIG_FILE"
    bad apply; guarded
    contains "$MOCK_ROOT/mangle/FORWARD" '-i br-restricted'
    bad uninstall; guarded
done
pass 'identity changes protect old bridge and refuse migration/removal'

for setting in 'BLOCK_CIDRS="oops"' 'BLOCK_CIDRS="10.0.0.1/8"' 'BLOCK_CIDRS="999.0.0.0/8"' 'BLOCK_CIDRS="010.0.0.0/8"' 'BLOCK_CIDRS="::/0"' 'BLOCK_CIDRS="*"' 'BRIDGE=br+' 'CHAIN=DOCKER-USER' 'BROKEN="'; do
    fresh; ok apply
    printf '%s\n' "$setting" >> "$DRE_CONFIG_FILE"
    bad apply; guarded
done
pass 'invalid values and broken Bash config fail with old guard installed'

fresh; ok apply
printf 'BLOCK_CIDRS=""\n' >> "$DRE_CONFIG_FILE"
ok apply; open_guard
[[ $(wc -l < "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS") == 1 ]]
pass 'explicit empty block list returns to Docker processing'

fresh; ok apply
rm -rf "$MOCK_ROOT/mangle" "$MOCK_ROOT/filter"
mkdir -p "$MOCK_ROOT/mangle" "$MOCK_ROOT/filter"
: > "$MOCK_ROOT/mangle/FORWARD"
printf 'BROKEN="\n' >> "$DRE_CONFIG_FILE"
bad guard; guarded
pass 'saved guard replays after host reboot even with malformed configuration'

fresh
rm "$MOCK_ROOT/filter/DOCKER-USER"
bad apply; guarded
absent "$MOCK_ROOT/network"
pass 'missing DOCKER-USER fails closed'

fresh
printf '%s\n' '-A FORWARD -j ACCEPT' '-A FORWARD -j DOCKER-USER' > "$MOCK_ROOT/filter/FORWARD"
bad apply; guarded
pass 'earlier FORWARD acceptance cannot bypass the policy silently'

fresh
printf '%s\n' '-A DOCKER-RESTRICTED-EGRESS -j ACCEPT' > "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS"
cp "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS" "$TMP/unowned"
bad apply; guarded
cmp "$TMP/unowned" "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS"
pass 'an unowned chain is preserved on collision'

fresh; ok apply
sed -i 's/br-restricted/br-existing/' "$MOCK_ROOT/network"
bad apply; guarded
contains "$MOCK_ROOT/mangle/FORWARD" '-i br-existing'
contains "$DRE_STATE_DIR/guards" br-existing
pass 'mismatched actual bridge is also blocked and remembered'

for replacement in 's/|bridge|/|macvlan|/' 's/|local|/|swarm|/' 's/|false|false|/|true|false|/' 's/|false|false|/|false|true|/' 's@172.30.0.0/24,@172.31.0.0/24,@' 's/|true|true|/|false|true|/' 's/|true|true|/|true|false|/' 's/||false|/|routed|false|/'; do
    fresh; ok apply
    sed -i "$replacement" "$MOCK_ROOT/network"
    bad apply; guarded
done
pass 'incompatible network driver, scope, IPv6, subnet, and options are rejected'

for failure in 'network ls' 'network inspect' '-t filter -F DOCKER-RESTRICTED-EGRESS' '-t filter -A DOCKER-RESTRICTED-EGRESS -d 172.16' '-t filter -I DOCKER-USER' '-t filter -C DOCKER-USER' '-t filter -C DOCKER-RESTRICTED-EGRESS -j RETURN' '-t mangle -D FORWARD'; do
    fresh; ok apply
    printf '%s\n' "$failure" > "$MOCK_ROOT/fail"
    bad apply; guarded
    rm "$MOCK_ROOT/fail"
    ok apply; open_guard
done
pass 'Docker and mid-policy failures keep guard; corrected reload recovers'

fresh
printf '%s\n' '-t mangle -I FORWARD' > "$MOCK_ROOT/fail"
bad guard
absent "$MOCK_ROOT/network"
pass 'guard insertion failure returns failure to Docker ExecStartPre'

fresh; ok apply
printf '%s\n' '-A mangle-unrelated -j RETURN' > "$MOCK_ROOT/mangle/unrelated"
printf '%s\n' '-A FORWARD -j ACCEPT' > "$MOCK_ROOT/mangle/FORWARD"
ok guard; guarded
[[ $(head -n 1 "$MOCK_ROOT/mangle/FORWARD") == *'docker-restricted-egress:guard'* ]]
ok apply
contains "$MOCK_ROOT/mangle/FORWARD" '-A FORWARD -j ACCEPT'
contains "$MOCK_ROOT/mangle/unrelated" '-A mangle-unrelated -j RETURN'
pass 'guard precedes existing mangle ACCEPT and preserves unrelated rules'

fresh; ok apply
sed -i 's/|0|true|/|1|true|/' "$MOCK_ROOT/network"
bad uninstall; guarded
[[ -f $MOCK_ROOT/network && -f $MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS ]]
pass 'connected endpoints refuse uninstall without removing policy'

for marker in daemon-down race-attach race-recreate; do
    fresh; ok apply
    : > "$MOCK_ROOT/$marker"
    bad uninstall; guarded
    [[ -f $MOCK_ROOT/network && -f $MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS ]]
done
pass 'unavailable daemon, attach race, and recreation race retain protection'

fresh; ok apply
printf '%s\n' 'network rm' > "$MOCK_ROOT/fail"
bad uninstall; guarded
rm "$MOCK_ROOT/fail"
ok uninstall; open_guard
absent "$MOCK_ROOT/network"
absent "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS"
contains "$MOCK_ROOT/filter/DOCKER-USER" existing-rule
ok stop; ok guard; ok uninstall
open_guard
bad apply
ok prepare; ok apply; open_guard
pass 'removal failure recovers; completed removal suppresses hooks until reinstall'

fresh; ok apply
rm "$MOCK_ROOT/network"
bad apply; guarded
ok uninstall; open_guard
pass 'missing managed network refuses silent recreation but can be uninstalled'

fresh; ok apply
printf '%s\n' '-t filter -S' > "$MOCK_ROOT/fail"
bad uninstall; guarded
[[ -f $DRE_STATE_DIR/chain-owned ]]
pass 'filter inspection failure cannot discard ownership or guard'

fresh
fw apply & first_pid=$!
fw apply & second_pid=$!
wait "$first_pid"; wait "$second_pid"
open_guard
[[ $(wc -l < "$MOCK_ROOT/filter/DOCKER-USER") == 2 ]]
pass 'concurrent apply operations serialize with flock'

printf '%d firewall scenarios passed\n' "$passed"
