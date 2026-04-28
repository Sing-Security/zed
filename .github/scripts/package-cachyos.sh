#!/usr/bin/env bash
set -euo pipefail

# package-cachyos.sh — Assemble a .pkg.tar.zst for CachyOS/Arch from a pre-built Zed binary.
#
# Expects to be run from the repo root after `cargo build --release --bin zed`.
# Reads VERSION and PKGREL from the environment (set by the CI workflow).

VERSION="${VERSION:-$(grep '^version' Cargo.toml | head -1 | sed 's/.*= *"\(.*\)"/\1/')}"
PKGREL="${PKGREL:-1}"
ARCH="x86_64"
PKGNAME="zed-crucititan"

PKGDIR="pkg/${PKGNAME}-${VERSION}-${PKGREL}-${ARCH}"
OUTDIR="pkg"

echo "==> Packaging ${PKGNAME} ${VERSION}-${PKGREL} (${ARCH})"

# ── 1. Validate binary ───────────────────────────────────────────────────────
BINARY="target/release/zed"
[[ -f "${BINARY}" ]] || { echo "ERROR: ${BINARY} not found — run cargo build --release first"; exit 1; }
strip --strip-all "${BINARY}"

# ── 2. Create staging directory ──────────────────────────────────────────────
rm -rf "${PKGDIR}"
install -dm755 "${PKGDIR}/usr/bin"
install -dm755 "${PKGDIR}/usr/share/applications"
install -dm755 "${PKGDIR}/usr/share/pixmaps"
install -dm755 "${PKGDIR}/usr/share/zed/extensions"
install -dm755 "${PKGDIR}/.PKGINFO"   # placeholder; overwritten below

# ── 3. Binary ────────────────────────────────────────────────────────────────
install -Dm755 "${BINARY}" "${PKGDIR}/usr/bin/zed"

# ── 4. Icon ──────────────────────────────────────────────────────────────────
ICON_SRC=""
for candidate in \
    "crates/zed/resources/app-icon.png" \
    "assets/icons/app-icon.png" \
    "assets/icons/app_icon.png" \
    "assets/app-icon.png" \
    "assets/app_icon.png" \
    "assets/zed.png"
do
    [[ -f "${candidate}" ]] && { ICON_SRC="${candidate}"; break; }
done

if [[ -n "${ICON_SRC}" ]]; then
    install -Dm644 "${ICON_SRC}" "${PKGDIR}/usr/share/pixmaps/zed.png"
    echo "    Icon: ${ICON_SRC}"
else
    echo "    WARNING: No icon found — skipping"
fi

# ── 5. Desktop entry ─────────────────────────────────────────────────────────
DESKTOP_TEMPLATE="crates/zed/resources/zed.desktop.in"
DESKTOP_SRC=""
for candidate in \
    "assets/zed.desktop" \
    "assets/linux/zed.desktop" \
    "resources/zed.desktop"
do
    [[ -f "${candidate}" ]] && { DESKTOP_SRC="${candidate}"; break; }
done

if [[ -n "${DESKTOP_SRC}" ]]; then
    install -Dm644 "${DESKTOP_SRC}" "${PKGDIR}/usr/share/applications/zed.desktop"
    echo "    Desktop: ${DESKTOP_SRC}"
elif [[ -f "${DESKTOP_TEMPLATE}" ]]; then
    APP_NAME="Zed" APP_CLI="zed" APP_ARGS="%F" DO_STARTUP_NOTIFY="true" APP_ICON="zed" \
        envsubst < "${DESKTOP_TEMPLATE}" > "${PKGDIR}/usr/share/applications/zed.desktop"
    echo "    Desktop: rendered from ${DESKTOP_TEMPLATE}"
else
    echo "    Generating desktop entry..."
    cat > "${PKGDIR}/usr/share/applications/zed.desktop" <<'DESKTOP'
