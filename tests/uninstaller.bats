#!/usr/bin/env bats
# Tests für src/uninstall-syno-backup.sh

load helper

setup() {
  setup_sandbox
  stub_rsync 0
  install_sandbox --scheduler systemd --time 03:00
}

teardown() {
  teardown_sandbox
}

@test "--help wird ausgegeben und endet mit 0" {
  run "$UNINSTALLER" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--purge"* ]]
}

@test "unbekannte Option endet mit Exitcode 2" {
  run "$UNINSTALLER" --gibtsnicht
  [ "$status" -eq 2 ]
}

@test "dry-run entfernt nichts" {
  run "$UNINSTALLER" --dry-run
  [ "$status" -eq 0 ]
  [ -x "$BACKUP_SCRIPT" ]
  [ -f "$TIMER_UNIT" ]
}

@test "Deinstallation entfernt Script, Units und Logrotation" {
  run "$UNINSTALLER" --yes
  [ "$status" -eq 0 ]
  [ ! -e "$BACKUP_SCRIPT" ]
  [ ! -e "$TIMER_UNIT" ]
  [ ! -e "$SERVICE_UNIT" ]
  [ ! -e "$LOGROTATE_FILE" ]
}

@test "ohne --purge bleiben Konfiguration, Passwort und Log erhalten" {
  "$UNINSTALLER" --yes
  [ -f "$CONF_FILE" ]
  [ -f "$EXCLUDE_FILE" ]
  [ -f "$PASSFILE" ]
  [ -f "$LOGFILE" ]
}

@test "--purge entfernt auch Konfiguration, Passwort und Log" {
  run "$UNINSTALLER" --yes --purge
  [ "$status" -eq 0 ]
  [ ! -e "$CONF_FILE" ]
  [ ! -e "$EXCLUDE_FILE" ]
  [ ! -e "$PASSFILE" ]
  [ ! -e "$LOGFILE" ]
}

@test "Deinstallation ist wiederholbar" {
  "$UNINSTALLER" --yes --purge
  run "$UNINSTALLER" --yes --purge
  [ "$status" -eq 0 ]
}

@test "Cronjob wird entfernt, fremde Einträge bleiben" {
  stub_crontab
  printf '30 5 * * * /usr/local/bin/etwas-anderes.sh\n' > "${SANDBOX}/crontab.txt"
  install_sandbox --scheduler cron --time 03:00
  run "$UNINSTALLER" --yes
  [ "$status" -eq 0 ]
  ! grep -q 'backup-to-synology.sh' "${SANDBOX}/crontab.txt"
  grep -q 'etwas-anderes.sh' "${SANDBOX}/crontab.txt"
}
