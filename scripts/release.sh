#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version>"
  echo "Beispiel: $0 1.1.0"
  exit 1
fi

VERSION="$1"

# einfache Versionsprüfung: X.Y.Z
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Ungültige Versionsnummer: $VERSION (erwartet: X.Y.Z, z.B. 1.1.0)"
  exit 1
fi

# aktueller Branch
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
  echo "Bitte auf 'main' ausführen (aktueller Branch: $BRANCH)"
  exit 1
fi

echo "Starte Release für Version $VERSION auf Branch $BRANCH ..."
echo

# 1) Sicherstellen, dass wir auf dem aktuellen Stand sind
echo "Hole neuesten Stand von origin/$BRANCH ..."
git fetch origin
git pull --rebase origin "$BRANCH"

# 2) Prüfen, dass keine getrackten Änderungen offen sind
if ! git diff-index --quiet HEAD --; then
  echo "Arbeitsverzeichnis ist nicht sauber (Änderungen an getrackten Dateien vorhanden)."
  echo "Bitte Änderungen erst committen oder verwerfen:"
  git status
  exit 1
fi

# 3) VERSION-Datei setzen
echo "$VERSION" > VERSION

# 4) Commit anlegen
git add VERSION
git commit -m "Release $VERSION"

# 5) main pushen
git push origin "$BRANCH"

# 6) Tag anlegen und pushen
TAG="v$VERSION"
git tag "$TAG"
git push origin "$TAG"

echo
echo "Release $VERSION abgeschlossen:"
echo "- VERSION-Datei aktualisiert und auf $BRANCH gepusht"
echo "- Tag $TAG erstellt und gepusht"
echo
echo "GitHub Actions bauen jetzt automatisch:"
echo "- Changelog (auf main)"
echo "- Release inkl. Assets (für Tag $TAG)"