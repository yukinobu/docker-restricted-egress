#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
DEB=${1:?package path required}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
dpkg-deb -x "$DEB" "$TMP/root"
dpkg-deb -e "$DEB" "$TMP/control"
[[ $(dpkg-deb -f "$DEB" Package) == docker-restricted-egress ]]
[[ $(dpkg-deb -f "$DEB" Architecture) == all ]]
[[ $(< "$TMP/control/conffiles") == /etc/default/docker-restricted-egress ]]
cmp "$ROOT/src/firewall" "$TMP/root/usr/libexec/docker-restricted-egress/firewall"
cmp "$ROOT/config/docker-restricted-egress" "$TMP/root/etc/default/docker-restricted-egress"
for script in preinst postinst prerm postrm; do [[ -x $TMP/control/$script ]]; done
[[ -x $TMP/root/usr/libexec/docker-restricted-egress/firewall ]]
[[ $(stat -c %a "$TMP/root/var/lib/docker-restricted-egress") == 700 ]]
[[ -f $TMP/root/usr/lib/systemd/system/docker.service.d/50-restricted-egress.conf ]]
printf 'ok - Debian metadata, conffile, payload and modes\n'

# Run extracted maintainer scripts with all host paths redirected to a sandbox.
export PKG_TEST_ROOT=$TMP
mkdir -p "$TMP/bin" "$TMP/running-systemd" "$TMP/state"
cat > "$TMP/bin/firewall" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "firewall $*" >> "$PKG_TEST_ROOT/log"
if [[ -f $PKG_TEST_ROOT/fail && "firewall $*" == "$(< "$PKG_TEST_ROOT/fail")" ]]; then exit 1; fi
if [[ $1 == uninstall ]]; then : > "$PKG_TEST_ROOT/state/removed"; fi
EOF
cat > "$TMP/bin/systemctl" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "systemctl $*" >> "$PKG_TEST_ROOT/log"
if [[ -f $PKG_TEST_ROOT/fail && "systemctl $*" == "$(< "$PKG_TEST_ROOT/fail")" ]]; then exit 1; fi
EOF
chmod +x "$TMP/bin/firewall" "$TMP/bin/systemctl"
export PATH=$TMP/bin:$PATH
for script in preinst postinst prerm postrm; do
    sed -e "s@/usr/libexec/docker-restricted-egress/firewall@$TMP/bin/firewall@g" \
        -e "s@/run/systemd/system@$TMP/running-systemd@g" \
        -e "s@/var/lib/docker-restricted-egress@$TMP/state@g" \
        "$TMP/control/$script" > "$TMP/$script"
done
expect() { diff -u <(printf '%s\n' "$@") "$TMP/log"; }
reset_log() { : > "$TMP/log"; rm -f "$TMP/fail"; }
reset_log
bash "$TMP/preinst" upgrade 0.9.0
bash "$TMP/prerm" upgrade 1.0.0
expect 'firewall guard' 'firewall guard'
printf 'ok - upgrade blocks before unpacking\n'

reset_log
bash "$TMP/postinst" configure
expect 'firewall prepare' 'systemctl daemon-reload' 'systemctl start docker.service' 'systemctl restart docker-restricted-egress.service'
printf 'ok - configuration guards before Docker and applies via systemd\n'

reset_log
echo 'firewall prepare' > "$TMP/fail"
if bash "$TMP/postinst" configure; then exit 1; fi
expect 'firewall prepare'
printf 'ok - failed guard aborts package configuration\n'

reset_log
bash "$TMP/prerm" remove
expect 'firewall check-unused' 'systemctl stop docker-restricted-egress.service' 'firewall uninstall'
[[ -f $TMP/state/removed ]]
bash "$TMP/postrm" remove
[[ ! -e $TMP/state ]]
[[ -f $TMP/root/etc/default/docker-restricted-egress ]]
printf 'ok - remove stops service before deleting the network; config is a conffile\n'

for action in 'firewall check-unused' 'systemctl stop docker-restricted-egress.service' 'firewall uninstall'; do
    reset_log
    echo "$action" > "$TMP/fail"
    if bash "$TMP/prerm" remove; then exit 1; fi
    [[ $(tail -n 1 "$TMP/log") == "$action" ]]
done
printf 'ok - every safety-check failure aborts removal\n'

reset_log
bash "$TMP/postrm" upgrade
bash "$TMP/postrm" failed-upgrade
[[ ! -s $TMP/log ]]
mkdir -p "$TMP/state"
: > "$TMP/state/identity"
bash "$TMP/postrm" purge
[[ -f $TMP/state/identity ]]
printf 'ok - upgrade and incomplete-removal cleanup retain runtime protection state\n'

reset_log
bash "$TMP/postinst" abort-remove
bash "$TMP/postinst" abort-upgrade
expect 'systemctl daemon-reload' 'systemctl daemon-reload'
printf 'ok - aborted package operations do not reopen egress\n'
