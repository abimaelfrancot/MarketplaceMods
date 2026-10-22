#!/usr/bin/env bash
# Packages MarketplaceAdBlock.dylib as a .deb for jailbroken iOS, loaded by
# ElleKit/Substrate from MobileSubstrate/DynamicLibraries.
#
# Usage: packaging/package.sh [rootless|rootful] [version]
#   scheme  rootless (default): /var/jb prefix, iphoneos-arm64
#           rootful:            no prefix,      iphoneos-arm
#   version defaults to the latest git tag without a leading "v", else 1.0.0
#
# Output: packages/MarketplaceAdBlock_<version>_<arch>.deb
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root

PKG=com.adamsardo.marketplaceadblock
DYLIB=MarketplaceAdBlock.dylib

SCHEME=${1:-rootless}
case $SCHEME in
    rootless) ARCH=iphoneos-arm64; PREFIX=/var/jb ;;
    rootful)  ARCH=iphoneos-arm;   PREFIX= ;;
    *) echo "usage: $0 [rootless|rootful] [version]" >&2; exit 1 ;;
esac

VERSION=${2:-$(git describe --tags --abbrev=0 2>/dev/null || echo 1.0.0)}
VERSION=${VERSION#v}

# Build the release dylib if needed. MPAB_LOG_ALL=0 so a value in the
# caller's environment can't turn this into the debug build.
[ -f "$DYLIB" ] || MPAB_LOG_ALL=0 ./build.sh

# build.sh writes debug builds to the same filename. These format strings
# only exist when MPAB_LOG_ALL=1, so refuse to package a debug dylib.
if grep -qE 'item types|query %\{public\}@' "$DYLIB"; then
    echo "error: $DYLIB is a debug build (MPAB_LOG_ALL=1); delete it and rerun" >&2
    exit 1
fi

# Stage in a temp dir, removed on exit.
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/mpab-stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

LIBDIR=$STAGE$PREFIX/Library/MobileSubstrate/DynamicLibraries
DOCDIR=$STAGE$PREFIX/usr/share/doc/$PKG
mkdir -p "$STAGE/DEBIAN" "$LIBDIR" "$DOCDIR"

cp "$DYLIB" packaging/MarketplaceAdBlock.plist "$LIBDIR/"
# Fakesign the staged copy so the jailbreak trusts it by CDHash.
ldid -S "$LIBDIR/$DYLIB"

# The doc README is the author's, unmodified: take it from upstream main so
# local README edits don't leak in. Fall back to the working copy outside git.
git show main:README.md > "$DOCDIR/README.md" 2>/dev/null || cp README.md "$DOCDIR/"
cp packaging/CREDITS "$DOCDIR/"

sed -e "s|@VERSION@|$VERSION|" -e "s|@ARCH@|$ARCH|" packaging/control.in > "$STAGE/DEBIAN/control"

# 0755 on every directory (including the 0700 mktemp root, which becomes
# ./ in the archive) and the dylib; 0644 on everything else.
find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE" -type f -exec chmod 0644 {} +
chmod 0755 "$LIBDIR/$DYLIB"

mkdir -p packages
OUT=packages/MarketplaceAdBlock_${VERSION}_${ARCH}.deb
dpkg-deb -Zgzip --root-owner-group -b "$STAGE" "$OUT"
