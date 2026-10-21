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
         "$STAGE/share/applications" "$STAGE/share/mime/packages" \
         "$STAGE/share/man/man1" \
         "$STAGE/share/bash-completion/completions" \
         "$STAGE/share/zsh/site-functions" \
         "$STAGE/share/fish/vendor_completions.d" \
         "$STAGE/share/powershell/completions" \
         "$STAGE/share/euterpia/presets/templates" \
         "$STAGE/share/euterpia/presets/setlists" \
         "$STAGE/share/euterpia/presets/params"

cp "$CLI" "$STAGE/bin/euterpia"
chmod +x "$STAGE/bin/euterpia"
echo "$VERSION" > "$STAGE/VERSION"

for doc in README.md CHANGELOG.md MANIFEST.md; do
  [ -f "$ROOT/$doc" ] && cp "$ROOT/$doc" "$STAGE/share/doc/euterpia/"
done
for doc in cli.md clients.md embedding.md delivery.md quickstart.md cli-policy.md; do
  [ -f "$ROOT/docs/$doc" ] && cp "$ROOT/docs/$doc" "$STAGE/share/doc/euterpia/"
done

# Presets are data, not build artefacts (#341-#343): an installed CLI must
# find them via the installed layout (Nim preset search also checks
# `<prefix>/share/euterpia/presets`).
if [ -d "$ROOT/presets" ]; then
  cp -r "$ROOT/presets/." "$STAGE/share/euterpia/presets/"
fi

# man pages are generated from the command specification (#349), never copied
# from a hand-written directory: the shipped binary and the manual cannot
# describe different command surfaces.
"$CLI" __man --write "$STAGE/share/man/man1" >/dev/null

"$CLI" completion bash > "$STAGE/share/bash-completion/completions/euterpia"
"$CLI" completion zsh > "$STAGE/share/zsh/site-functions/_euterpia"
"$CLI" completion fish > "$STAGE/share/fish/vendor_completions.d/euterpia.fish"
"$CLI" completion powershell > "$STAGE/share/powershell/completions/euterpia.ps1"

# File-association helper: a click on a project opens a terminal in the
# project directory, then runs `euterpia open` (#348).
cat > "$STAGE/bin/euterpia-open" <<'OPEN'
#!/usr/bin/env bash
# Open an EUTERPIA project in a terminal at its directory.
set -euo pipefail
if [ "$#" -lt 1 ]; then
  echo "usage: euterpia-open <project.eproj|project.eut>" >&2
  exit 1
fi
target="$1"
cd "$(dirname "$target")"
here="$(cd "$(dirname "$0")" && pwd)"
exec "$here/euterpia" open "$(basename "$target")"
OPEN
chmod +x "$STAGE/bin/euterpia-open"

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
Exec=euterpia-open %f
Terminal=true
Categories=AudioVideo;Audio;Midi;Sequencer;
MimeType=application/x-euterpia-project;
DESKTOP

cat > "$STAGE/install.sh" <<'SH'
#!/usr/bin/env bash
# Install from the archive without a package manager (issue #229, #348).
# Default prefix: ~/.local. System-wide: PREFIX=/usr/local sudo -E ./install.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
mkdir -p "$PREFIX/bin" "$PREFIX/share/applications" \
         "$PREFIX/share/mime/packages" "$PREFIX/share/doc/euterpia" \
         "$PREFIX/share/man/man1" "$PREFIX/share/bash-completion/completions" \
         "$PREFIX/share/zsh/site-functions" \
         "$PREFIX/share/fish/vendor_completions.d" \
         "$PREFIX/share/powershell/completions" \
         "$PREFIX/share/euterpia"
install -m 755 "$HERE/bin/euterpia" "$PREFIX/bin/euterpia"
install -m 755 "$HERE/bin/euterpia-open" "$PREFIX/bin/euterpia-open"
install -m 644 "$HERE/share/applications/euterpia.desktop" "$PREFIX/share/applications/"
install -m 644 "$HERE/share/mime/packages/euterpia.xml" "$PREFIX/share/mime/packages/"
cp -r "$HERE/share/doc/euterpia/." "$PREFIX/share/doc/euterpia/"
# Manual and completion are part of the contract: `man euterpia` and tab
# completion must work for an installed binary, not only in the repository.
cp "$HERE"/share/man/man1/*.1 "$PREFIX/share/man/man1/"
cp "$HERE"/share/bash-completion/completions/euterpia \
   "$PREFIX/share/bash-completion/completions/euterpia"
cp "$HERE"/share/zsh/site-functions/_euterpia "$PREFIX/share/zsh/site-functions/_euterpia"
cp "$HERE"/share/fish/vendor_completions.d/euterpia.fish \
   "$PREFIX/share/fish/vendor_completions.d/euterpia.fish"
cp "$HERE"/share/powershell/completions/euterpia.ps1 \
   "$PREFIX/share/powershell/completions/euterpia.ps1"
mkdir -p "$PREFIX/share/euterpia"
cp -r "$HERE/share/euterpia/presets" "$PREFIX/share/euterpia/"
if command -v update-mime-database >/dev/null 2>&1; then
  update-mime-database "$PREFIX/share/mime" >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$PREFIX/share/applications" >/dev/null 2>&1 || true
fi
if command -v mandb >/dev/null 2>&1; then
  mandb -q "$PREFIX/share/man" >/dev/null 2>&1 || true
fi
if command -v xdg-mime >/dev/null 2>&1; then
  xdg-mime default euterpia.desktop application/x-euterpia-project >/dev/null 2>&1 || true
fi
echo "EUTERPIA installed: $PREFIX/bin/euterpia"
echo "Check: $PREFIX/bin/euterpia --version"
echo "Manual: MANPATH=$PREFIX/share/man man euterpia"
SH

cat > "$STAGE/uninstall.sh" <<'SH'
#!/usr/bin/env bash
# Remove files installed by install.sh (issue #229, #348).
set -euo pipefail
PREFIX="${PREFIX:-$HOME/.local}"
rm -f "$PREFIX/bin/euterpia" "$PREFIX/bin/euterpia-open" \
      "$PREFIX/share/applications/euterpia.desktop" \
      "$PREFIX/share/mime/packages/euterpia.xml" \
      "$PREFIX/share/bash-completion/completions/euterpia" \
      "$PREFIX/share/zsh/site-functions/_euterpia" \
      "$PREFIX/share/fish/vendor_completions.d/euterpia.fish" \
      "$PREFIX/share/powershell/completions/euterpia.ps1"
rm -f "$PREFIX"/share/man/man1/euterpia*.1
rm -rf "$PREFIX/share/doc/euterpia" "$PREFIX/share/euterpia"
if command -v update-mime-database >/dev/null 2>&1; then
  update-mime-database "$PREFIX/share/mime" >/dev/null 2>&1 || true
fi
echo "EUTERPIA removed from $PREFIX"
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
# macOS не содержит sha256sum: там есть shasum -a 256. Формат вывода у обоих
# одинаков ("хеш  файл"), поэтому контрольная сумма остаётся проверяемой
# одной командой на любой ОС.
if command -v sha256sum >/dev/null 2>&1; then
  ( cd "$OUTDIR" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )
else
  ( cd "$OUTDIR" && shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )
fi

echo "пакет: $ARCHIVE"
echo "sha256: $(cut -d' ' -f1 "$OUTDIR/$NAME.tar.gz.sha256")"
echo "$NAME"
