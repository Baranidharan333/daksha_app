#!/usr/bin/env bash
# Builds a Debian package of the app.
#   ./packaging/build_deb.sh            -> build/deb/daksha_<version>_amd64.deb
# Install:   sudo apt install ./build/deb/daksha_<version>_amd64.deb
# Uninstall: sudo apt remove daksha
set -euo pipefail

PKG=daksha
APP_NAME="daksha"
APP_ID=com.daksha.app   # must match APPLICATION_ID in linux/CMakeLists.txt
BINARY=daksha

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' pubspec.yaml)"
ARCH=amd64
STAGE="$ROOT/build/deb/${PKG}_${VERSION}_${ARCH}"
OUT="$ROOT/build/deb/${PKG}_${VERSION}_${ARCH}.deb"

echo "==> flutter build linux --release"
flutter build linux --release

echo "==> staging $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/opt/$PKG" "$STAGE/usr/bin" \
         "$STAGE/usr/share/applications" "$STAGE/usr/share/icons/hicolor/256x256/apps"

cp -r build/linux/x64/release/bundle/. "$STAGE/opt/$PKG/"
# The plugin copies the system WPE WebKit libraries into the bundle; the package
# depends on the system ones instead (saves ~150 MB, gets distro security updates).
rm -f "$STAGE/opt/$PKG/lib/"libWPEWebKit-2.0.so* "$STAGE/opt/$PKG/lib/"libwpe-1.0.so*
strip --strip-unneeded "$STAGE/opt/$PKG/$BINARY" "$STAGE/opt/$PKG/lib/"*.so 2>/dev/null || true

ln -s "/opt/$PKG/$BINARY" "$STAGE/usr/bin/$PKG"

cp packaging/icon.png "$STAGE/usr/share/icons/hicolor/256x256/apps/$PKG.png"

cat > "$STAGE/usr/share/applications/$PKG.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=Daksha robot bringup console
Exec=/usr/bin/$PKG
Icon=$PKG
Terminal=false
Categories=Utility;Development;
StartupWMClass=$APP_ID
EOF

INSTALLED_KB="$(du -sk "$STAGE" | cut -f1)"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Architecture: $ARCH
Maintainer: Daksha <ihrphysicalai@gmail.com>
Installed-Size: $INSTALLED_KB
Depends: libgtk-3-0t64 | libgtk-3-0, libwpewebkit-2.0-1, libwpe-1.0-1, libsecret-1-0, libepoxy0, libsoup-3.0-0
Section: utils
Priority: optional
Description: $APP_NAME
 Desktop window for the Daksha bringup web UI (http://s1.local:8100),
 built with Flutter and WPE WebKit. Opens the dashboard and its log pages
 in tabs without showing the server address.
EOF

# Refresh the menu and icon caches on install and removal.
for script in postinst postrm; do
  cat > "$STAGE/DEBIAN/$script" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
exit 0
EOF
  chmod 755 "$STAGE/DEBIAN/$script"
done

echo "==> dpkg-deb"
fakeroot dpkg-deb --build --root-owner-group "$STAGE" "$OUT" >/dev/null
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
