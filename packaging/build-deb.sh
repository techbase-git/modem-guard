#!/bin/bash
# Builds the modem-guard .deb.
#
# Usage: ./packaging/build-deb.sh <version> [output-dir]
#
# Everything in this package is scripts, units and config, so the package is
# Architecture: all - one file works on arm64 and armhf alike, and it can be
# built on any machine with dpkg-deb.
set -euo pipefail

VERSION="${1:?usage: build-deb.sh <version> [output-dir]}"
OUTDIR="${2:-dist}"
REPO="${GITHUB_REPOSITORY:-techbase-git/modem-guard}"

PKG=modem-guard
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# mktemp -d creates 0700; the package root has to be world-readable or every
# path inside it becomes inaccessible once installed.
chmod 755 "$STAGE"

echo "Building $PKG $VERSION"

# --- file tree ----------------------------------------------------------
install -d -m 755 "$STAGE/DEBIAN"
install -d -m 755 "$STAGE/usr/sbin"
install -d -m 755 "$STAGE/lib/systemd/system"
install -d -m 755 "$STAGE/etc"
install -d -m 755 "$STAGE/etc/NetworkManager/system-connections"
install -d -m 755 "$STAGE/usr/share/doc/$PKG"

install -m 755 "$ROOT/bin/modem-guard" "$STAGE/usr/sbin/modem-guard"
install -m 755 "$ROOT/bin/modem-gpio"  "$STAGE/usr/sbin/modem-gpio"
install -m 644 "$ROOT"/systemd/*.service "$ROOT"/systemd/*.timer \
    "$STAGE/lib/systemd/system/"
install -m 644 "$ROOT/etc/modem.conf" "$STAGE/etc/modem.conf"

# NetworkManager silently ignores keyfiles that are not 0600, so the mode
# matters here and dpkg preserves it.
install -m 600 "$ROOT/etc/modem.nmconnection.example" \
    "$STAGE/etc/NetworkManager/system-connections/modem.nmconnection"

# The overlay is staged here rather than straight into /boot/firmware, which
# may not be mounted when dpkg unpacks. postinst copies it across once it has
# checked the board and that the directory exists.
install -d -m 755 "$STAGE/usr/share/$PKG/overlays"
install -m 644 "$ROOT/overlays/i2c0-cm5.dtbo" "$STAGE/usr/share/$PKG/overlays/"
install -m 644 "$ROOT/overlays/i2c0-cm5.dts"  "$STAGE/usr/share/$PKG/overlays/"

install -m 644 "$ROOT/README.md" "$STAGE/usr/share/doc/$PKG/README.md"
install -m 644 "$ROOT/LICENSE" "$STAGE/usr/share/doc/$PKG/copyright"

# --- control files ------------------------------------------------------
sed -e "s/@VERSION@/$VERSION/" -e "s#@REPO@#$REPO#" \
    "$ROOT/packaging/control.in" > "$STAGE/DEBIAN/control"
install -m 644 "$ROOT/packaging/conffiles" "$STAGE/DEBIAN/conffiles"
install -m 755 "$ROOT/packaging/postinst" "$STAGE/DEBIAN/postinst"
install -m 755 "$ROOT/packaging/prerm"    "$STAGE/DEBIAN/prerm"
install -m 755 "$ROOT/packaging/postrm"   "$STAGE/DEBIAN/postrm"

# --- build --------------------------------------------------------------
mkdir -p "$ROOT/$OUTDIR"
DEB="$ROOT/$OUTDIR/${PKG}_${VERSION}_all.deb"

# --root-owner-group avoids needing fakeroot just to get root:root ownership.
dpkg-deb --build --root-owner-group "$STAGE" "$DEB"

echo "Built $DEB"
