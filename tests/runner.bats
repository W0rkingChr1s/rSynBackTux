#!/usr/bin/env bats
# Tests für das vom Installer erzeugte Backup-Script

load helper

setup() {
  setup_sandbox
  stub_rsync 0
  install_sandbox
  # Der Verbindungstest des Installers hat den Argumentmitschnitt gefüllt
  rm -f "${SANDBOX}/rsync-args.txt"
}

teardown() {
  teardown_sandbox
}

@test "Runner überträgt an das konfigurierte Ziel" {
  run "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  rsync_args | grep -qx 'backup@192.168.178.5::NetBackup/testserver/'
}

@test "Runner nutzt die Ausschlussdatei statt einer Brace-Liste" {
  "$BACKUP_SCRIPT"
  rsync_args | grep -qxF -- "--exclude-from=${EXCLUDE_FILE}"
  ! rsync_args | grep -q '{'
}

@test "Runner sichert Besitzrechte numerisch und nutzt die Passwortdatei" {
  "$BACKUP_SCRIPT"
  rsync_args | grep -qx -- '--numeric-ids'
  rsync_args | grep -qx -- '--archive'
  rsync_args | grep -qx -- '--hard-links'
  rsync_args | grep -qxF -- "--password-file=${PASSFILE}"
}

@test "Runner löscht auf dem Ziel nur bei DELETE=true" {
  "$BACKUP_SCRIPT"
  rsync_args | grep -qx -- '--delete'

  rm -f "${SANDBOX}/rsync-args.txt"
  sed -i 's/^DELETE=.*/DELETE="false"/' "$CONF_FILE"
  "$BACKUP_SCRIPT"
  ! rsync_args | grep -qx -- '--delete'
}

@test "ONE_FILE_SYSTEM ist standardmäßig aus" {
  "$BACKUP_SCRIPT"
  ! rsync_args | grep -qx -- '--one-file-system'
}

@test "ONE_FILE_SYSTEM kann in der Konfiguration aktiviert werden" {
  sed -i 's/^ONE_FILE_SYSTEM=.*/ONE_FILE_SYSTEM="true"/' "$CONF_FILE"
  "$BACKUP_SCRIPT"
  rsync_args | grep -qx -- '--one-file-system'
}

@test "Bandbreitenlimit wird übernommen" {
  sed -i 's/^BANDWIDTH_LIMIT=.*/BANDWIDTH_LIMIT="2048"/' "$CONF_FILE"
  "$BACKUP_SCRIPT"
  rsync_args | grep -qx -- '--bwlimit=2048'
}

@test "rsync-Exitcode 24 gilt als Erfolg" {
  stub_rsync 24
  run "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'rsync 24' "$LOGFILE"
}

@test "rsync-Exitcode 23 gilt standardmäßig als Fehler" {
  stub_rsync 23
  run "$BACKUP_SCRIPT"
  [ "$status" -eq 23 ]
  grep -q 'FEHLGESCHLAGEN' "$LOGFILE"
}

@test "rsync-Exitcode 23 kann toleriert werden" {
  stub_rsync 23
  sed -i 's/^TOLERATE_PARTIAL=.*/TOLERATE_PARTIAL="true"/' "$CONF_FILE"
  run "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "echter rsync-Fehler wird durchgereicht" {
  stub_rsync 12
  run "$BACKUP_SCRIPT"
  [ "$status" -eq 12 ]
  [[ "$output" == *"FEHLGESCHLAGEN"* ]]
}

@test "Erfolgsmeldung geht nach stdout, Fehlermeldung nach stderr" {
  run "$BACKUP_SCRIPT"
  [[ "$output" == *"erfolgreich"* ]]

  stub_rsync 5
  run bash -c '"$1" 2>&1 >/dev/null' _ "$BACKUP_SCRIPT"
  [[ "$output" == *"FEHLGESCHLAGEN"* ]]
}

@test "Details landen im Logfile, nicht auf der Konsole" {
  run "$BACKUP_SCRIPT"
  [[ "$output" != *"Backup gestartet"* ]]
  grep -q 'Backup gestartet' "$LOGFILE"
  grep -q 'Backup erfolgreich' "$LOGFILE"
}

@test "fehlende Konfiguration führt zu klarem Fehler" {
  rm -f "$CONF_FILE"
  run "$BACKUP_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Konfiguration nicht lesbar"* ]]
}

@test "fehlende Passwortdatei führt zu klarem Fehler" {
  rm -f "$PASSFILE"
  run "$BACKUP_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Passwortdatei nicht lesbar"* ]]
}

@test "paralleler Lauf wird durch die Sperre verhindert" {
  # Sperre von außen halten und den Runner starten
  local lockfile
  lockfile="$(grep '^LOCKFILE=' "$CONF_FILE" | cut -d= -f2-)"
  mkdir -p "$(dirname "$lockfile")"
  run flock -x "$lockfile" -c "\"$BACKUP_SCRIPT\""
  # flock -n im Runner scheitert, der Lauf endet ohne Fehler und ohne rsync
  [ "$status" -eq 0 ]
  [[ "$output" == *"läuft bereits"* ]]
  [ ! -s "${SANDBOX}/rsync-args.txt" ]
}
