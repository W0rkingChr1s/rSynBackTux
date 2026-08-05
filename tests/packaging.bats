#!/usr/bin/env bats
# Tests für den Paketmodus und den Paketbau (scripts/build-deb.sh)

load helper

setup() {
  setup_sandbox
  stub_rsync 0
}

teardown() {
  teardown_sandbox
}

# --- --emit-package-files ----------------------------------------------------

@test "--emit-package-files legt alle Paketdateien an" {
  run "$INSTALLER" --emit-package-files "${SANDBOX}/stage"
  [ "$status" -eq 0 ]
  [ -x "${SANDBOX}/stage/usr/sbin/rsynbacktux-backup" ]
  [ -f "${SANDBOX}/stage/usr/lib/systemd/system/rsynbacktux.service" ]
  [ -f "${SANDBOX}/stage/usr/lib/systemd/system/rsynbacktux.timer" ]
  [ -f "${SANDBOX}/stage/etc/logrotate.d/rsynbacktux" ]
  [ -f "${SANDBOX}/stage/etc/rsynbacktux/excludes.list" ]
}

@test "--emit-package-files ignoriert RSYNBACKTUX_PREFIX in den Pfaden" {
  # Die Dateien landen im Staging-Verzeichnis, die Pfade darin sind absolut.
  "$INSTALLER" --emit-package-files "${SANDBOX}/stage"
  local runner="${SANDBOX}/stage/usr/sbin/rsynbacktux-backup"
  grep -q 'CONF_FILE="\${RSYNBACKTUX_CONF:-/etc/rsynbacktux/backup.conf}"' "$runner"
  ! grep -q "$RSYNBACKTUX_PREFIX" "$runner"
  ! grep -q "$RSYNBACKTUX_PREFIX" "${SANDBOX}/stage/etc/logrotate.d/rsynbacktux"
}

@test "--emit-package-files verändert nichts am System" {
  "$INSTALLER" --emit-package-files "${SANDBOX}/stage"
  [ ! -e "$CONF_FILE" ]
  [ ! -e "$PASSFILE" ]
  [ ! -e "$BACKUP_SCRIPT" ]
}

@test "--emit-package-files ohne Verzeichnis schlägt fehl" {
  run "$INSTALLER" --emit-package-files ""
  [ "$status" -ne 0 ]
}

@test "mitgelieferte Unit startet den Runner aus dem Paket" {
  "$INSTALLER" --emit-package-files "${SANDBOX}/stage"
  grep -qx 'ExecStart=/usr/sbin/rsynbacktux-backup' \
    "${SANDBOX}/stage/usr/lib/systemd/system/rsynbacktux.service"
}

@test "mitgelieferter Timer hat eine Standardzeit" {
  "$INSTALLER" --emit-package-files "${SANDBOX}/stage"
  grep -q 'OnCalendar=\*-\*-\* 03:00:00' \
    "${SANDBOX}/stage/usr/lib/systemd/system/rsynbacktux.timer"
}

@test "erzeugter Paket-Runner ist syntaktisch gültig" {
  "$INSTALLER" --emit-package-files "${SANDBOX}/stage"
  run bash -n "${SANDBOX}/stage/usr/sbin/rsynbacktux-backup"
  [ "$status" -eq 0 ]
}

# --- Paketmodus (--packaged) -------------------------------------------------

@test "Paketmodus fasst Dateien des Pakets nicht an" {
  stage_package_files
  printf '# von Hand ergaenzt\n' >> "$LOGROTATE_FILE"

  install_sandbox --packaged
  [ -f "$CONF_FILE" ]
  [ -f "$PASSFILE" ]
  # Logrotation gehört dem Paket und bleibt unverändert
  grep -qx '# von Hand ergaenzt' "$LOGROTATE_FILE"
  # Der Runner kommt aus dem Paket, der Installer legt keinen zweiten an
  [ ! -e "${RSYNBACKTUX_PREFIX}/usr/local/sbin/backup-to-synology.sh" ]
}

@test "Paketmodus ohne installiertes Paket bricht mit klarer Meldung ab" {
  run install_sandbox --packaged
  [ "$status" -ne 0 ]
  [[ "$output" == *"Ist das Paket rsynbacktux installiert?"* ]]
}

@test "Paketmodus setzt die Zeit über ein systemd-Drop-in" {
  stage_package_files
  install_sandbox --packaged --scheduler systemd --time 04:15
  local dropin="${RSYNBACKTUX_PREFIX}/etc/systemd/system/rsynbacktux.timer.d/override.conf"
  [ -f "$dropin" ]
  # Leerer Wert zuerst, sonst gälte zusätzlich die Zeit aus der Paket-Unit
  grep -qx 'OnCalendar=' "$dropin"
  grep -qx 'OnCalendar=\*-\*-\* 04:15:00' "$dropin"
  # Die Units selbst gehören dem Paket und werden nicht überschrieben
  [ ! -e "$TIMER_UNIT" ]
  [ ! -e "$SERVICE_UNIT" ]
}

