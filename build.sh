#!/bin/bash
# DOA Watcher derleme + imzalama
# ONEMLI: Her zaman Developer ID sertifikasi ile imzala.
# Ad-hoc imza (-s -) kullanilirsa her derlemede cdhash degisir ve
# Tam Disk Erisimi (FDA) izni gecersiz olur, elle yeniden vermek gerekir.
# Developer ID imzasi ile izin kalicidir.

set -e
cd "$(dirname "$0")"

# Imzalama sertifikasi. Kendi sertifikanizi kullanmak icin:
#   DOA_SIGN_CERT="Developer ID Application: ADINIZ (TEAMID)" ./build.sh
# Kurulu sertifikalari gormek icin: security find-identity -v -p codesigning
CERT="${DOA_SIGN_CERT:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"
APP="DOAWatcher.app"

if [ -z "$CERT" ]; then
  echo "HATA: Developer ID sertifikasi bulunamadi."
  echo "Ad-hoc imza (-s -) kullanilabilir ama her derlemede FDA izni bozulur."
  exit 1
fi
echo "Sertifika: $CERT"

# Yarim kalmis imzalama denemelerinden arta kalanlari temizle.
# .cstemp dosyasi kalirsa imza "code has no resources" hatasi verir.
rm -f "$APP/Contents/MacOS/"*.cstemp
rm -rf "$APP/Contents/_CodeSignature"
find "$APP" -name ".DS_Store" -delete 2>/dev/null || true

# Bundle iskeleti - .app repoya girmez, temiz klonda her sey burada uretilir
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.ozden.doa-watcher</string>
    <key>CFBundleName</key>
    <string>DOA Watcher</string>
    <key>CFBundleDisplayName</key>
    <string>DOA Watcher</string>
    <key>CFBundleExecutable</key>
    <string>DOAWatcher</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>MacOSX</string></array>
</dict>
</plist>
PLIST

echo "1/4 Ikon uretiliyor..."
# logo.jpeg -> AppIcon.icns (sips ve iconutil macOS ile gelir, ek arac gerekmez)
LOGO="logo.jpeg"
if [ -f "$LOGO" ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s -s format png "$LOGO" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d -s format png "$LOGO" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$ICONSET")"
else
  echo "   $LOGO bulunamadi, ikon atlandi"
fi

echo "2/4 Derleniyor..."
swiftc -swift-version 5 -O \
  -o "$APP/Contents/MacOS/DOAWatcher" \
  DOAWatcher.swift \
  -framework SwiftUI -framework AppKit -framework MapKit

echo "3/4 Imzalaniyor..."
codesign -s "$CERT" -f --timestamp "$APP"

echo "4/4 Dogrulaniyor..."
codesign -v "$APP" && echo "   imza gecerli"
codesign -d -r- "$APP" 2>&1 | tail -1

# --release: GitHub Releases'a yuklenecek dagitim paketi.
# Zip, ana dizine acilacak sekilde "doa-watcher" klasoru icerir; indiren kisinin
# derleme yapmasina veya gelistirici hesabina ihtiyaci yoktur.
if [ "${1:-}" = "--release" ]; then
  echo ""
  echo "Dagitim paketi hazirlaniyor..."
  STAGE_ROOT="$(mktemp -d)"
  STAGE="$STAGE_ROOT/doa-watcher"
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/$APP"
  cp doa-checker.py config.example.json README.md LICENSE "$STAGE/"
  ZIP="DOA-Watcher.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$STAGE" "$ZIP"

  # Opsiyonel noterleme (notarization): indirilen uygulamanin Gatekeeper
  # uyarisi olmadan acilmasini saglar. Bir kez kimlik kaydedin:
  #   xcrun notarytool store-credentials doa-notary \
  #     --apple-id APPLE_ID --team-id TEAMID --password UYGULAMAYA_OZEL_SIFRE
  # Sonra: NOTARY_PROFILE=doa-notary ./build.sh --release
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "Notere gonderiliyor (birkac dakika surebilir)..."
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$STAGE/$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$STAGE" "$ZIP"
    echo "Noterleme tamam, bilet pakete islendi."
  else
    echo "Not: NOTARY_PROFILE tanimli degil, noterleme atlandi."
    echo "     Noterlenmemis paket ilk aciliste Gatekeeper uyarisi verir."
  fi
  rm -rf "$STAGE_ROOT"
  echo "Dagitim paketi: $ZIP"
fi

echo ""
echo "Tamamlandi. Zamanlayiciyi yenilemek icin uygulamayi acip Kaydet'e basin."
