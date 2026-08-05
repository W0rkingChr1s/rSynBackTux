# Changelog

## v2.1.0 - 2026-08-04

Bereitstellung als Debian-Paket. Die Installation über das Script bleibt
unverändert – wer sie nutzt, muss nichts ändern.

### Neu

- **Debian-Paket `rsynbacktux`** für Debian, Ubuntu und Derivate:
  `apt-get install rsynbacktux`, danach einmalig `sudo rsynbacktux-setup`.
  Updates und Deinstallation übernimmt der Paketmanager, die Konfiguration in
  `/etc/rsynbacktux/` bleibt dabei erhalten.
- **APT-Repository** über GitHub Pages: `.github/workflows/apt-repo.yml` baut
  das Paket bei jedem Release, signiert die Release-Datei mit GPG und
  veröffentlicht `dists/`- und `pool/`-Struktur im Branch `gh-pages`. Ohne
  hinterlegten Schlüssel wird nichts veröffentlicht.
- **`scripts/build-deb.sh`** baut das Paket allein mit `dpkg-deb`, ohne
  debhelper und ohne fakeroot.
- **Handbuchseiten** `rsynbacktux-setup(8)`, `rsynbacktux-backup(8)` und
  `rsynbacktux.conf(5)`.
- Der Installer kennt zwei neue Optionen: `--emit-package-files DIR` schreibt
  die statischen Paketdateien für den Paketbau, `--packaged` richtet nur
  Konfiguration, Passwortdatei und Zeitsteuerung ein. Unter dem Namen
  `rsynbacktux-setup` aufgerufen, schaltet er selbst in den Paketmodus.
- CI baut das Paket, prüft es mit lintian, installiert es auf dem Runner,
  richtet einen systemd-Timer ein und prüft, dass `purge` restlos aufräumt.
  Die Testsuite wächst um 18 Tests auf 67.

### Geändert

- Im Paketmodus gehören Backup-Runner (`/usr/sbin/rsynbacktux-backup`),
  systemd-Units, Logrotation und Ausschlussliste dem Paketmanager. Die Uhrzeit
  landet in einem Drop-in (`rsynbacktux.timer.d/override.conf`), damit ein
  Paket-Update sie nicht überschreibt, und eine vorhandene Ausschlussliste
  bleibt bei erneutem `rsynbacktux-setup` unangetastet.
- Der Timer wird nach der Paketinstallation bewusst noch nicht aktiviert –
  ohne Konfiguration hätte ein Lauf keine Chance. Das erledigt die Einrichtung.
- Releases enthalten zusätzlich das `.deb` als Asset.

## v2.0.0 - 2026-08-02

Vollständige Überarbeitung. Die Konfiguration liegt jetzt in `/etc/rsynbacktux/`
statt fest im generierten Script – bestehende Installationen sollten den
Installer erneut ausführen.

### Behoben

- **Ausschlüsse griffen nicht.** Alle Muster steckten in einem einzigen
  `--exclude='{/dev/*,/proc/*,...}'`. rsync expandiert keine Klammer-Listen,
  dadurch wurden `/dev`, `/proc`, `/sys`, `/tmp`, `/run`, `/mnt` und `/media`
  vollständig mitgesichert. Die Muster stehen jetzt einzeln in
  `/etc/rsynbacktux/excludes.list`.
- **Endlosschleife bei `curl | bash`.** Bei einer Pipe belegt das Script selbst
  die Standardeingabe; die Eingabeschleife lief unbegrenzt weiter. Eingaben
  werden jetzt bevorzugt von `/dev/tty` gelesen, ansonsten bricht der Installer
  nach drei Versuchen mit klarer Meldung ab.
- **Passwort landete auf der NAS.** `/root/.rsync_pass` war von keinem Ausschluss
  erfasst und wurde bei jedem Lauf mitgesichert – ebenso das Logfile.
