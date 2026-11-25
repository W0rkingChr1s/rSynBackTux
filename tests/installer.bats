#!/usr/bin/env bats
# Tests für src/install-syno-backup.sh

load helper

setup() {
  setup_sandbox
  stub_rsync 0
}

teardown() {
  teardown_sandbox
}

@test "--help wird ausgegeben und endet mit 0" {
  run "$INSTALLER" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Verwendung:"* ]]
  [[ "$output" == *"--non-interactive"* ]]
}

@test "--version passt zur VERSION-Datei" {
  run "$INSTALLER" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "rSynBackTux $(cat "${REPO_ROOT}/VERSION")" ]]
}

@test "unbekannte Option endet mit Exitcode 2" {
  run "$INSTALLER" --gibtsnicht
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unbekannte Option"* ]]
}

@test "ungültiger Scheduler wird abgelehnt" {
  run "$INSTALLER" --scheduler quatsch --non-interactive
  [ "$status" -ne 0 ]
  [[ "$output" == *"scheduler"* ]]
}

@test "nicht-interaktiv ohne Passwort schlägt sauber fehl" {
  run env -u RSYNBACKTUX_PASSWORD -u RSYNC_PASSWORD \
    "$INSTALLER" --non-interactive --host nas.local --skip-connection-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"Kein Passwort angegeben"* ]]
}

@test "ungültiger Host wird abgelehnt" {
  run env RSYNBACKTUX_PASSWORD=geheim \
    "$INSTALLER" --non-interactive --host 'nas; rm -rf /' --skip-connection-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"Ungültiger Host"* ]]
}

@test "ungültige Zeitangabe wird abgelehnt" {
  run env RSYNBACKTUX_PASSWORD=geheim \
    "$INSTALLER" --non-interactive --host nas.local --time 25:99 --skip-connection-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"Ungültige Zeitangabe"* ]]
}

@test "dry-run verändert nichts am Dateisystem" {
  run env RSYNBACKTUX_PASSWORD=geheim \
    "$INSTALLER" --dry-run --non-interactive --host nas.local --skip-connection-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  [ ! -e "$CONF_FILE" ]
  [ ! -e "$BACKUP_SCRIPT" ]
  [ ! -e "$PASSFILE" ]
}

@test "Installation legt alle erwarteten Dateien an" {
  run install_sandbox
  [ "$status" -eq 0 ]
  [ -f "$CONF_FILE" ]
  [ -f "$EXCLUDE_FILE" ]
  [ -x "$BACKUP_SCRIPT" ]
  [ -f "$PASSFILE" ]
  [ -f "$LOGFILE" ]
  [ -f "$LOGROTATE_FILE" ]
}

@test "Passwortdatei ist nur für root lesbar" {
  install_sandbox
  [ "$(file_mode "$PASSFILE")" = "600" ]
}

@test "Logfile ist nicht welt-lesbar" {
  install_sandbox
  [ "$(file_mode "$LOGFILE")" = "640" ]
}

@test "Konfiguration enthält die übergebenen Werte" {
  install_sandbox
  grep -q '^SYNO_HOST=192.168.178.5$' "$CONF_FILE"
  grep -q '^SYNO_MODULE=NetBackup$' "$CONF_FILE"
  grep -q '^SYNO_USER=backup$' "$CONF_FILE"
  grep -q '^SYNO_SUBDIR=testserver$' "$CONF_FILE"
}

@test "Sonderzeichen im Passwort überstehen die Installation" {
  RSYNBACKTUX_PASSWORD='a"b$c \d`e' "$INSTALLER" --non-interactive \
    --host nas.local --scheduler none --skip-connection-test --no-run-now
  [ "$(cat "$PASSFILE")" = 'a"b$c \d`e' ]
}

@test "Konfiguration ist auch mit Sonderzeichen wieder einlesbar" {
  RSYNBACKTUX_PASSWORD=geheim "$INSTALLER" --non-interactive \
    --host nas.local --subdir 'server mit leerzeichen' --scheduler none \
    --skip-connection-test --no-run-now
  # shellcheck source=/dev/null
  ( source "$CONF_FILE" && [ "$SYNO_SUBDIR" = "server_mit_leerzeichen" ] )
}

@test "Ausschlussliste enthält je ein Muster pro Zeile" {
  install_sandbox
  grep -qx '/proc/\*' "$EXCLUDE_FILE"
  grep -qx '/sys/\*' "$EXCLUDE_FILE"
  grep -qx '/dev/\*' "$EXCLUDE_FILE"
  grep -qx '/tmp/\*' "$EXCLUDE_FILE"
  # Keine Brace-Listen – rsync expandiert die nicht
  ! grep -q '{' "$EXCLUDE_FILE"
}

