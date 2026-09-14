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

fresh
cat >> "$DRE_CONFIG_FILE" <<'EOF'
BLOCK_CIDRS_EXCEPTIONS="
192.168.1.53/32:udp:53 192.168.1.53/32:tcp:53
10.0.0.10/32:tcp:443
172.20.0.0/16:tcp:8000-8080
10.1.0.0/16:icmp
10.2.0.0/16
10.3.0.0/16:all
10.4.0.0/16:tcp 10.5.0.0/16:udp
10.6.0.0/16:udp:1 10.7.0.0/16:tcp:65535
10.8.0.0/16:udp:1-65535
"
EOF
ok apply; open_guard
cat > "$TMP/expected-exceptions" <<'EOF'
-A DOCKER-RESTRICTED-EGRESS -d 192.168.1.53/32 -p udp --dport 53 -j RETURN
-A DOCKER-RESTRICTED-EGRESS -d 192.168.1.53/32 -p tcp --dport 53 -j RETURN
-A DOCKER-RESTRICTED-EGRESS -d 10.0.0.10/32 -p tcp --dport 443 -j RETURN
-A DOCKER-RESTRICTED-EGRESS -d 172.20.0.0/16 -p tcp --dport 8000:8080 -j RETURN
-A DOCKER-RESTRICTED-EGRESS -d 10.1.0.0/16 -p icmp -j RETURN
-A DOCKER-RESTRICTED-EGRESS -d 10.2.0.0/16 -j RETURN
-A DOCKER-RESTRICTED-EGRESS -d 10.3.0.0/16 -j RETURN
-A DOCKER-RESTRICTED-EGRESS -d 10.4.0.0/16 -p tcp -j RETURN
-A DOCKER-RESTRICTED-EGRESS -d 10.5.0.0/16 -p udp -j RETURN
-A DOCKER-RESTRICTED-EGRESS -d 10.6.0.0/16 -p udp --dport 1 -j RETURN
-A DOCKER-RESTRICTED-EGRESS -d 10.7.0.0/16 -p tcp --dport 65535 -j RETURN
-A DOCKER-RESTRICTED-EGRESS -d 10.8.0.0/16 -p udp --dport 1:65535 -j RETURN
-A DOCKER-RESTRICTED-EGRESS -d 10.0.0.0/8 -j REJECT --reject-with icmp-admin-prohibited
-A DOCKER-RESTRICTED-EGRESS -d 172.16.0.0/12 -j REJECT --reject-with icmp-admin-prohibited
-A DOCKER-RESTRICTED-EGRESS -d 192.168.0.0/16 -j REJECT --reject-with icmp-admin-prohibited
-A DOCKER-RESTRICTED-EGRESS -j RETURN
EOF
cmp "$TMP/expected-exceptions" "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS"
cmp "$TMP/expected-jump" "$MOCK_ROOT/filter/DOCKER-USER"
ok apply; open_guard
cmp "$TMP/expected-exceptions" "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS"
pass 'exceptions precede all rejects, return to existing rules, and support protocols and port ranges idempotently'

printf 'BLOCK_CIDRS_EXCEPTIONS="10.0.0.11/32:tcp:8443"\n' >> "$DRE_CONFIG_FILE"
ok apply; open_guard
[[ $(wc -l < "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS") == 5 ]]
[[ $(head -n 1 "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS") == '-A DOCKER-RESTRICTED-EGRESS -d 10.0.0.11/32 -p tcp --dport 8443 -j RETURN' ]]
printf 'BLOCK_CIDRS_EXCEPTIONS=""\n' >> "$DRE_CONFIG_FILE"
ok apply; open_guard
cmp "$TMP/expected-policy" "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS"
printf 'BLOCK_CIDRS_EXCEPTIONS="10.0.0.11/32:tcp:8443"\n' >> "$DRE_CONFIG_FILE"
ok apply
sed '/^BLOCK_CIDRS_EXCEPTIONS=/d' "$ROOT/config/docker-restricted-egress" > "$DRE_CONFIG_FILE"
ok apply; open_guard
cmp "$TMP/expected-policy" "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS"
pass 'reload replaces and removes exceptions; older configs default to no exceptions'

