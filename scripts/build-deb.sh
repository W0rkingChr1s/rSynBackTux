#!/usr/bin/env bash
# shellcheck shell=bash
#
# rSynBackTux – baut das Debian-Paket.
#
#   scripts/build-deb.sh [ZIELVERZEICHNIS]
#
# Ergebnis: ZIELVERZEICHNIS/rsynbacktux_<version>-<revision>_all.deb
# (Standard: dist/). Die Paketrevision lässt sich über DEB_REVISION setzen.
#
# Es werden nur dpkg-deb und Standardwerkzeuge benötigt – kein debhelper,
# kein fakeroot (dpkg-deb --root-owner-group setzt die Eigentümer selbst).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-${REPO_ROOT}/dist}"
DEB_REVISION="${DEB_REVISION:-1}"

INSTALLER="${REPO_ROOT}/src/install-syno-backup.sh"
PACKAGING="${REPO_ROOT}/packaging/debian"
MAN_DIR="${REPO_ROOT}/packaging/man"

die() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }

command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb nicht gefunden (Paket dpkg-dev)."
[[ -x "$INSTALLER" ]] || die "Installer nicht gefunden: ${INSTALLER}"

VERSION="$(cat "${REPO_ROOT}/VERSION")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Ungültige Version in VERSION: ${VERSION}"

# Version des Installers muss zur VERSION-Datei passen, sonst meldet das Paket
# später etwas anderes als draufsteht.
installer_version="$("$INSTALLER" --version)"
[[ "$installer_version" == "rSynBackTux ${VERSION}" ]] ||
  die "VERSION (${VERSION}) und Installer (${installer_version}) weichen ab."

DEB_VERSION="${VERSION}-${DEB_REVISION}"
PKG_DIR="$(mktemp -d)"
trap 'rm -rf "$PKG_DIR"' EXIT

printf 'Baue rsynbacktux %s ...\n' "$DEB_VERSION"

# --- Vom Paket mitgelieferte Dateien -----------------------------------------
# Backup-Runner, systemd-Units, Logrotation und Ausschlussliste erzeugt der
# Installer selbst. So gibt es nur eine Quelle für diese Dateien.
"$INSTALLER" --emit-package-files "$PKG_DIR" >/dev/null

# Das Einrichtungskommando ist der Installer selbst: unter dem Namen
# 'rsynbacktux-setup' schaltet er automatisch in den Paketmodus.
install -D -m 755 "$INSTALLER" "${PKG_DIR}/usr/sbin/rsynbacktux-setup"

# --- Dokumentation -----------------------------------------------------------
DOC_DIR="${PKG_DIR}/usr/share/doc/rsynbacktux"
install -d -m 755 "$DOC_DIR"
install -m 644 "${PACKAGING}/copyright" "${DOC_DIR}/copyright"
install -m 644 "${REPO_ROOT}/README.md" "${DOC_DIR}/README.md"

# changelog.Debian.gz aus der VERSION ableiten – reicht für ein Paket, das
# außerhalb von Debian gepflegt wird, und hält lintian ruhig.
{
  printf 'rsynbacktux (%s) stable; urgency=medium\n\n' "$DEB_VERSION"
  printf '  * Release %s. Details siehe /usr/share/doc/rsynbacktux/README.md\n' "$VERSION"
  printf '    und https://github.com/W0rkingChr1s/rSynBackTux/blob/main/CHANGELOG.md\n\n'
  printf ' -- Christoph <38165726+W0rkingChr1s@users.noreply.github.com>  %s\n' \
    "$(date -R --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}")"
} | gzip -9n > "${DOC_DIR}/changelog.Debian.gz"
chmod 644 "${DOC_DIR}/changelog.Debian.gz"

# --- Handbuchseiten ----------------------------------------------------------
install -d -m 755 "${PKG_DIR}/usr/share/man/man5" "${PKG_DIR}/usr/share/man/man8"
for page in "$MAN_DIR"/*.8; do
  gzip -9nc "$page" > "${PKG_DIR}/usr/share/man/man8/$(basename "$page").gz"
  chmod 644 "${PKG_DIR}/usr/share/man/man8/$(basename "$page").gz"
done
for page in "$MAN_DIR"/*.5; do
  gzip -9nc "$page" > "${PKG_DIR}/usr/share/man/man5/$(basename "$page").gz"
  chmod 644 "${PKG_DIR}/usr/share/man/man5/$(basename "$page").gz"
done

# --- Steuerdateien -----------------------------------------------------------
install -d -m 755 "${PKG_DIR}/DEBIAN"

installed_size="$(du -ks --exclude=DEBIAN "$PKG_DIR" | cut -f1)"
sed -e "s/@VERSION@/${DEB_VERSION}/" \
    -e "s/@INSTALLED_SIZE@/${installed_size}/" \
    "${PACKAGING}/control.in" > "${PKG_DIR}/DEBIAN/control"
chmod 644 "${PKG_DIR}/DEBIAN/control"

install -m 644 "${PACKAGING}/conffiles" "${PKG_DIR}/DEBIAN/conffiles"
for script in postinst prerm postrm; do
  install -m 755 "${PACKAGING}/${script}" "${PKG_DIR}/DEBIAN/${script}"
done

# md5sums über alle Nutzdateien (ohne DEBIAN/)
( cd "$PKG_DIR" && find . -type f ! -path './DEBIAN/*' -printf '%P\0' \
    | sort -z | xargs -0 md5sum > DEBIAN/md5sums )
chmod 644 "${PKG_DIR}/DEBIAN/md5sums"

# --- Paket bauen -------------------------------------------------------------
install -d -m 755 "$OUT_DIR"
DEB_FILE="${OUT_DIR}/rsynbacktux_${DEB_VERSION}_all.deb"
dpkg-deb --root-owner-group --build "$PKG_DIR" "$DEB_FILE" >/dev/null

printf 'Paket gebaut: %s\n' "$DEB_FILE"
dpkg-deb --info "$DEB_FILE" | sed -n '1,12p'
printf '\nInhalt:\n'
dpkg-deb --contents "$DEB_FILE" | awk '{ print "  " $6 }'
