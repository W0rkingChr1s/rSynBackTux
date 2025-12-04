#!/bin/bash
set -euo pipefail

echo "=== Synology Backup Installer ==="

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen (sudo bash install-syno-backup.sh)." >&2
  exit 1
fi

# --- Eingaben abfragen ---

read -rp "Synology Host/IP: " SYNO_HOST
SYNO_HOST=${SYNO_HOST:-"192.168.178.5"}

read -rp "Synology rsync Modulname [NetBackup]: " SYNO_MODULE
SYNO_MODULE=${SYNO_MODULE:-"NetBackup"}

read -rp "Synology rsync Benutzername [backup]: " SYNO_USER
SYNO_USER=${SYNO_USER:-"backup"}

DEFAULT_SUBDIR="$(hostname -s)"
read -rp "Unterordner auf NAS für diesen Server [${DEFAULT_SUBDIR}]: " SYNO_SUBDIR
SYNO_SUBDIR=${SYNO_SUBDIR:-"$DEFAULT_SUBDIR"}

echo -n "Passwort für rsync Benutzer '${SYNO_USER}': "
read -rs RSYNC_PASS
echo

# --- rsync installieren (falls nötig) ---

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

# --- Passwortdatei anlegen ---

PASSFILE="/root/.rsync_pass"

printf "%s\n" "$RSYNC_PASS" > "$PASSFILE"
chmod 600 "$PASSFILE"

echo "Passwortdatei in $PASSFILE angelegt."

# --- Backup-Script schreiben ---

BACKUP_SCRIPT="/usr/local/sbin/backup-to-synology.sh"
LOGFILE="/var/log/backup-to-synology.log"

cat > "$BACKUP_SCRIPT" <<EOF
#!/bin/bash
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
    --password-file="\$PASSFILE" \
    --exclude='{/dev/*,/proc/*,/sys/*,/tmp/*,/run/*,/mnt/*,/media/*,/lost+found}' \
    /  "\${SYNO_USER}@\${SYNO_HOST}::\${SYNO_MODULE}/\${SYNO_SUBDIR}/"

  echo "===== \$(date '+%F %T') – Backup fertig (\$(hostname -s)) ====="
} >> "\$LOGFILE" 2>&1
EOF

chmod +x "$BACKUP_SCRIPT"
touch "$LOGFILE"
chmod 640 "$LOGFILE"

echo "Backup-Script installiert: $BACKUP_SCRIPT"
echo "Log-Datei: $LOGFILE"

# --- Testlauf anbieten ---

read -rp "Jetzt einen Testlauf starten? [j/N]: " RUN_NOW
RUN_NOW=${RUN_NOW:-"n"}

if [[ "$RUN_NOW" =~ ^[JjYy]$ ]]; then
  echo "Starte Test-Backup..."
  "$BACKUP_SCRIPT"
  echo "Testlauf beendet. Log-Auszug:"
  tail -n 20 "$LOGFILE" || true
fi

# --- Cronjob einrichten ---

read -rp "Cronjob für tägliches Backup um 03:00 einrichten? [J/n]: " SET_CRON
SET_CRON=${SET_CRON:-"j"}

if [[ "$SET_CRON" =~ ^[JjYy]$ ]]; then
  CRON_EXPR_DEFAULT="0 3 * * *"
  read -rp "Cron-Zeit (Standard: '${CRON_EXPR_DEFAULT}'): " CRON_EXPR
  CRON_EXPR=${CRON_EXPR:-"$CRON_EXPR_DEFAULT"}

  # Root-Crontab erweitern
  (crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT" || true; echo "${CRON_EXPR} ${BACKUP_SCRIPT}") | crontab -

  echo "Cronjob eingerichtet:"
  echo "  $CRON_EXPR $BACKUP_SCRIPT"
else
  echo "Kein Cronjob eingerichtet. Du kannst das Script manuell per Root-Crontab einbinden."
fi

echo "=== Installation abgeschlossen. ==="
EOF