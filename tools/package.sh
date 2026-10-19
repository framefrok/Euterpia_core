#!/usr/bin/env bash
# tools/package.sh
#
# Сборка архива поставки EUTERPIA (issue #229): Linux и macOS.
#
# Что делает:
#   * раскладывает бинарь, документацию и файлы ассоциации проектов;
#   * на macOS дополнительно собирает `Euterpia.app` с Info.plist;
#   * проверяет, что версия бинаря совпадает с `euterpia_version.nim` (#113);
#   * кладёт `VERSION`, `install.sh`, `uninstall.sh` и SHA256-контроль.
#
# Почему ассоциации лежат в пакете: пользователь получает архив и install.sh,
# а не инструкцию «пропишите MIME руками».
#
# Использование: tools/package.sh build/euterpia [каталог-вывода]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${1:-$ROOT/build/euterpia}"
OUTDIR="${2:-$ROOT/build/dist}"

fail() { echo "package: $*" >&2; exit 1; }

[ -x "$CLI" ] || fail "нет исполняемого бинаря: $CLI"
mkdir -p "$OUTDIR"

VERSION="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/euterpia_version.nim" | head -1)"
[ -n "$VERSION" ] || fail "не удалось прочитать версию из euterpia_version.nim"
CLI_VERSION="$("$CLI" --version)"
[ "$CLI_VERSION" = "euterpia $VERSION" ] || \
  fail "версия бинаря «$CLI_VERSION» не совпала с $VERSION (euterpia_version.nim)"

case "$(uname -s)" in
  Linux)  OS=linux ;;
  Darwin) OS=macos ;;
  *)      fail "неподдерживаемая ОС: $(uname -s)" ;;
esac
ARCH="$(uname -m)"
NAME="euterpia-$VERSION-$OS-$ARCH"
STAGE="$OUTDIR/$NAME"

rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/share/doc/euterpia" \
         "$STAGE/share/applications" "$STAGE/share/mime/packages"

cp "$CLI" "$STAGE/bin/euterpia"
chmod +x "$STAGE/bin/euterpia"
echo "$VERSION" > "$STAGE/VERSION"

for doc in README.md CHANGELOG.md MANIFEST.md; do
  [ -f "$ROOT/$doc" ] && cp "$ROOT/$doc" "$STAGE/share/doc/euterpia/"
done
for doc in cli.md clients.md embedding.md delivery.md; do
  [ -f "$ROOT/docs/$doc" ] && cp "$ROOT/docs/$doc" "$STAGE/share/doc/euterpia/"
done

# --- ассоциация файлов проекта (Linux, freedesktop) -------------------------
cat > "$STAGE/share/mime/packages/euterpia.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-euterpia-project">
    <comment>EUTERPIA project</comment>
    <glob pattern="*.eproj"/>
    <glob pattern="*.eut"/>
    <magic priority="50">
      <match value="&quot;format&quot;: &quot;euterpia-project&quot;" type="string" offset="0:512"/>
    </magic>
  </mime-type>
</mime-info>
XML

cat > "$STAGE/share/applications/euterpia.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=EUTERPIA
Comment=Digital audio workstation
Exec=euterpia %f
Terminal=true
Categories=AudioVideo;Audio;Midi;Sequencer;
MimeType=application/x-euterpia-project;
DESKTOP

cat > "$STAGE/install.sh" <<'SH'
#!/usr/bin/env bash
# Установка из архива без пакетного менеджера (issue #229).
# По умолчанию — ~/.local; системно: PREFIX=/usr/local sudo -E ./install.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
mkdir -p "$PREFIX/bin" "$PREFIX/share/applications" \
         "$PREFIX/share/mime/packages" "$PREFIX/share/doc/euterpia"
install -m 755 "$HERE/bin/euterpia" "$PREFIX/bin/euterpia"
install -m 644 "$HERE/share/applications/euterpia.desktop" "$PREFIX/share/applications/"
install -m 644 "$HERE/share/mime/packages/euterpia.xml" "$PREFIX/share/mime/packages/"
cp -r "$HERE/share/doc/euterpia/." "$PREFIX/share/doc/euterpia/"
if command -v update-mime-database >/dev/null 2>&1; then
  update-mime-database "$PREFIX/share/mime" >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$PREFIX/share/applications" >/dev/null 2>&1 || true
fi
if command -v xdg-mime >/dev/null 2>&1; then
  xdg-mime default euterpia.desktop application/x-euterpia-project >/dev/null 2>&1 || true
fi
echo "EUTERPIA установлена: $PREFIX/bin/euterpia"
echo "Проверка: $PREFIX/bin/euterpia --version"
SH

cat > "$STAGE/uninstall.sh" <<'SH'
#!/usr/bin/env bash
# Удаление файлов, установленных install.sh (issue #229).
set -euo pipefail
PREFIX="${PREFIX:-$HOME/.local}"
rm -f "$PREFIX/bin/euterpia" \
      "$PREFIX/share/applications/euterpia.desktop" \
      "$PREFIX/share/mime/packages/euterpia.xml"
rm -rf "$PREFIX/share/doc/euterpia"
if command -v update-mime-database >/dev/null 2>&1; then
  update-mime-database "$PREFIX/share/mime" >/dev/null 2>&1 || true
fi
echo "EUTERPIA удалена из $PREFIX"
SH
chmod +x "$STAGE/install.sh" "$STAGE/uninstall.sh"

# --- macOS: app bundle с ассоциацией ----------------------------------------
if [ "$OS" = "macos" ]; then
  APP="$STAGE/Euterpia.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$CLI" "$APP/Contents/MacOS/euterpia"
  cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>EUTERPIA</string>
  <key>CFBundleIdentifier</key><string>org.euterpia.daw</string>
  <key>CFBundleExecutable</key><string>euterpia</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>EUTERPIA project</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>CFBundleTypeExtensions</key>
    <array><string>eproj</string><string>eut</string></array>
  </dict></array>
</dict>
</plist>
PLIST
fi

# --- архив и контрольная сумма ---------------------------------------------
ARCHIVE="$OUTDIR/$NAME.tar.gz"
tar -C "$OUTDIR" -czf "$ARCHIVE" "$NAME"
( cd "$OUTDIR" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )

echo "пакет: $ARCHIVE"
echo "sha256: $(cut -d' ' -f1 "$OUTDIR/$NAME.tar.gz.sha256")"
echo "$NAME"
