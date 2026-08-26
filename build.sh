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

echo "1/3 Derleniyor..."
swiftc -swift-version 5 -O \
  -o "$APP/Contents/MacOS/DOAWatcher" \
  DOAWatcher.swift \
  -framework SwiftUI -framework AppKit

echo "2/3 Imzalaniyor..."
codesign -s "$CERT" -f --timestamp "$APP"

echo "3/3 Dogrulaniyor..."
codesign -v "$APP" && echo "   imza gecerli"
codesign -d -r- "$APP" 2>&1 | tail -1

echo ""
echo "Tamamlandi. Zamanlayiciyi yenilemek icin uygulamayi acip Kaydet'e basin."