fresh; ok apply
cp "$DRE_CONFIG_FILE" "$TMP/base-config"
cp "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS" "$TMP/old-policy"
for entry in 'oops' '*' 'example.com/32:tcp:443' '10.0.0.1/8' '999.0.0.0/8' '010.0.0.0/8' '::/0' \
    '10.0.0.1' '10.0.0.1/33' '10.0.0.1/32:' '10.0.0.1/32::53' '10.0.0.1/32:53' \
    '10.0.0.1/32:TCP:443' '10.0.0.1/32:sctp:443' '10.0.0.1/32:tcp:' \
    '10.0.0.1/32:tcp:443:' '10.0.0.1/32:tcp:80:443' '10.0.0.1/32:tcp:80,443' \
    '10.0.0.1/32:icmp:53' '10.0.0.1/32:all:53' '10.0.0.1/32:tcp:https' \
    '10.0.0.1/32:tcp:0' '10.0.0.1/32:udp:65536' '10.0.0.1/32:tcp:053' \
    '10.0.0.1/32:tcp:99999999999999999999' '10.0.0.1/32:udp:54-53' \
    '10.0.0.1/32:tcp:0-53' '10.0.0.1/32:udp:53-65536' '10.0.0.1/32:tcp:1-053' \
    '10.0.0.1/32:tcp:-53' '10.0.0.1/32:tcp:53-' '10.0.0.1/32:tcp:1-2-3' \
    '8.8.8.8/32:udp:53' '10.0.0.0/7' '172.0.0.0/8' '0.0.0.0/0'; do
    cp "$TMP/base-config" "$DRE_CONFIG_FILE"
    # A valid entry before an invalid one must not be applied either.
    printf 'BLOCK_CIDRS_EXCEPTIONS="10.0.0.10/32:tcp:443 %s"\n' "$entry" >> "$DRE_CONFIG_FILE"
    bad apply; guarded
    contains "$TMP/output" BLOCK_CIDRS_EXCEPTIONS
    cmp "$TMP/old-policy" "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS"
done
pass 'malformed and out-of-block exceptions fail closed before replacing any policy rules'

cp "$TMP/base-config" "$DRE_CONFIG_FILE"
printf 'BLOCK_CIDRS_EXCEPTIONS="10.0.0.10/32:tcp:443"\n' >> "$DRE_CONFIG_FILE"
ok apply; open_guard
cp "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS" "$TMP/old-policy"
printf 'BLOCK_CIDRS=""\n' >> "$DRE_CONFIG_FILE"
bad apply; guarded
cmp "$TMP/old-policy" "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS"
printf 'BLOCK_CIDRS_EXCEPTIONS=" \t\n "\n' >> "$DRE_CONFIG_FILE"
ok apply; open_guard
[[ $(< "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS") == '-A DOCKER-RESTRICTED-EGRESS -j RETURN' ]]
pass 'removing blocks requires removing their exceptions; whitespace-only lists are empty'

fresh
printf 'BLOCK_CIDRS_EXCEPTIONS="8.8.8.8/32:udp:53"\n' >> "$DRE_CONFIG_FILE"
bad apply; guarded
absent "$MOCK_ROOT/network"
absent "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS"
pass 'invalid exceptions on first apply cannot create a network or policy'

fresh
for pair in '0.0.0.0/0 255.255.255.255/32' '0.0.0.0/0 0.0.0.0/0' \
    '192.168.1.53/32 192.168.1.53/32' '172.16.0.0/12 172.31.255.255/32' \
    '192.168.1.128/25 192.168.1.255/32'; do
    read -r block exception <<< "$pair"
    cp "$ROOT/config/docker-restricted-egress" "$DRE_CONFIG_FILE"
    printf 'BLOCK_CIDRS="%s"\nBLOCK_CIDRS_EXCEPTIONS="%s"\n' "$block" "$exception" >> "$DRE_CONFIG_FILE"
    ok apply; open_guard
    contains "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS" "-d $exception -j RETURN"
done
for pair in '192.168.1.53/32 192.168.1.52/32' '172.16.0.0/12 172.32.0.0/32' \
    '192.168.1.128/25 192.168.1.127/32'; do
    read -r block exception <<< "$pair"
    cp "$ROOT/config/docker-restricted-egress" "$DRE_CONFIG_FILE"
    printf 'BLOCK_CIDRS="%s"\nBLOCK_CIDRS_EXCEPTIONS="%s"\n' "$block" "$exception" >> "$DRE_CONFIG_FILE"
    bad apply; guarded
done
pass 'exception containment handles /0, /32, non-octet masks, and adjacent addresses'

fresh
printf 'BLOCK_CIDRS_EXCEPTIONS="10.0.0.10/32:tcp:443"\n' >> "$DRE_CONFIG_FILE"
ok apply
for failure in '-t filter -A DOCKER-RESTRICTED-EGRESS -d 10.0.0.10/32' \
    '-t filter -C DOCKER-RESTRICTED-EGRESS -d 10.0.0.10/32'; do
    printf '%s\n' "$failure" > "$MOCK_ROOT/fail"
    bad apply; guarded
    rm "$MOCK_ROOT/fail"
    ok apply; open_guard
done
ok stop; guarded
absent "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS"
ok apply; open_guard
contains "$MOCK_ROOT/filter/DOCKER-RESTRICTED-EGRESS" '-d 10.0.0.10/32 -p tcp --dport 443 -j RETURN'
pass 'exception insertion and verification failures retain protection; recovery and restart restore exceptions'

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