- **rsync-Exitcode 24** („vanished files", auf laufenden Systemen normal) wurde
  durch `set -e` als Fehlschlag gewertet.
- **Fehlender Schutz vor Parallelläufen.** Der Runner sperrt jetzt per `flock`.
- Cron-Ausdrücke mit führender Null (`08:09`) werden nicht mehr als Oktalzahl
  interpretiert.
- Die Passwortdatei wird mit `install -m 600` angelegt, statt erst zu schreiben
  und danach die Rechte zu setzen.

### Neu

- Konfiguration in `/etc/rsynbacktux/backup.conf`: Host, Modul, Benutzer,
  Quellpfad, Bandbreitenlimit, Timeout und weitere Optionen ohne
  Neuinstallation änderbar.
- Zeitsteuerung über systemd-Timer (`Persistent=true`, `RandomizedDelaySec`),
  Cron als automatischer Fallback; wählbar über `--scheduler`.
- Nicht-interaktiver Modus (`--non-interactive`) mit `--host`, `--module`,
  `--user`, `--subdir`, `--time`, `--oncalendar`, `--cron`, `--password-file`
  und `RSYNBACKTUX_PASSWORD` für Massenrollouts.
- `--help` und `--version`; unbekannte Optionen enden mit Exitcode 2 statt
  stillschweigend ignoriert zu werden.
- Deinstallation über `src/uninstall-syno-backup.sh`, optional mit `--purge`.
- Logrotation über `/etc/logrotate.d/rsynbacktux` (wöchentlich, 8 Generationen).
- Netzwerk-Mounts (NFS/CIFS/SSHFS) werden zur Laufzeit automatisch
  ausgeschlossen, damit ein eingehängtes Share nicht in sich selbst landet.
- Verbindungstest prüft zusätzlich den Schreibzugriff im Zielunterordner.
- `--numeric-ids` für korrekte UID/GID-Zuordnung bei der Wiederherstellung,
  `--timeout`/`--contimeout` gegen hängende Läufe.
- Ausführliche Ausgabe geht ins Logfile, eine Kurzmeldung ins Journal bzw. bei
  Cron nur im Fehlerfall in die Mail.
- bats-Testsuite mit 49 Tests (`tests/`), die vollständig in ein temporäres
  Verzeichnis installiert und ohne NAS auskommt.

### Geändert

- `ci.yml` bündelt Lint, Tests und Dry-Run; `shellcheck.yml` und `security.yml`
  entfallen (widersprüchliche shellharden-Gates).
- Das generierte Backup-Script wird in CI erzeugt und mitgelintet.
- Der Changelog-Workflow überschreibt handgepflegte Abschnitte nicht mehr.
- Die doppelte `scripts/VERSION` entfällt, `VERSION` ist die einzige Quelle und
  wird in CI gegen `--version` geprüft.
- Standardmäßig `--info=stats2` statt `-v`; Einzeldateien nur noch mit
  `VERBOSE="true"`.

## v1.2.0 - 2026-03-27

- fix: release.yml – contents: write für GitHub Release-Erstellung (236c6cd)
- fix: changelog.yml – Commits in Variable sammeln statt direkt im Block (5c044e0)
- Release 1.2.0 (cdbf4d2)
- Merge pull request #5 from W0rkingChr1s/claude/code-review-iRE2k (2603a04)
- chore: Version auf 1.2.0 erhöht (9ff822f)
- docs: README für v1.2.0 aktualisiert (a56d60f)
- Merge pull request #2 from W0rkingChr1s/dependabot/github_actions/dot-github/workflows/github_actions-34786f325a (a21a07c)
- Merge pull request #4 from W0rkingChr1s/claude/code-review-iRE2k (7f9485b)
- fix: shellharden-Konformität – überflüssige Braces entfernt (490c257)
- fix: Hostname-Sanitierung, Netzwerkcheck, grep -F für Cron (3c8fa24)
- Merge pull request #3 from W0rkingChr1s/add-claude-github-actions-1774595246426 (8350ef4)
- "Claude Code Review workflow" (4604156)
- "Claude PR Assistant workflow" (57957f3)
- Bump aquasecurity/trivy-action (5a000cd)
- Ändere Berechtigungen in Workflow-Dateien von "write" auf "read" für ShellCheck und Trivy (0cd65fb)
- Ändere Berechtigungen in Workflow-Dateien von "read" auf "write" für Changelog, CodeQL, ShellCheck und Trivy (a56c53b)
- Füge Berechtigungen für Inhalte und Pull-Requests in Workflow-Dateien hinzu (bb43558)
- Füge Statusüberprüfung für shellharden-Linting hinzu, um CI nicht bei gefundenen Problemen zu fehlschlagen (131bdc9)
- Verbessere CodeQL-Workflow: Bereinige Berechtigungen und strukturiere den Code (02da0cc)
- Use shellharden from GitHub release in security audit workflow (d454e36)
- Update CodeQL and ShellCheck workflows for improved analysis and clarity (28ef6be)
- Remove --github-actions flag from TruffleHog step (e665de4)
- Fix TruffleHog extra_args (no duplicate --fail) (9f1f374)
- Update secret scan workflow for TruffleHog (994d3d1)
- Aktualisiere Workflows: Füge ShellCheck und Trivy-Scans hinzu, passe CodeQL- und Secret-Scan-Konfigurationen an (00feb8c)
- Aktualisiere CodeQL-Workflow: Bereinige Cron-Format und entferne nicht benötigte Sprachen (8fb7beb)
- Füge CodeQL-Analyse, Secret-Scan und Sicherheitsprüfung für Shell-Skripte hinzu (1a42337)
- Entferne veraltete Einträge aus dem CHANGELOG.md und bereinige die Struktur. (749cf52)
- Verbessere die Logik zur Versionsbestimmung und aktualisiere die Generierung des CHANGELOG.md, um Merge-Spam zu filtern und die Struktur zu optimieren. (3883d64)
- Füge .gitattributes und .gitignore hinzu; aktualisiere README.md (f82f5bd)
- Füge "Buy Me A Coffee"-Link zur README.md hinzu (1efd35f)
- Aktualisiere README.md mit korrektem GitHub-Link und füge einen persönlichen Hinweis hinzu; entferne test.txt (ccb53a0)
- Aktualisiere Beispielversionsnummer und Fehlermeldungen im Release-Skript (203b181)


## v1.1.0 - 2026-03-27

- Merge pull request #2 from W0rkingChr1s/dependabot/github_actions/dot-github/workflows/github_actions-34786f325a (a21a07c)
- Merge pull request #4 from W0rkingChr1s/claude/code-review-iRE2k (7f9485b)
- fix: shellharden-Konformität – überflüssige Braces entfernt (490c257)
- fix: Hostname-Sanitierung, Netzwerkcheck, grep -F für Cron (3c8fa24)
- Merge pull request #3 from W0rkingChr1s/add-claude-github-actions-1774595246426 (8350ef4)
- "Claude Code Review workflow" (4604156)
- "Claude PR Assistant workflow" (57957f3)
- Bump aquasecurity/trivy-action (5a000cd)
- Ändere Berechtigungen in Workflow-Dateien von "write" auf "read" für ShellCheck und Trivy (0cd65fb)
- Ändere Berechtigungen in Workflow-Dateien von "read" auf "write" für Changelog, CodeQL, ShellCheck und Trivy (a56c53b)
- Füge Berechtigungen für Inhalte und Pull-Requests in Workflow-Dateien hinzu (bb43558)
- Füge Statusüberprüfung für shellharden-Linting hinzu, um CI nicht bei gefundenen Problemen zu fehlschlagen (131bdc9)
- Verbessere CodeQL-Workflow: Bereinige Berechtigungen und strukturiere den Code (02da0cc)
- Use shellharden from GitHub release in security audit workflow (d454e36)
- Update CodeQL and ShellCheck workflows for improved analysis and clarity (28ef6be)
- Remove --github-actions flag from TruffleHog step (e665de4)
- Fix TruffleHog extra_args (no duplicate --fail) (9f1f374)
- Update secret scan workflow for TruffleHog (994d3d1)
- Aktualisiere Workflows: Füge ShellCheck und Trivy-Scans hinzu, passe CodeQL- und Secret-Scan-Konfigurationen an (00feb8c)
- Aktualisiere CodeQL-Workflow: Bereinige Cron-Format und entferne nicht benötigte Sprachen (8fb7beb)
- Füge CodeQL-Analyse, Secret-Scan und Sicherheitsprüfung für Shell-Skripte hinzu (1a42337)
- Entferne veraltete Einträge aus dem CHANGELOG.md und bereinige die Struktur. (749cf52)
- Verbessere die Logik zur Versionsbestimmung und aktualisiere die Generierung des CHANGELOG.md, um Merge-Spam zu filtern und die Struktur zu optimieren. (3883d64)
- Füge .gitattributes und .gitignore hinzu; aktualisiere README.md (f82f5bd)
- Füge "Buy Me A Coffee"-Link zur README.md hinzu (1efd35f)
- Aktualisiere README.md mit korrektem GitHub-Link und füge einen persönlichen Hinweis hinzu; entferne test.txt (ccb53a0)
- Aktualisiere Beispielversionsnummer und Fehlermeldungen im Release-Skript (203b181)


## v1.0.5 - 2025-12-04

- Merge branch 'main' of <https://github.com/W0rkingChr1s/rSynBackTux> (5b28891)
- Füge leere Testdatei hinzu (75581ee)
- Update CHANGELOG.md for v00eadb5204e7e791536bb1d29de734d742fbe4f8 (c3af40b)
- Merge branch 'main' of <https://github.com/W0rkingChr1s/rSynBackTux> (00eadb5)
- Release 1.0.5 (beecf7d)
- Update CHANGELOG.md for v57153cea91d44b2d245bf759f42f926ae93207eb (32df557)
- Add relesase helper script (57153ce)
- Update CHANGELOG.md for v59cdc22be8aca1e3284b0b0a2a9472dcb5a1a05d (f4b5bd2)
- Merge branch 'main' of <https://github.com/W0rkingChr1s/rSynBackTux> (00eadb5)
- Release 1.0.5 (beecf7d)
- Update CHANGELOG.md for v57153cea91d44b2d245bf759f42f926ae93207eb (32df557)
- Add relesase helper script (57153ce)
- Update CHANGELOG.md for v59cdc22be8aca1e3284b0b0a2a9472dcb5a1a05d (f4b5bd2)

## v1.0.4 - 2025-12-04

- Add relesase helper script (57153ce)
- Update CHANGELOG.md for v59cdc22be8aca1e3284b0b0a2a9472dcb5a1a05d (f4b5bd2)
- Bump version to 1.0.4 (59cdc22)
- Update CHANGELOG.md for v843eb603fa983606db69bd06100cb067353827bb (1c4e896)
- Aktualisiere Workflow zur Generierung des CHANGELOG.md, um nur bei Pushes auf den main-Branch zu triggern und verbessere die Tag-Verarbeitung. (843eb60)
- Update CHANGELOG.md for ${GITHUB_REF##*/} (fc09dad)
- Füge branch-Parameter zur CHANGELOG.md Commit-Aktion hinzu (fae0ca3)

## v1.0.3 - 2025-12-04

- Aktualisiere Workflow zur Generierung des CHANGELOG.md, um nur bei Pushes auf den main-Branch zu triggern und verbessere die Tag-Verarbeitung. (843eb60)
- Update CHANGELOG.md for ${GITHUB_REF##*/} (fc09dad)
- Füge branch-Parameter zur CHANGELOG.md Commit-Aktion hinzu (fae0ca3)

## main - 2025-12-04

- Füge branch-Parameter zur CHANGELOG.md Commit-Aktion hinzu (fae0ca3)
- Rename Changelog.md to CHANGELOG.md (cbde21a)
- Refactor changelog workflow to use git log (831f12d)
