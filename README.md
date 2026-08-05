# rSynBackTux – Synology Remote Backup for Linux Servers

<p align="center">
    <img src="res/banner.png" alt="rSynBackTux Banner" width="100%"/>
</p>

![Latest Release](https://img.shields.io/github/v/release/W0rkingChr1s/rSynBackTux)
![Downloads](https://img.shields.io/github/downloads/W0rkingChr1s/rSynBackTux/total)
![GitHub License](https://img.shields.io/github/license/W0rkingChr1s/rSynBackTux)
![Last Commit](https://img.shields.io/github/last-commit/W0rkingChr1s/rSynBackTux)
![Repo Size](https://img.shields.io/github/repo-size/W0rkingChr1s/rSynBackTux)
![Stars](https://img.shields.io/github/stars/W0rkingChr1s/rSynBackTux?style=social)
![Issues](https://img.shields.io/github/issues/W0rkingChr1s/rSynBackTux)
![Shell Script](https://img.shields.io/badge/language-shell-blue)
![CI](https://github.com/W0rkingChr1s/rSynBackTux/actions/workflows/ci.yml/badge.svg)
![Trivy Scan](https://github.com/W0rkingChr1s/rSynBackTux/actions/workflows/trivy.yml/badge.svg)
![Secret Scan](https://github.com/W0rkingChr1s/rSynBackTux/actions/workflows/secret-scan.yml/badge.svg)
[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/w0rkingchr1s)

rSynBackTux (**r**sync|**Syn**ology|**Back**up|**Tux**) sichert **beliebige Linux-Server automatisiert und zuverlässig auf eine Synology NAS** – ohne zusätzliche Software oder Agenten.
Die Sicherung läuft über den **rsync-Daemon** der Synology und ein Backup-Script, das der Installer auf dem Linux-Server einrichtet.

Der Installer richtet ein:

| Pfad | Inhalt |
| --- | --- |
| `/etc/rsynbacktux/backup.conf` | Konfiguration (Host, Modul, Benutzer, Optionen) |
| `/etc/rsynbacktux/excludes.list` | Ausschlussliste für rsync |
| `/usr/local/sbin/backup-to-synology.sh` | Backup-Runner |
| `/root/.rsync_pass` | Passwortdatei, Modus `600` |
| `/var/log/backup-to-synology.log` | Logfile inklusive Logrotation |
| systemd-Timer bzw. Cronjob | Zeitsteuerung |

Aus dem Debian-Paket installiert, liegt der Runner unter
`/usr/sbin/rsynbacktux-backup` und die Einrichtung übernimmt
`rsynbacktux-setup`; alles Weitere ist identisch.

---

## Repository

GitHub:
**<https://github.com/W0rkingChr1s/rSynBackTux>**

Direkter Installer (Raw-Datei):
**<https://raw.githubusercontent.com/W0rkingChr1s/rSynBackTux/main/src/install-syno-backup.sh>**

---

## Features

- Vollständige Serversicherung (Root-Filesystem `/`), Quellpfad frei wählbar
- Konfiguration in `/etc/rsynbacktux/backup.conf` – Änderungen ohne Neuinstallation
- systemd-Timer mit `Persistent=true`, automatischer Cron-Fallback
- Verbindungs- **und** Schreibtest zur Synology vor der Installation
- Ausschlussliste als eigene Datei, jederzeit erweiterbar
- Netzwerk-Mounts (NFS/CIFS/SSHFS) werden zur Laufzeit automatisch ausgeschlossen
- Sperre gegen parallele Läufe (`flock`)
- Korrekte Bewertung der rsync-Exitcodes (Code 24 ist kein Fehler)
- Logrotation ab Werk, Kurzmeldung ins systemd-Journal
- Nicht-interaktiver Modus für Konfigurationsmanagement und Massenrollout
- Debian-Paket inklusive Handbuchseiten, Installation und Updates über `apt-get`
- Deinstallation per Script oder `apt-get purge`, optional mit `--purge`
- Sicherung über Standard-Dienste – kein Agent, kein Docker nötig

---

## Changelog

Siehe [CHANGELOG.md](CHANGELOG.md) für eine Übersicht der Änderungen pro Version.

---

## Funktionsweise

1. Auf der Synology wird ein **rsync-Zielmodul (`NetBackup`)** eingerichtet.
2. Jeder Linux-Server meldet sich per **rsync-Konto `backup`** dort an.
3. Der Backup-Runner kopiert das Dateisystem nach `NetBackup/<SERVERNAME>/`.
4. systemd-Timer oder Cron führen den Lauf regelmäßig aus.
5. rsync überträgt nur geänderte Dateien (inkrementell).

---

## Voraussetzungen

### Synology NAS

- DSM 6 oder DSM 7
- Shared Folder für Backups (z. B. `NetBackup`)
- Aktivierte rsync-Dienste:
  - „rsync-Dienst aktivieren"
  - „Netzwerksicherungsziel aktivieren"
- rsync-Konto `backup` mit Schreibberechtigung auf das Modul `NetBackup`

### Linux-Server

- rsync (der Installer installiert es bei Bedarf nach)
- root-Rechte
- Bash 4 oder neuer

Getestet mit u. a.: Ubuntu, Debian, Rocky, AlmaLinux, RHEL, Fedora, openSUSE, Arch.

---

## Installation

### Debian und Ubuntu: APT-Repository

Für Debian, Ubuntu und Derivate gibt es ein Paket. Damit übernimmt der
Paketmanager Updates, Abhängigkeiten und die Deinstallation:

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://w0rkingchr1s.github.io/rSynBackTux/rsynbacktux-archive-keyring.asc \
  | sudo gpg --dearmor -o /etc/apt/keyrings/rsynbacktux.gpg

echo "deb [signed-by=/etc/apt/keyrings/rsynbacktux.gpg] https://w0rkingchr1s.github.io/rSynBackTux stable main" \
  | sudo tee /etc/apt/sources.list.d/rsynbacktux.list

sudo apt-get update
sudo apt-get install rsynbacktux
```

Danach einmalig einrichten – dieselben Fragen und Optionen wie beim Installer:

```bash
sudo rsynbacktux-setup
```

Ein Update kommt anschließend über `sudo apt-get upgrade` mit; die
Konfiguration in `/etc/rsynbacktux/` bleibt dabei erhalten.

### Debian und Ubuntu: einzelnes Paket

Ohne Repository lässt sich das `.deb` aus dem
[Release](https://github.com/W0rkingChr1s/rSynBackTux/releases/latest)
direkt installieren:

```bash
sudo apt-get install ./rsynbacktux_2.1.0-1_all.deb
sudo rsynbacktux-setup
```

### Alle Distributionen: Installer-Script, interaktiv

Auf Rocky, AlmaLinux, RHEL, Fedora, openSUSE, Arch und überall dort, wo kein
`.deb` passt:

```bash
curl -fsSL -o install-syno-backup.sh \
  https://raw.githubusercontent.com/W0rkingChr1s/rSynBackTux/main/src/install-syno-backup.sh
sudo bash install-syno-backup.sh
```

> **Hinweis:** `curl ... | sudo bash` wird nicht empfohlen. Bei einer Pipe belegt
> das Script selbst die Standardeingabe, sodass interaktive Abfragen ins Leere
> laufen. Der Installer liest deshalb bevorzugt von `/dev/tty` und bricht
> ansonsten mit einer klaren Meldung ab, statt sich aufzuhängen. Wer trotzdem
> per Pipe installieren will, nutzt `--non-interactive` (siehe unten).

Abgefragt werden:

- Synology-Host / IP
- rsync-Modulname (Standard: `NetBackup`)
- rsync-Benutzername (Standard: `backup`)
- Unterordner (Standard: Hostname, Sonderzeichen werden bereinigt)
- Passwort für rsync (landet ausschließlich lokal in `/root/.rsync_pass`)
- Uhrzeit für den täglichen Lauf (Standard: `03:00`)

Anschließend prüft der Installer Erreichbarkeit, Zugangsdaten **und
Schreibrechte** im Zielordner. Schlägt das fehl, bricht die Installation ab und
die Passwortdatei wird wieder entfernt.

### Nicht-interaktiv

Für Ansible, Cloud-init oder Massenrollouts (mit dem Paket genauso, dort heißt
das Kommando `rsynbacktux-setup`):

```bash
RSYNBACKTUX_PASSWORD='geheim' sudo -E bash install-syno-backup.sh \
  --non-interactive \
  --host 192.168.178.5 \
  --module NetBackup \
  --user backup \
  --time 02:30
```

Alternativ zur Umgebungsvariablen: `--password-file /pfad/zur/datei`.

### Alle Optionen

```
Verbindung:
  --host HOST              Synology Host oder IP
  --module NAME            rsync-Modul (Standard: NetBackup)
  --user NAME              rsync-Benutzer (Standard: backup)
  --subdir NAME            Zielunterordner (Standard: Hostname)
  --password-file DATEI    Datei mit dem rsync-Passwort

Backup:
  --source PFAD            Quellverzeichnis (Standard: /)
  --one-file-system        Dateisystemgrenzen nicht überschreiten

Zeitsteuerung:
  --scheduler MODUS        auto | systemd | cron | none (Standard: auto)
  --time HH:MM             Startzeit (Standard: 03:00)
  --oncalendar AUSDRUCK    systemd-OnCalendar-Ausdruck
  --cron AUSDRUCK          Cron-Ausdruck

Ablauf:
  --non-interactive        Keine Rückfragen
  --run-now / --no-run-now Testlauf nach der Installation
  --skip-connection-test   Verbindungstest überspringen
  --dry-run                Nichts verändern, nur anzeigen
  --help / --version
```

---

## Konfiguration

Alle Einstellungen liegen in `/etc/rsynbacktux/backup.conf` und werden beim
nächsten Lauf übernommen – eine Neuinstallation ist dafür nicht nötig.

| Option | Standard | Bedeutung |
| --- | --- | --- |
| `SYNO_HOST` | – | Host oder IP der Synology |
| `SYNO_MODULE` | `NetBackup` | rsync-Modul |
| `SYNO_USER` | `backup` | rsync-Benutzer |
| `SYNO_SUBDIR` | Hostname | Zielunterordner im Modul |
| `SOURCE` | `/` | Quellverzeichnis |
| `ONE_FILE_SYSTEM` | `false` | `true` = separate Partitionen werden übersprungen |
| `DELETE` | `true` | Auf dem Ziel löschen, was in der Quelle fehlt |
| `PRESERVE_ACLS` | `false` | ACLs und xattrs mitsichern |
| `VERBOSE` | `false` | Jede Datei einzeln protokollieren |
| `TOLERATE_PARTIAL` | `false` | rsync-Code 23 als Warnung statt Fehler werten |
| `BANDWIDTH_LIMIT` | leer | Limit in KB/s |
| `RSYNC_TIMEOUT` | `600` | I/O-Timeout in Sekunden |
| `EXCLUDE_REMOTE_MOUNTS` | `true` | NFS/CIFS/SSHFS zur Laufzeit ausschließen |

### Ausschlüsse

`/etc/rsynbacktux/excludes.list` enthält ein rsync-Muster pro Zeile:

```
/dev/*
/proc/*
/sys/*
/run/*
/tmp/*
/var/tmp/*
/mnt/*
/media/*
/lost+found
/swapfile
/root/.rsync_pass
/var/log/backup-to-synology.log
```

> **Wichtig:** rsync expandiert keine Klammer-Listen. Ein Muster wie
> `{/dev/*,/proc/*}` in einem einzelnen `--exclude` schließt **nichts** aus.
> Deshalb hier: ein Muster pro Zeile.

Eigene Einträge einfach ergänzen, etwa:

```
/var/lib/docker/overlay2/*
/home/*/.cache/*
```

---

## Betrieb

### Status prüfen

Mit systemd:

```bash
systemctl list-timers rsynbacktux.timer
systemctl status rsynbacktux.service
journalctl -u rsynbacktux.service --since today
```

Mit Cron:

```bash
crontab -l
```

### Manuell starten

```bash
sudo /usr/local/sbin/backup-to-synology.sh
```

Oder über systemd:

```bash
sudo systemctl start rsynbacktux.service
```

### Log

Der ausführliche Verlauf steht in `/var/log/backup-to-synology.log`, rotiert
wöchentlich, acht Generationen. Auf der Konsole bzw. im Journal erscheint nur
eine Kurzmeldung – bei Cron bedeutet das: Mail nur im Fehlerfall.

```bash
tail -f /var/log/backup-to-synology.log
```

### Exitcodes

| Code | Bedeutung | Bewertung |
| --- | --- | --- |
| `0` | Alles übertragen | Erfolg |
| `24` | Dateien verschwanden während des Laufs | Erfolg (auf laufenden Systemen normal) |
| `23` | Nicht alle Dateien übertragen | Fehler, mit `TOLERATE_PARTIAL="true"` Warnung |
| sonst | rsync-Fehler | Fehler, Code wird durchgereicht |

---

## Weitere Server einbinden

Auf jedem neuen Server:

```bash
curl -fsSL -o install-syno-backup.sh \
  https://raw.githubusercontent.com/W0rkingChr1s/rSynBackTux/main/src/install-syno-backup.sh
sudo bash install-syno-backup.sh
```

Der Installer erkennt den Hostnamen, legt `NetBackup/<SERVERNAME>/` an und
richtet die Zeitsteuerung ein.

### Ordnerstruktur auf der Synology

```
NetBackup/
├── server1/
├── server2/
├── server3/
└── server4/
```

---

## Troubleshooting

### rsync fragt nach einem Passwort

- Installer lief nicht als root
- `/root/.rsync_pass` hat falsche Rechte (muss `600` sein)
- Passwort auf der NAS weicht ab

### `Connection reset by peer`

- Falscher Modulname (`NetBackup` vs. `netbackup`)
- rsync-Konto hat keine Berechtigung auf das Modul
- Ziel war ein HyperBackup-Modul statt eines rsync-kompatiblen Moduls

### Backup läuft nicht los

```bash
systemctl list-timers rsynbacktux.timer   # systemd
crontab -l                                # cron
```

Bei Cron zusätzlich:

```bash
sudo systemctl status cron    # Debian/Ubuntu
sudo systemctl status crond   # RHEL/Fedora
```

### „Backup läuft bereits"

Ein vorheriger Lauf ist noch aktiv oder hat die Sperre nicht freigegeben:

```bash
sudo fuser -v /var/lock/rsynbacktux.lock
```

### Backup bricht ab

- NAS im Ruhezustand / HDD-Hibernation
- Netzwerkprobleme zwischen Server und NAS
- `RSYNC_TIMEOUT` in der Konfiguration erhöhen

---

## Deinstallation

Aus dem Paket installiert:

```bash
sudo apt-get remove rsynbacktux    # Zeitsteuerung und Programmdateien
sudo apt-get purge  rsynbacktux    # zusätzlich Konfiguration, Passwort und Log
```

Mit dem Installer-Script installiert:

```bash
sudo bash uninstall-syno-backup.sh
```

Entfernt Zeitsteuerung, Backup-Script und Logrotation. Konfiguration,
Passwortdatei und Logfile bleiben erhalten.

Restlos entfernen:

```bash
sudo bash uninstall-syno-backup.sh --purge
```

Der Datenbestand auf der Synology wird in keinem Fall angetastet – der Ordner
`NetBackup/<SERVERNAME>/` muss bei Bedarf manuell gelöscht werden.

---

## Entwicklung

Tests laufen mit [bats](https://github.com/bats-core/bats-core):

```bash
sudo apt-get install -y bats shellcheck
bats tests/
shellcheck -x src/*.sh scripts/*.sh tests/*.bash
```

Die Testsuite installiert vollständig in ein temporäres Verzeichnis
(`RSYNBACKTUX_PREFIX`) und ersetzt `rsync` sowie `crontab` durch Stubs – es
werden also weder root-Rechte noch eine erreichbare NAS benötigt.

### Debian-Paket bauen

```bash
sudo apt-get install -y dpkg-dev lintian
scripts/build-deb.sh            # Ergebnis: dist/rsynbacktux_<version>-1_all.deb
lintian dist/*.deb
sudo apt-get install ./dist/rsynbacktux_*_all.deb
```

Backup-Runner, systemd-Units, Logrotation und Ausschlussliste erzeugt der
Installer selbst (`--emit-package-files`), damit Paket und Script-Installation
nicht auseinanderlaufen. Der Paketinhalt liegt in `packaging/`.

### APT-Repository

`.github/workflows/apt-repo.yml` baut das Paket bei jedem Release, erzeugt
`dists/`- und `pool/`-Struktur, signiert die Release-Datei und veröffentlicht
alles im Branch `gh-pages`.

Einmalig einzurichten:

1. Signierschlüssel erzeugen:

   ```bash
   gpg --quick-generate-key 'rSynBackTux Repository <mail@example.com>' rsa4096 sign never
   gpg --list-secret-keys --keyid-format LONG    # KEY-ID ablesen
   ```

   Ohne Passphrase – die Action müsste sie sonst als zweites Secret danebenliegen
   haben, im selben Tresor. Kein Ablaufdatum, sonst bricht eines Tages bei allen
   Clients `apt update`.

2. Privaten Schlüssel als Secret `GPG_PRIVATE_KEY` hinterlegen. Am besten
   direkt aus der Pipe, dann kann beim Kopieren nichts verlorengehen:

   ```bash
   gpg --armor --export-secret-keys <KEY-ID> \
     | gh secret set GPG_PRIVATE_KEY --repo W0rkingChr1s/rSynBackTux
   ```

   Über die Weboberfläche muss der **komplette** Block hinein, von
   `-----BEGIN PGP PRIVATE KEY BLOCK-----` bis `-----END PGP PRIVATE KEY BLOCK-----`,
   mit allen Zeilenumbrüchen. Hat der Schlüssel doch eine Passphrase, kommt sie
   zusätzlich in das Secret `GPG_PASSPHRASE`.

3. Unter *Settings → Pages* als Quelle den Branch `gh-pages` wählen. Den Branch
   legt der erste erfolgreiche Lauf an – vorher bietet GitHub ihn nicht an.

Den privaten Schlüssel zusätzlich offline sichern: Geht er verloren, braucht
jeder Server, der das Repository bereits eingebunden hat, von Hand den neuen
Keyring, sonst schlägt `apt update` mit `NO_PUBKEY` fehl.

Ohne `GPG_PRIVATE_KEY` baut der Workflow das Repository trotzdem und legt es
als Artefakt ab, veröffentlicht aber nichts – ein unsigniertes APT-Repository
könnten die Clients nicht überprüfen. Ist das Secret gesetzt, aber unbrauchbar,
bricht der Lauf mit einer Meldung ab, die den Grund nennt (öffentlicher statt
privatem Schlüssel, verlorene Zeilenumbrüche, leerer Export).

---

## Lizenz

Dieses Projekt steht unter der MIT-Lizenz.
Nutzung, Anpassung und Weiterentwicklung sind ausdrücklich erwünscht.

---

Made with ❤️, sweat and slightly too much coffee ☕🐧
