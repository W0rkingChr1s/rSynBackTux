#!/usr/bin/env bash
# shellcheck shell=bash
#
# Gemeinsame Hilfsfunktionen für die bats-Testsuite.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${REPO_ROOT}/src/install-syno-backup.sh"
UNINSTALLER="${REPO_ROOT}/src/uninstall-syno-backup.sh"

export REPO_ROOT INSTALLER UNINSTALLER

# Legt eine isolierte Umgebung an: eigenes Präfix für alle Zielpfade und ein
# eigenes bin-Verzeichnis für Stub-Programme.
setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  STUB_BIN="${SANDBOX}/bin"
  mkdir -p "$STUB_BIN"
  export SANDBOX STUB_BIN
  export RSYNBACKTUX_PREFIX="${SANDBOX}/root"
  export PATH="${STUB_BIN}:${PATH}"

  CONF_FILE="${RSYNBACKTUX_PREFIX}/etc/rsynbacktux/backup.conf"
  EXCLUDE_FILE="${RSYNBACKTUX_PREFIX}/etc/rsynbacktux/excludes.list"
  BACKUP_SCRIPT="${RSYNBACKTUX_PREFIX}/usr/local/sbin/backup-to-synology.sh"
  PASSFILE="${RSYNBACKTUX_PREFIX}/root/.rsync_pass"
  LOGFILE="${RSYNBACKTUX_PREFIX}/var/log/backup-to-synology.log"
  TIMER_UNIT="${RSYNBACKTUX_PREFIX}/etc/systemd/system/rsynbacktux.timer"
  SERVICE_UNIT="${RSYNBACKTUX_PREFIX}/etc/systemd/system/rsynbacktux.service"
  LOGROTATE_FILE="${RSYNBACKTUX_PREFIX}/etc/logrotate.d/rsynbacktux"
  export CONF_FILE EXCLUDE_FILE BACKUP_SCRIPT PASSFILE LOGFILE
  export TIMER_UNIT SERVICE_UNIT LOGROTATE_FILE
}

teardown_sandbox() {
  if [[ -n "${SANDBOX-}" && -d "$SANDBOX" ]]; then
    rm -rf "$SANDBOX"
  fi
}

# Legt einen rsync-Stub an, der seine Argumente protokolliert und mit dem
# gewünschten Code endet.
stub_rsync() {
  local exit_code="${1:-0}"
  cat > "${STUB_BIN}/rsync" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "${SANDBOX}/rsync-args.txt"
printf 'stub rsync aufgerufen\n'
exit ${exit_code}
STUB
  chmod +x "${STUB_BIN}/rsync"
}

# Legt einen crontab-Stub an, der die geschriebene Tabelle in einer Datei ablegt.
stub_crontab() {
  cat > "${STUB_BIN}/crontab" <<STUB
#!/usr/bin/env bash
if [[ "\${1-}" == "-l" ]]; then
  cat "${SANDBOX}/crontab.txt" 2>/dev/null || exit 1
  exit 0
fi
# Wie das echte crontab: erst vollständig einlesen, dann installieren
tmp="\$(mktemp)"
cat > "\$tmp"
mv "\$tmp" "${SANDBOX}/crontab.txt"
STUB
  chmod +x "${STUB_BIN}/crontab"
}

rsync_args() {
  cat "${SANDBOX}/rsync-args.txt" 2>/dev/null || true
}

# Vollständige, nicht-interaktive Installation in die Sandbox.
install_sandbox() {
  RSYNBACKTUX_PASSWORD='test-passwort' "$INSTALLER" \
    --non-interactive \
    --host 192.168.178.5 \
    --module NetBackup \
    --user backup \
    --subdir testserver \
    --scheduler none \
    --skip-connection-test \
    --no-run-now \
    "$@"
}

file_mode() {
  stat -c '%a' "$1"
}