@test "Paketmodus trägt den Paket-Runner in den Cronjob ein" {
  stage_package_files
  stub_crontab
  install_sandbox --packaged --scheduler cron --time 05:30
  grep -q "^30 5 \* \* \* ${RSYNBACKTUX_PREFIX}/usr/sbin/rsynbacktux-backup$" \
    "${SANDBOX}/crontab.txt"
}

@test "Paketmodus überschreibt eine vorhandene Ausschlussliste nicht" {
  stage_package_files
  printf '/eigener/pfad/*\n' > "$EXCLUDE_FILE"
  install_sandbox --packaged
  grep -qx '/eigener/pfad/\*' "$EXCLUDE_FILE"
}

@test "Paketmodus ist über RSYNBACKTUX_PACKAGED aktivierbar" {
  stage_package_files
  run env RSYNBACKTUX_PACKAGED=1 RSYNBACKTUX_PASSWORD='test-passwort' "$INSTALLER" \
    --non-interactive --host 192.168.178.5 --subdir testserver \
    --scheduler none --skip-connection-test --no-run-now
  [ "$status" -eq 0 ]
  [[ "$output" == *"Einrichtung (Paketinstallation)"* ]]
  [ ! -e "${RSYNBACKTUX_PREFIX}/usr/local/sbin/backup-to-synology.sh" ]
}

@test "Aufruf als rsynbacktux-setup aktiviert den Paketmodus" {
  # Im Paket heißt der Installer 'rsynbacktux-setup'; der Name schaltet um.
  stage_package_files
  cp "$INSTALLER" "${STUB_BIN}/rsynbacktux-setup"
  run env RSYNBACKTUX_PASSWORD='test-passwort' "${STUB_BIN}/rsynbacktux-setup" \
    --non-interactive --host 192.168.178.5 --subdir testserver \
    --scheduler none --skip-connection-test --no-run-now
  [ "$status" -eq 0 ]
  [[ "$output" == *"Einrichtung (Paketinstallation)"* ]]
  [ ! -e "${RSYNBACKTUX_PREFIX}/usr/local/sbin/backup-to-synology.sh" ]
}

@test "Dry-Run im Paketmodus weist auf die Paketdateien hin" {
  run env RSYNBACKTUX_PASSWORD=geheim "$INSTALLER" --packaged --dry-run \
    --non-interactive --host nas.local --skip-connection-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"/usr/sbin/rsynbacktux-backup (aus dem Paket)"* ]]
}

# --- Paketbau ----------------------------------------------------------------

@test "build-deb.sh erzeugt ein installierbares Paket" {
  if ! command -v dpkg-deb >/dev/null 2>&1; then
    skip "dpkg-deb nicht verfügbar"
  fi
  run env -u RSYNBACKTUX_PREFIX "${REPO_ROOT}/scripts/build-deb.sh" "${SANDBOX}/dist"
  [ "$status" -eq 0 ]

  local deb="${SANDBOX}/dist/rsynbacktux_$(cat "${REPO_ROOT}/VERSION")-1_all.deb"
  [ -f "$deb" ]

  run dpkg-deb --info "$deb"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Package: rsynbacktux"* ]]
  [[ "$output" == *"Version: $(cat "${REPO_ROOT}/VERSION")-1"* ]]
  [[ "$output" == *"Depends: rsync"* ]]
}

@test "Paket enthält Runner, Setup, Units und Handbuchseiten" {
  if ! command -v dpkg-deb >/dev/null 2>&1; then
    skip "dpkg-deb nicht verfügbar"
  fi
  env -u RSYNBACKTUX_PREFIX "${REPO_ROOT}/scripts/build-deb.sh" "${SANDBOX}/dist" >/dev/null

  local deb="${SANDBOX}/dist/rsynbacktux_$(cat "${REPO_ROOT}/VERSION")-1_all.deb"
  run dpkg-deb --contents "$deb"
  [ "$status" -eq 0 ]
  [[ "$output" == *"./usr/sbin/rsynbacktux-backup"* ]]
  [[ "$output" == *"./usr/sbin/rsynbacktux-setup"* ]]
  [[ "$output" == *"./usr/lib/systemd/system/rsynbacktux.timer"* ]]
  [[ "$output" == *"./usr/share/man/man8/rsynbacktux-setup.8.gz"* ]]
  [[ "$output" == *"./usr/share/doc/rsynbacktux/copyright"* ]]
}

@test "Paketversion folgt der VERSION-Datei" {
  if ! command -v dpkg-deb >/dev/null 2>&1; then
    skip "dpkg-deb nicht verfügbar"
  fi
  run env -u RSYNBACKTUX_PREFIX DEB_REVISION=3 \
    "${REPO_ROOT}/scripts/build-deb.sh" "${SANDBOX}/dist"
  [ "$status" -eq 0 ]
  [ -f "${SANDBOX}/dist/rsynbacktux_$(cat "${REPO_ROOT}/VERSION")-3_all.deb" ]
}
