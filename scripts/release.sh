#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version>"
  echo "Beispiel: $0 1.0.3"
  exit 1
fi

VERSION="$1"

# einfache Versionsprüfung: X.Y.Z
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Ungültige Versionsnummer: $VERSION (erwartet: X.Y.Z, z.B. 1.0.3)"
  exit 1
fi

# auf welchem Branch sind wir?
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
  echo "Bitte auf 'main' ausführen (aktueller Branch: $BRANCH)"
  exit 1
fi

# Arbeitsverzeichnis sauber (nur getrackte Dateien prüfen, untracked erlauben)?
if ! git diff-index --quiet HEAD --; then
  echo "Arbeitsverzeichnis ist nicht sauber (Änderungen an getrackten Dateien)."
  git status
  exit 1
fi

echo "Starte Release für Version $VERSION auf Branch $BRANCH ..."
echo

# 1) VERSION-Datei setzen
echo "$VERSION" > VERSION

# 2) Commit
git add VERSION
git commit -m "Release $VERSION"

# 3) Push main
git push origin main

# 4) Tag setzen
TAG="v$VERSION"
git tag "$TAG"

# 5) Tag pushen
git push origin "$TAG"

echo
echo "Release $VERSION vorbereitet:"
echo "- VERSION-Datei aktualisiert"
echo "- Commit auf main erstellt und gepusht"
echo "- Tag $TAG erstellt und gepusht"
echo
echo "GitHub Actions bauen jetzt automatisch:"
echo "- Changelog"
echo "- Release inkl. Assets"