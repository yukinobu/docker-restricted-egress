#!/bin/bash
set -euo pipefail
DEB=${1:?package path required}
ANALYZE=${SYSTEMD_ANALYZE:-systemd-analyze}
command -v "$ANALYZE" >/dev/null || {
    echo 'systemd-analyze is required for make test-systemd.' >&2
    exit 1
}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
dpkg-deb -x "$DEB" "$TMP"
UNITS=$TMP/usr/lib/systemd/system
# Use a minimal Docker service with docker-ce's notify/signal-stop semantics.
# No daemon is executed; this checks syntax and the start dependency graph only.
mkdir -p "$TMP/usr/bin"
cp /usr/bin/true "$TMP/usr/bin/dockerd"
cat > "$UNITS/docker.service" <<'EOF'
[Unit]
Description=Docker fixture for dependency validation
[Service]
Type=notify
ExecStart=/usr/bin/dockerd
KillMode=process
Restart=always
EOF
for target in sysinit basic shutdown; do
    cat > "$UNITS/$target.target" <<'EOF'
[Unit]
Description=Target fixture for dependency validation
DefaultDependencies=no
EOF
done
"$ANALYZE" --root="$TMP" --man=no verify docker.service docker-restricted-egress.service
echo 'ok - systemd unit/drop-in syntax and start dependency graph'
