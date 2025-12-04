#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

DRY_RUN=false
if [[ "${1-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "[DRY RUN] Installer läuft im Testmodus (keine Änderungen am System)."
fi

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Bitte als root ausführen (z. B. via sudo)." >&2
    exit 1
  fi
}

prompt_nonempty() {
  local var_name="$1"
  local prompt="$2"
  local default="${3-}"

  local value=""
  while [[ -z "${value}" ]]; do
    if [[ -n "$default" ]]; then
      read -r -p "${prompt} [${default}]: " value || true
      value="${value:-$default}"
    else
      read -r -p "${prompt}: " value || true
    fi
    if [[ -z "$value" ]]; then
      echo "Eingabe darf nicht leer sein."
    fi
  done
  printf -v "${var_name}" '%s' "${value}"
}

main() {
  require_root

  echo "=== rSynBackTux – Synology Backup Installer ==="

  DEFAULT_HOST="192.168.178.5"
  DEFAULT_MODULE="NetBackup"
  DEFAULT_USER="backup"
  DEFAULT_SUBDIR="$(hostname -s)"

  local SYNO_HOST SYNO_MODULE SYNO_USER SYNO_SUBDIR RSYNC_PASS

  prompt_nonempty SYNO_HOST  "Synology Host/IP" "${DEFAULT_HOST}"
  prompt_nonempty SYNO_MODULE "rsync Modulname" "${DEFAULT_MODULE}"
  prompt_nonempty SYNO_USER   "rsync Benutzername" "${DEFAULT_USER}"
  prompt_nonempty SYNO_SUBDIR "Unterordner auf NAS für diesen Server" "${DEFAULT_SUBDIR}"

  # Passwort
  while [[ -z "${RSYNC_PASS-}" ]]; do
    printf "Passwort für rsync Benutzer '%s': " "${SYNO_USER}"
    # shellcheck disable=SC2162
    read -rs RSYNC_PASS || true
    echo
    if [[ -z "${RSYNC_PASS}" ]]; then
      echo "Passwort darf nicht leer sein."
    fi
  done

  local PASSFILE="/root/.rsync_pass"
  local BACKUP_SCRIPT="/usr/local/sbin/backup-to-synology.sh"
  local LOGFILE="/var/log/backup-to-synology.log"

  if [[ "${DRY_RUN}" == false ]]; then
    # rsync installieren falls nötig
    if ! command -v rsync >/dev/null 2>&1; then
      echo "rsync nicht gefunden, versuche Installation..."
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y rsync
      elif command -v dnf >/dev/null 2>&1; then
        dnf install -y rsync
      elif command -v yum >/dev/null 2>&1; then
        yum install -y rsync
      elif command -v zypper >/dev/null 2>&1; then
        zypper install -y rsync
      else
        echo "Kein unterstützter Paketmanager gefunden. Bitte rsync manuell installieren." >&2
        exit 1
      fi
    fi

    # Passwortdatei
    printf "%s\n" "${RSYNC_PASS}" > "${PASSFILE}"
    chmod 600 "${PASSFILE}"
    echo "Passwortdatei in ${PASSFILE} angelegt."

    # Backup-Script schreiben
    cat > "${BACKUP_SCRIPT}" <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

SYNO_HOST="${SYNO_HOST}"
SYNO_MODULE="${SYNO_MODULE}"
SYNO_USER="${SYNO_USER}"
SYNO_SUBDIR="${SYNO_SUBDIR}"
PASSFILE="${PASSFILE}"
LOGFILE="${LOGFILE}"

{
  echo "===== \$(date '+%F %T') – Backup gestartet (\$(hostname -s)) ====="

  rsync -aHv --delete \
    --password-file="\${PASSFILE}" \
    --exclude='{/dev/*,/proc/*,/sys/*,/tmp/*,/run/*,/mnt/*,/media/*,/lost+found}' \
    / "\${SYNO_USER}@\${SYNO_HOST}::\${SYNO_MODULE}/\${SYNO_SUBDIR}/"

  echo "===== \$(date '+%F %T') – Backup fertig (\$(hostname -s)) ====="
} >> "\${LOGFILE}" 2>&1
EOF

    chmod +x "${BACKUP_SCRIPT}"
    touch "${LOGFILE}"
    chmod 640 "${LOGFILE}"

    echo "Backup-Script: ${BACKUP_SCRIPT}"
    echo "Logfile:       ${LOGFILE}"
  else
    echo "[DRY RUN] Würde jetzt rsync installieren (falls nötig), Passwortdatei und Backup-Script erzeugen."
  fi

  # Testlauf
  local RUN_NOW
  read -r -p "Jetzt einen Testlauf starten? [j/N]: " RUN_NOW || true
  RUN_NOW="${RUN_NOW:-n}"

  if [[ "${DRY_RUN}" == false && "${RUN_NOW}" =~ ^[JjYy]$ ]]; then
    echo "Starte Test-Backup..."
    "${BACKUP_SCRIPT}"
    echo "Testlauf beendet. (Auszug aus dem Logfile)"
    tail -n 20 "${LOGFILE}" || true
  else
    echo "Kein Testlauf gestartet."
  fi

  # Cronjob
  local SET_CRON
  read -r -p "Cronjob für tägliches Backup um 03:00 einrichten? [J/n]: " SET_CRON || true
  SET_CRON="${SET_CRON:-j}"

  if [[ "${DRY_RUN}" == false && "${SET_CRON}" =~ ^[JjYy]$ ]]; then
    local CRON_EXPR_DEFAULT="0 3 * * *"
    local CRON_EXPR
    read -r -p "Cron-Zeit (Standard: '${CRON_EXPR_DEFAULT}'): " CRON_EXPR || true
    CRON_EXPR="${CRON_EXPR:-$CRON_EXPR_DEFAULT}"

    (crontab -l 2>/dev/null | grep -v "${BACKUP_SCRIPT}" || true; echo "${CRON_EXPR} ${BACKUP_SCRIPT}") | crontab -
    echo "Cronjob eingerichtet: ${CRON_EXPR} ${BACKUP_SCRIPT}"
  else
    echo "Kein Cronjob eingerichtet."
  fi

  echo "=== Installation abgeschlossen. ==="
}

main "$@"