[Desktop Entry]
Name=Zed
GenericName=Text Editor
Comment=CruciTitan — AI-powered Zed editor
Exec=zed %F
Icon=zed
Type=Application
Categories=Development;IDE;TextEditor;
MimeType=text/plain;text/x-makefile;text/x-c++hdr;text/x-c++src;text/x-chdr;text/x-csrc;text/x-java;text/x-moc;text/x-python;text/x-tcl;text/x-tex;text/html;text/css;text/x-sql;text/x-diff;application/x-ruby;application/json;application/xml;
Keywords=editor;code;text;development;
StartupNotify=true
StartupWMClass=dev.zed.Zed
DESKTOP
fi

# ── 6. Bundled assets (keymaps, themes, languages) ──────────────────────────
for asset_dir in "assets/keymaps" "assets/themes" "assets/languages" "assets/settings"; do
    [[ -d "${asset_dir}" ]] && \
        cp -r "${asset_dir}" "${PKGDIR}/usr/share/zed/$(basename ${asset_dir})" && \
        echo "    Assets: ${asset_dir}"
done

# ── 7. Write .PKGINFO ────────────────────────────────────────────────────────
BINARY_SIZE=$(du -sb "${PKGDIR}" | cut -f1)
BUILD_DATE=$(date +%s)

cat > "${PKGDIR}/.PKGINFO" <<PKGINFO
pkgname = ${PKGNAME}
pkgbase = ${PKGNAME}
pkgver = ${VERSION}-${PKGREL}
pkgdesc = CruciTitan — AI-augmented Zed editor with agent harness
url = https://github.com/Rock3t/zed
builddate = ${BUILD_DATE}
packager = CruciTitan CI <ci@crucititan.dev>
size = ${BINARY_SIZE}
arch = ${ARCH}
license = GPL-3.0-or-later
license = Apache-2.0
provides = zed=${VERSION}
conflict = zed
conflict = zed-git
conflict = zed-preview
depend = alsa-lib
depend = fontconfig
depend = musl
depend = libgit2
depend = libxcb
depend = libxkbcommon
depend = openssl
depend = sqlite
depend = vulkan-icd-loader
depend = wayland
depend = zlib
depend = zstd
PKGINFO

# ── 8. Write .INSTALL (post-install hook) ────────────────────────────────────
cat > "${PKGDIR}/.INSTALL" <<'INSTALL'
post_install() {
    update-desktop-database -q 2>/dev/null || true
    gtk-update-icon-cache -q /usr/share/icons/hicolor 2>/dev/null || true
    echo "  Zed (CruciTitan) installed. Run: zed"
}
post_upgrade() { post_install; }
post_remove() {
    update-desktop-database -q 2>/dev/null || true
}
INSTALL

# ── 9. Pack .pkg.tar.zst ─────────────────────────────────────────────────────
mkdir -p "${OUTDIR}"
PKG_FILENAME="${PKGNAME}-${VERSION}-${PKGREL}-${ARCH}.pkg.tar.zst"
PKG_PATH="${OUTDIR}/${PKG_FILENAME}"

(
    cd "${PKGDIR}"
    # bsdtar preserves ownership as root:root for package files
    fakeroot -- bash -c "
        chown -R root:root .
        bsdtar -czf '../../${PKG_PATH}' --options 'zstd:compression-level=19' *  .PKGINFO .INSTALL
    "
)

echo "==> Built: ${PKG_PATH} ($(du -sh ${PKG_PATH} | cut -f1))"

# ── 10. Sign the package (requires PACKAGER_GPG_KEY in env) ──────────────────
if [[ -n "${PACKAGER_GPG_KEY:-}" ]]; then
    echo "${PACKAGER_GPG_KEY}" | gpg --batch --import
    gpg --detach-sign --use-agent --no-armor "${PKG_PATH}"
    echo "==> Signed: ${PKG_PATH}.sig"
else
    echo "    (Skipping signature — PACKAGER_GPG_KEY not set)"
fi
