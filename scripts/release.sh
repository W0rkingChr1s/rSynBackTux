#!/usr/bin/env bash
# shellcheck shell=bash
#
# rSynBackTux – Version anheben und ausliefern.
#
#   scripts/release.sh <version>
#
# Das Script setzt nur die Versionsnummer und schiebt sie nach main. Alles
# Weitere übernimmt GitHub Actions: Tag anlegen, Paket bauen, Release samt
# Assets erzeugen und das APT-Repository aktualisieren.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

die() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }

if [[ $# -ne 1 ]]; then
  echo "Verwendung: $0 <version>"
  echo "Beispiel:   $0 2.3.0"
  exit 1
fi

VERSION="$1"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "Ungültige Versionsnummer: ${VERSION} (erwartet X.Y.Z, z. B. 2.3.0)"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || die "Bitte auf 'main' ausführen (aktuell: ${BRANCH})"

# Vollständige Refspecs: Im Repository liegt ein Tag namens 'main'. Ein
# schlichtes 'git pull origin main' ist damit mehrdeutig und kann auf dem Tag
# statt auf dem Branch landen.
echo "Hole den neuesten Stand von origin/main ..."
git fetch origin refs/heads/main:refs/remotes/origin/main
git merge --ff-only origin/main

git diff-index --quiet HEAD -- ||
  die "Arbeitsverzeichnis ist nicht sauber – bitte erst committen oder verwerfen."

TAG="v${VERSION}"
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
  die "Tag ${TAG} existiert bereits."
fi

echo "Setze Version auf ${VERSION} ..."
echo "$VERSION" > VERSION

# Die Scripte tragen die Version selbst; CI bricht ab, wenn sie abweicht.
sed -i -E "s/^RSYNBACKTUX_VERSION=\".*\"\$/RSYNBACKTUX_VERSION=\"${VERSION}\"/" \
  src/install-syno-backup.sh src/uninstall-syno-backup.sh

actual="$(src/install-syno-backup.sh --version)"
[[ "$actual" == "rSynBackTux ${VERSION}" ]] ||
  die "Version im Installer stimmt nicht: ${actual}"

git add VERSION src/install-syno-backup.sh src/uninstall-syno-backup.sh
git commit -m "chore: Version ${VERSION}"
git push origin "HEAD:refs/heads/main"

cat <<INFO

Version ${VERSION} ist auf main.

GitHub Actions übernimmt jetzt:
  - Tag ${TAG} anlegen
  - Paket bauen und Release mit Assets erzeugen
  - APT-Repository aktualisieren

Fortschritt: https://github.com/W0rkingChr1s/rSynBackTux/actions
INFO
