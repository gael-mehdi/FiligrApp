#!/bin/bash
# Construit FiligrApp.app à partir de FiligrApp.swift (macOS 12 ou plus récent).
set -e
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Les outils de développement Apple sont nécessaires."
  echo "Une fenêtre va s'ouvrir : cliquez sur « Installer », puis relancez ce script."
  xcode-select --install || true
  exit 1
fi

APP="FiligrApp.app"
echo "→ Compilation…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if ! xcrun swiftc -O -parse-as-library FiligrApp.swift -o "$APP/Contents/MacOS/FiligrApp" 2> build-erreurs.txt; then
  rm -rf "$APP"
  echo "✗ La compilation a échoué. Les détails sont dans build-erreurs.txt (même dossier)."
  open -R build-erreurs.txt
  exit 1
fi
rm -f build-erreurs.txt

# Icône : si icon.png (carré, idéalement 1024×1024) est présent, on le convertit en .icns
ICON_KEY=""
if [ -f icon.png ]; then
  echo "→ Icône…"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; then
    ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
  else
    echo "  (icône ignorée : conversion impossible)"
  fi
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FiligrApp</string>
  <key>CFBundleDisplayName</key><string>FiligrApp</string>
  <key>CFBundleIdentifier</key><string>local.filigrapp</string>
  <key>CFBundleExecutable</key><string>FiligrApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  $ICON_KEY
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Document PDF</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force -s - "$APP" >/dev/null 2>&1 || true
touch "$APP"   # pour que le Finder affiche la nouvelle icône

echo "✓ FiligrApp.app est prête."
echo "  Glissez-la dans votre dossier Applications si vous le souhaitez."
open -R "$APP"