@test "Ausschlussliste schließt Passwortdatei und Logfile aus" {
  install_sandbox
  grep -qxF "$PASSFILE" "$EXCLUDE_FILE"
  grep -qxF "$LOGFILE" "$EXCLUDE_FILE"
}

@test "systemd-Units werden mit korrektem OnCalendar geschrieben" {
  install_sandbox --scheduler systemd --time 02:30
  [ -f "$TIMER_UNIT" ]
  [ -f "$SERVICE_UNIT" ]
  grep -q 'OnCalendar=\*-\*-\* 02:30:00' "$TIMER_UNIT"
  grep -q 'Persistent=true' "$TIMER_UNIT"
  grep -qF "ExecStart=${BACKUP_SCRIPT}" "$SERVICE_UNIT"
}

@test "Cron-Ausdruck wird korrekt aus der Uhrzeit gebildet" {
  stub_crontab
  install_sandbox --scheduler cron --time 08:09
  # Führende Nullen dürfen nicht als Oktalzahl interpretiert werden
  grep -q '^9 8 \* \* \* ' "${SANDBOX}/crontab.txt"
}

@test "bestehender Cronjob wird nicht dupliziert" {
  stub_crontab
  install_sandbox --scheduler cron --time 03:00
  install_sandbox --scheduler cron --time 04:00
  [ "$(grep -c 'backup-to-synology.sh' "${SANDBOX}/crontab.txt")" -eq 1 ]
  grep -q '^0 4 \* \* \* ' "${SANDBOX}/crontab.txt"
}

@test "fremde Cron-Einträge bleiben erhalten" {
  stub_crontab
  printf '30 5 * * * /usr/local/bin/etwas-anderes.sh\n' > "${SANDBOX}/crontab.txt"
  install_sandbox --scheduler cron --time 03:00
  grep -q 'etwas-anderes.sh' "${SANDBOX}/crontab.txt"
}

@test "Verbindungstest bricht bei Fehler ab und entfernt die Passwortdatei" {
  stub_rsync 1
  run env RSYNBACKTUX_PASSWORD=geheim "$INSTALLER" --non-interactive \
    --host nas.local --scheduler none --no-run-now
  [ "$status" -ne 0 ]
  [[ "$output" == *"nicht erreichbar"* ]]
  [ ! -e "$PASSFILE" ]
  [ ! -e "$CONF_FILE" ]
}

@test "Verbindungstest prüft auch den Schreibzugriff" {
  RSYNBACKTUX_PASSWORD=geheim "$INSTALLER" --non-interactive \
    --host nas.local --subdir testserver --scheduler none --no-run-now || true
  # Der Schreibtest lädt eine Markierungsdatei in den Zielunterordner hoch
  rsync_args | grep -q '\.rsynbacktux-write-test'
}

@test "interaktiver Ablauf über Standardeingabe funktioniert" {
  run env -u RSYNBACKTUX_PASSWORD -u RSYNC_PASSWORD RSYNBACKTUX_NO_TTY=1 \
    "$INSTALLER" --scheduler none --skip-connection-test <<'ANTWORTEN'
192.168.178.9
Backups
sicherung
webserver
mein-passwort
n
ANTWORTEN
  [ "$status" -eq 0 ]
  grep -q '^SYNO_HOST=192.168.178.9$' "$CONF_FILE"
  grep -q '^SYNO_MODULE=Backups$' "$CONF_FILE"
  grep -q '^SYNO_USER=sicherung$' "$CONF_FILE"
  grep -q '^SYNO_SUBDIR=webserver$' "$CONF_FILE"
  [ "$(cat "$PASSFILE")" = "mein-passwort" ]
}

@test "abgeschnittene Eingabe führt nicht in eine Endlosschleife" {
  # Simuliert "curl | bash": die Standardeingabe ist sofort am Ende.
  run env -u RSYNBACKTUX_PASSWORD -u RSYNC_PASSWORD RSYNBACKTUX_NO_TTY=1 timeout 20 \
    "$INSTALLER" --scheduler none --skip-connection-test </dev/null
  [ "$status" -ne 0 ]
  [ "$status" -ne 124 ]
}

@test "erzeugtes Backup-Script ist syntaktisch gültig" {
  install_sandbox
  run bash -n "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
}
