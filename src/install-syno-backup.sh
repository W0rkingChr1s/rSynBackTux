#!/usr/bin/env bash
# shellcheck shell=bash
#
# rSynBackTux – Installer für Synology-Backups von Linux-Servern
#
# Richtet ein:
#   - /etc/rsynbacktux/backup.conf      Konfiguration
#   - /etc/rsynbacktux/excludes.list    Ausschlussliste für rsync
#   - /usr/local/sbin/backup-to-synology.sh  Backup-Runner
#   - /root/.rsync_pass                 Passwortdatei (Modus 600)
#   - /etc/logrotate.d/rsynbacktux      Logrotation
#   - systemd-Timer oder Cronjob        Zeitsteuerung
#
# https://github.com/W0rkingChr1s/rSynBackTux

set -euo pipefail

RSYNBACKTUX_VERSION="2.0.0"

# Präfix für alle Zielpfade. Wird nur von der Testsuite gesetzt, damit eine
# vollständige Installation in ein temporäres Verzeichnis laufen kann.
PREFIX="${RSYNBACKTUX_PREFIX:-}"

CONF_DIR="${PREFIX}/etc/rsynbacktux"
CONF_FILE="${CONF_DIR}/backup.conf"
EXCLUDE_FILE="${CONF_DIR}/excludes.list"
BACKUP_SCRIPT="${PREFIX}/usr/local/sbin/backup-to-synology.sh"
PASSFILE="${PREFIX}/root/.rsync_pass"
LOGFILE="${PREFIX}/var/log/backup-to-synology.log"
LOGROTATE_FILE="${PREFIX}/etc/logrotate.d/rsynbacktux"
SYSTEMD_DIR="${PREFIX}/etc/systemd/system"
SERVICE_UNIT="${SYSTEMD_DIR}/rsynbacktux.service"
TIMER_UNIT="${SYSTEMD_DIR}/rsynbacktux.timer"
LOCKFILE="${PREFIX}/var/lock/rsynbacktux.lock"

# Optionen (per CLI überschreibbar)
OPT_HOST=""
OPT_MODULE=""
OPT_USER=""
OPT_SUBDIR=""
OPT_PASSWORD=""
OPT_PASSWORD_FILE=""
OPT_TIME=""
OPT_ONCALENDAR=""
OPT_CRON=""
OPT_SCHEDULER="auto"
OPT_SOURCE="/"
OPT_ONE_FILE_SYSTEM="false"
NON_INTERACTIVE=false
DRY_RUN=false
SKIP_CONNECTION_TEST=false
RUN_NOW=""

DEFAULT_HOST="192.168.178.5"
DEFAULT_MODULE="NetBackup"
DEFAULT_USER="backup"
DEFAULT_TIME="03:00"

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARNUNG: %s\n' "$*" >&2; }
die()  { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
rSynBackTux – Synology Backup Installer

Verwendung:
  install-syno-backup.sh [OPTIONEN]

Verbindung:
  --host HOST              Synology Host oder IP
  --module NAME            rsync-Modul auf der Synology (Standard: NetBackup)
  --user NAME              rsync-Benutzer (Standard: backup)
  --subdir NAME            Zielunterordner im Modul (Standard: Hostname)
  --password-file DATEI    Datei, die das rsync-Passwort enthält
                           (alternativ Umgebungsvariable RSYNBACKTUX_PASSWORD)

Backup:
  --source PFAD            Quellverzeichnis (Standard: /)
  --one-file-system        Dateisystemgrenzen nicht überschreiten (rsync -x).
                           Achtung: separate Partitionen wie /home oder /var
                           werden dann NICHT mitgesichert.

Zeitsteuerung:
  --scheduler MODUS        auto | systemd | cron | none (Standard: auto)
  --time HH:MM             Startzeit des täglichen Laufs (Standard: 03:00)
  --oncalendar AUSDRUCK    systemd-OnCalendar-Ausdruck (überschreibt --time)
  --cron AUSDRUCK          Cron-Ausdruck (überschreibt --time)

Ablauf:
  --non-interactive        Keine Rückfragen; fehlende Pflichtangaben sind Fehler
  --run-now                Nach der Installation sofort ein Backup starten
  --no-run-now             Kein Testlauf nach der Installation
  --skip-connection-test   Verbindungstest zur Synology überspringen
  --dry-run                Nichts am System verändern, nur anzeigen
  --help                   Diese Hilfe anzeigen
  --version                Version ausgeben

Beispiel (vollautomatisch):
  RSYNBACKTUX_PASSWORD='geheim' ./install-syno-backup.sh --non-interactive \
      --host 192.168.178.5 --module NetBackup --user backup --time 02:30
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host)             OPT_HOST="${2-}";          shift 2 ;;
      --module)           OPT_MODULE="${2-}";        shift 2 ;;
      --user)             OPT_USER="${2-}";          shift 2 ;;
      --subdir)           OPT_SUBDIR="${2-}";        shift 2 ;;
      --password-file)    OPT_PASSWORD_FILE="${2-}"; shift 2 ;;
      --source)           OPT_SOURCE="${2-}";        shift 2 ;;
      --time)             OPT_TIME="${2-}";          shift 2 ;;
      --oncalendar)       OPT_ONCALENDAR="${2-}";    shift 2 ;;
      --cron)             OPT_CRON="${2-}";          shift 2 ;;
      --scheduler)        OPT_SCHEDULER="${2-}";     shift 2 ;;
      --one-file-system)  OPT_ONE_FILE_SYSTEM="true"; shift ;;
      --non-interactive)  NON_INTERACTIVE=true;      shift ;;
      --run-now)          RUN_NOW="yes";             shift ;;
      --no-run-now)       RUN_NOW="no";              shift ;;
      --skip-connection-test) SKIP_CONNECTION_TEST=true; shift ;;
      --dry-run)          DRY_RUN=true;              shift ;;
      --help|-h)          usage; exit 0 ;;
      --version|-V)       printf 'rSynBackTux %s\n' "$RSYNBACKTUX_VERSION"; exit 0 ;;
      *)
        printf 'FEHLER: Unbekannte Option: %s\n\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  case "$OPT_SCHEDULER" in
    auto|systemd|cron|none) ;;
    *) die "Ungültiger Wert für --scheduler: ${OPT_SCHEDULER} (auto|systemd|cron|none)" ;;
  esac
}

require_root() {
  # Im Dry-Run und in der Testsuite (PREFIX gesetzt) wird nichts am System
  # verändert, deshalb sind dort auch keine root-Rechte nötig.
  if [[ "$DRY_RUN" == true || -n "$PREFIX" ]]; then
    return
  fi
  if [[ $EUID -ne 0 ]]; then
    die "Bitte als root ausführen (z. B. via sudo)."
  fi
}

# Liest interaktive Eingaben bevorzugt vom Terminal. Das ist nötig, weil bei
# "curl ... | bash" die Standardeingabe bereits vom Skript selbst belegt ist.
# RSYNBACKTUX_NO_TTY erzwingt das Lesen von der Standardeingabe (Testsuite).
read_input() {
  # -r wird von den Aufrufern über "$@" mitgegeben
  # shellcheck disable=SC2162
  if [[ -z "${RSYNBACKTUX_NO_TTY-}" && -r /dev/tty ]]; then
    read "$@" </dev/tty
  else
    read "$@"
  fi
}

prompt_value() {
  local var_name="$1" prompt="$2" default="${3-}" preset="${4-}"

  if [[ -n "$preset" ]]; then
    printf -v "$var_name" '%s' "$preset"
    return
  fi

  if [[ "$NON_INTERACTIVE" == true ]]; then
    if [[ -n "$default" ]]; then
      printf -v "$var_name" '%s' "$default"
      return
    fi
    die "Pflichtangabe fehlt: ${prompt} (im nicht-interaktiven Modus als Option angeben)"
  fi

  local value="" attempt=0
  while [[ -z "$value" ]]; do
    attempt=$((attempt + 1))
    if [[ "$attempt" -gt 3 ]]; then
      die "Keine Eingabe möglich für: ${prompt}. Bitte die passende Option nutzen (--help)."
    fi
    if [[ -n "$default" ]]; then
      printf '%s [%s]: ' "$prompt" "$default"
      read_input -r value || value=""
      value="${value:-$default}"
    else
      printf '%s: ' "$prompt"
      read_input -r value || value=""
    fi
    if [[ -z "$value" ]]; then
      log "Eingabe darf nicht leer sein."
    fi
  done
  printf -v "$var_name" '%s' "$value"
}

prompt_password() {
  # 1. Vorrang: Umgebungsvariablen
  if [[ -n "${RSYNBACKTUX_PASSWORD-}" ]]; then
    OPT_PASSWORD="$RSYNBACKTUX_PASSWORD"
    return
  fi
  if [[ -n "${RSYNC_PASSWORD-}" ]]; then
    OPT_PASSWORD="$RSYNC_PASSWORD"
    return
  fi
  # 2. Passwortdatei
  if [[ -n "$OPT_PASSWORD_FILE" ]]; then
    [[ -r "$OPT_PASSWORD_FILE" ]] || die "Passwortdatei nicht lesbar: ${OPT_PASSWORD_FILE}"
    OPT_PASSWORD="$(head -n 1 "$OPT_PASSWORD_FILE")"
    [[ -n "$OPT_PASSWORD" ]] || die "Passwortdatei ist leer: ${OPT_PASSWORD_FILE}"
    return
  fi
  # 3. Interaktive Abfrage
  if [[ "$NON_INTERACTIVE" == true ]]; then
    die "Kein Passwort angegeben. Bitte --password-file nutzen oder RSYNBACKTUX_PASSWORD setzen."
  fi

  local attempt=0
  while [[ -z "$OPT_PASSWORD" ]]; do
    attempt=$((attempt + 1))
    if [[ "$attempt" -gt 3 ]]; then
      die "Keine Passworteingabe möglich. Bitte --password-file nutzen oder RSYNBACKTUX_PASSWORD setzen."
    fi
    printf "Passwort für rsync-Benutzer '%s': " "$OPT_USER"
    read_input -rs OPT_PASSWORD || OPT_PASSWORD=""
    printf '\n'
    if [[ -z "$OPT_PASSWORD" ]]; then
      log "Passwort darf nicht leer sein."
    fi
  done
}

prompt_yes_no() {
  local prompt="$1" default="$2" preset="${3-}"
  local answer=""

  if [[ -n "$preset" ]]; then
    [[ "$preset" == "yes" ]]
    return
  fi
  if [[ "$NON_INTERACTIVE" == true ]]; then
    [[ "$default" == "yes" ]]
    return
  fi

  local hint="[j/N]"
  if [[ "$default" == "yes" ]]; then
    hint="[J/n]"
  fi
  printf '%s %s: ' "$prompt" "$hint"
  read_input -r answer || answer=""
  answer="${answer:-$default}"
  case "$answer" in
    yes|Yes|y|Y|j|J|ja|Ja) return 0 ;;
    *) return 1 ;;
  esac
}

sanitize_name() {
  printf '%s' "$1" | tr -c 'a-zA-Z0-9_.-' '_'
}

validate_inputs() {
  [[ "$OPT_HOST"   =~ ^[A-Za-z0-9_.:-]+$ ]] || die "Ungültiger Host: ${OPT_HOST}"
  [[ "$OPT_MODULE" =~ ^[A-Za-z0-9_.-]+$ ]]  || die "Ungültiger Modulname: ${OPT_MODULE}"
  [[ "$OPT_USER"   =~ ^[A-Za-z0-9_.-]+$ ]]  || die "Ungültiger Benutzername: ${OPT_USER}"
  [[ "$OPT_SUBDIR" =~ ^[A-Za-z0-9_./-]+$ ]] || die "Ungültiger Unterordner: ${OPT_SUBDIR}"
  [[ "$OPT_SOURCE" == /* ]]                 || die "Quellpfad muss absolut sein: ${OPT_SOURCE}"
  if [[ -n "$OPT_TIME" ]] && [[ ! "$OPT_TIME" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
    die "Ungültige Zeitangabe: ${OPT_TIME} (erwartet HH:MM)"
  fi
}

# Wählt die Zeitsteuerung: systemd bevorzugt, sonst cron.
detect_scheduler() {
  case "$OPT_SCHEDULER" in
    none|systemd|cron)
      printf '%s' "$OPT_SCHEDULER"
      return
      ;;
  esac

  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    printf 'systemd'
  elif command -v crontab >/dev/null 2>&1; then
    printf 'cron'
  else
    printf 'none'
  fi
}

install_rsync() {
  if command -v rsync >/dev/null 2>&1; then
    return
  fi
  log "rsync nicht gefunden, versuche Installation..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y rsync
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y rsync
  elif command -v yum >/dev/null 2>&1; then
    yum install -y rsync
  elif command -v zypper >/dev/null 2>&1; then
    zypper install -y --no-confirm rsync
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm rsync
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache rsync
  else
    die "Kein unterstützter Paketmanager gefunden. Bitte rsync manuell installieren."
  fi
}

write_passfile() {
  install -d -m 700 "$(dirname "$PASSFILE")"
  # Erst mit restriktiven Rechten anlegen, dann befüllen – so ist das Passwort
  # zu keinem Zeitpunkt für andere Benutzer lesbar.
  install -m 600 /dev/null "$PASSFILE"
  printf '%s\n' "$OPT_PASSWORD" > "$PASSFILE"
  log "Passwortdatei angelegt: ${PASSFILE}"
}

write_excludes() {
  install -d -m 755 "$CONF_DIR"
  cat > "$EXCLUDE_FILE" <<EXCLUDES
# rSynBackTux – Ausschlussliste für rsync (--exclude-from)
# Ein Muster pro Zeile. Zeilen mit '#' sind Kommentare.
# Muster mit führendem '/' sind relativ zum Quellverzeichnis verankert.

# Pseudo- und Laufzeit-Dateisysteme
/dev/*
/proc/*
/sys/*
/run/*
/tmp/*
/var/tmp/*

# Mountpoints für Wechselmedien und Netzlaufwerke
/mnt/*
/media/*
/lost+found

# Swap
/swapfile
/swap.img
/swap/*

# rSynBackTux selbst – das Passwort gehört nicht auf die NAS
${PASSFILE}
${LOGFILE}
${LOGFILE}.*

# Caches, die sich jederzeit neu erzeugen lassen
/var/cache/apt/archives/*.deb
/var/cache/pacman/pkg/*
/var/lib/lxcfs/*
EXCLUDES
  chmod 644 "$EXCLUDE_FILE"
  log "Ausschlussliste angelegt: ${EXCLUDE_FILE}"
}

write_config() {
  install -d -m 755 "$CONF_DIR"
  {
    printf '# rSynBackTux – Konfiguration (wird vom Backup-Runner eingelesen)\n'
    printf '# Änderungen werden beim nächsten Lauf übernommen.\n\n'
    printf 'SYNO_HOST=%q\n'    "$OPT_HOST"
    printf 'SYNO_MODULE=%q\n'  "$OPT_MODULE"
    printf 'SYNO_USER=%q\n'    "$OPT_USER"
    printf 'SYNO_SUBDIR=%q\n'  "$OPT_SUBDIR"
    printf 'SOURCE=%q\n'       "$OPT_SOURCE"
    printf 'PASSFILE=%q\n'     "$PASSFILE"
    printf 'LOGFILE=%q\n'      "$LOGFILE"
    printf 'EXCLUDE_FILE=%q\n' "$EXCLUDE_FILE"
    printf 'LOCKFILE=%q\n'     "$LOCKFILE"
    printf '\n# Dateisystemgrenzen nicht überschreiten (rsync -x).\n'
    printf '# true schließt separate Partitionen wie /home oder /var aus!\n'
    printf 'ONE_FILE_SYSTEM=%q\n' "$OPT_ONE_FILE_SYSTEM"
    printf '\n# Auf dem Ziel löschen, was auf der Quelle nicht mehr existiert\n'
    printf 'DELETE="true"\n'
    printf '\n# ACLs und erweiterte Attribute mitsichern (kann auf der NAS Probleme machen)\n'
    printf 'PRESERVE_ACLS="false"\n'
    printf '\n# Jede übertragene Datei einzeln protokollieren (macht das Log sehr groß)\n'
    printf 'VERBOSE="false"\n'
    printf '\n# Abbruch durch nicht lesbare Dateien (rsync-Code 23) als Warnung werten\n'
    printf 'TOLERATE_PARTIAL="false"\n'
    printf '\n# Bandbreitenlimit in KB/s, leer = unbegrenzt\n'
    printf 'BANDWIDTH_LIMIT=""\n'
    printf '\n# I/O-Timeout in Sekunden\n'
    printf 'RSYNC_TIMEOUT="600"\n'
    printf '\n# Netzwerk-Mounts (NFS/CIFS/SSHFS) zur Laufzeit automatisch ausschließen\n'
    printf 'EXCLUDE_REMOTE_MOUNTS="true"\n'
  } > "$CONF_FILE"
  chmod 644 "$CONF_FILE"
  log "Konfiguration angelegt: ${CONF_FILE}"
}

write_backup_script() {
  install -d -m 755 "$(dirname "$BACKUP_SCRIPT")"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# shellcheck shell=bash'
    printf '%s\n' '#'
    printf '# rSynBackTux Backup-Runner %s\n' "$RSYNBACKTUX_VERSION"
    printf '%s\n' '# Automatisch erzeugt – Anpassungen gehören in die Konfiguration:'
    printf '#   %s\n' "$CONF_FILE"
    printf '%s\n' ''
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' ''
    # Die Expansion soll erst im erzeugten Script stattfinden, nicht hier
    # shellcheck disable=SC2016
    printf 'CONF_FILE="${RSYNBACKTUX_CONF:-%s}"\n' "$CONF_FILE"

    cat <<'RUNNER'

if [[ ! -r "$CONF_FILE" ]]; then
  printf 'FEHLER: Konfiguration nicht lesbar: %s\n' "$CONF_FILE" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$CONF_FILE"

: "${SYNO_HOST:?SYNO_HOST fehlt in der Konfiguration}"
: "${SYNO_MODULE:?SYNO_MODULE fehlt in der Konfiguration}"
: "${SYNO_USER:?SYNO_USER fehlt in der Konfiguration}"
: "${SYNO_SUBDIR:?SYNO_SUBDIR fehlt in der Konfiguration}"
: "${PASSFILE:?PASSFILE fehlt in der Konfiguration}"
: "${LOGFILE:?LOGFILE fehlt in der Konfiguration}"

SOURCE="${SOURCE:-/}"
EXCLUDE_FILE="${EXCLUDE_FILE:-}"
LOCKFILE="${LOCKFILE:-/var/lock/rsynbacktux.lock}"
ONE_FILE_SYSTEM="${ONE_FILE_SYSTEM:-false}"
DELETE="${DELETE:-true}"
PRESERVE_ACLS="${PRESERVE_ACLS:-false}"
VERBOSE="${VERBOSE:-false}"
TOLERATE_PARTIAL="${TOLERATE_PARTIAL:-false}"
BANDWIDTH_LIMIT="${BANDWIDTH_LIMIT:-}"
RSYNC_TIMEOUT="${RSYNC_TIMEOUT:-600}"
EXCLUDE_REMOTE_MOUNTS="${EXCLUDE_REMOTE_MOUNTS:-true}"

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
TARGET="${SYNO_USER}@${SYNO_HOST}::${SYNO_MODULE}/${SYNO_SUBDIR}/"

if [[ ! -r "$PASSFILE" ]]; then
  printf 'FEHLER: Passwortdatei nicht lesbar: %s\n' "$PASSFILE" >&2
  exit 1
fi

# Nur genau ein Backup gleichzeitig. Ohne flock läuft das Backup weiter,
# dann allerdings ohne Schutz vor Parallelläufen.
if command -v flock >/dev/null 2>&1; then
  mkdir -p "$(dirname "$LOCKFILE")" 2>/dev/null || true
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    printf 'Backup läuft bereits (Sperre: %s) – Abbruch.\n' "$LOCKFILE" >&2
    exit 0
  fi
fi

build_rsync_args() {
  RSYNC_ARGS=(--archive --hard-links --numeric-ids --human-readable)
  RSYNC_ARGS+=(--password-file="$PASSFILE")
  RSYNC_ARGS+=(--timeout="$RSYNC_TIMEOUT" --contimeout=30)

  if [[ "$VERBOSE" == "true" ]]; then
    RSYNC_ARGS+=(--verbose)
  else
    RSYNC_ARGS+=(--info=stats2)
  fi

  [[ "$DELETE" == "true" ]] && RSYNC_ARGS+=(--delete --delete-delay)
  [[ "$ONE_FILE_SYSTEM" == "true" ]] && RSYNC_ARGS+=(--one-file-system)
  [[ "$PRESERVE_ACLS" == "true" ]] && RSYNC_ARGS+=(--acls --xattrs)
  [[ -n "$BANDWIDTH_LIMIT" ]] && RSYNC_ARGS+=(--bwlimit="$BANDWIDTH_LIMIT")
  [[ -n "$EXCLUDE_FILE" && -r "$EXCLUDE_FILE" ]] && RSYNC_ARGS+=(--exclude-from="$EXCLUDE_FILE")

  # Netzwerk-Mounts zur Laufzeit ausschließen. Verhindert unter anderem, dass
  # ein eingehängtes NAS-Share in sich selbst gesichert wird.
  if [[ "$EXCLUDE_REMOTE_MOUNTS" == "true" && -r /proc/mounts ]]; then
    local mountpoint fstype
    while read -r _ mountpoint fstype _; do
      case "$fstype" in
        nfs|nfs4|cifs|smbfs|smb3|sshfs|fuse.sshfs|glusterfs|ceph)
          # Oktal-Escapes aus /proc/mounts auflösen (z. B. \040 für Leerzeichen)
          mountpoint="$(printf '%b' "$mountpoint")"
          [[ "$mountpoint" == "/" ]] && continue
          RSYNC_ARGS+=(--exclude="${mountpoint}/")
          printf 'Netzwerk-Mount ausgeschlossen: %s (%s)\n' "$mountpoint" "$fstype"
          ;;
      esac
    done < /proc/mounts
  fi
}

run_backup() {
  local started ended rc=0
  started="$(date '+%F %T')"

  printf '===== %s – Backup gestartet (%s) =====\n' "$started" "$HOSTNAME_SHORT"
  printf 'Quelle: %s\n' "$SOURCE"
  printf 'Ziel:   %s\n' "$TARGET"

  build_rsync_args

  rsync "${RSYNC_ARGS[@]}" "$SOURCE" "$TARGET" || rc=$?

  ended="$(date '+%F %T')"

  case "$rc" in
    0)
      printf '===== %s – Backup erfolgreich (%s) =====\n' "$ended" "$HOSTNAME_SHORT"
      ;;
    24)
      # Dateien sind während der Übertragung verschwunden. Auf einem laufenden
      # System ist das normal und kein Fehler.
      printf '===== %s – Backup erfolgreich, einzelne Dateien verschwanden während des Laufs (rsync 24) =====\n' "$ended"
      rc=0
      ;;
    23)
      if [[ "$TOLERATE_PARTIAL" == "true" ]]; then
        printf '===== %s – Backup mit Warnungen: nicht alle Dateien übertragen (rsync 23) =====\n' "$ended"
        rc=0
      else
        printf '===== %s – Backup FEHLGESCHLAGEN: nicht alle Dateien übertragen (rsync 23) =====\n' "$ended"
      fi
      ;;
    *)
      printf '===== %s – Backup FEHLGESCHLAGEN (rsync-Exitcode %s) =====\n' "$ended" "$rc"
      ;;
  esac

  return "$rc"
}

mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
RC=0
run_backup >> "$LOGFILE" 2>&1 || RC=$?

# Kurzmeldung nach stdout/stderr: landet im systemd-Journal bzw. bei cron nur
# im Fehlerfall in der Mail.
if [[ "$RC" -eq 0 ]]; then
  printf 'rSynBackTux: Backup nach %s erfolgreich.\n' "$TARGET"
else
  printf 'rSynBackTux: Backup nach %s FEHLGESCHLAGEN (Exitcode %s). Details: %s\n' \
    "$TARGET" "$RC" "$LOGFILE" >&2
fi

exit "$RC"
RUNNER
  } > "$BACKUP_SCRIPT"

  chmod 755 "$BACKUP_SCRIPT"
  log "Backup-Script angelegt: ${BACKUP_SCRIPT}"
}

write_logfile() {
  install -d -m 755 "$(dirname "$LOGFILE")"
  if [[ ! -f "$LOGFILE" ]]; then
    install -m 640 /dev/null "$LOGFILE"
  fi
  chmod 640 "$LOGFILE"
  log "Logfile: ${LOGFILE}"
}

write_logrotate() {
  if [[ ! -d "$(dirname "$LOGROTATE_FILE")" ]] && [[ -z "$PREFIX" ]]; then
    warn "logrotate scheint nicht installiert zu sein – Logrotation wird übersprungen."
    return
  fi
  install -d -m 755 "$(dirname "$LOGROTATE_FILE")"
  cat > "$LOGROTATE_FILE" <<ROTATE
${LOGFILE} {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
ROTATE
  chmod 644 "$LOGROTATE_FILE"
  log "Logrotation eingerichtet: ${LOGROTATE_FILE}"
}

setup_systemd() {
  local oncalendar="$1"

  install -d -m 755 "$SYSTEMD_DIR"

  cat > "$SERVICE_UNIT" <<SERVICE
[Unit]
Description=rSynBackTux – Backup auf Synology NAS
Documentation=https://github.com/W0rkingChr1s/rSynBackTux
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BACKUP_SCRIPT}
Nice=10
IOSchedulingClass=idle
SERVICE

  cat > "$TIMER_UNIT" <<TIMER
[Unit]
Description=rSynBackTux – geplanter Backup-Lauf
Documentation=https://github.com/W0rkingChr1s/rSynBackTux

[Timer]
OnCalendar=${oncalendar}
Persistent=true
RandomizedDelaySec=300
Unit=rsynbacktux.service

[Install]
WantedBy=timers.target
TIMER

  chmod 644 "$SERVICE_UNIT" "$TIMER_UNIT"

  if [[ -z "$PREFIX" ]]; then
    systemctl daemon-reload
    systemctl enable --now rsynbacktux.timer
    log "systemd-Timer aktiviert (OnCalendar=${oncalendar})."
    log "Status prüfen mit: systemctl list-timers rsynbacktux.timer"
  else
    log "systemd-Units geschrieben (OnCalendar=${oncalendar})."
  fi
}

setup_cron() {
  local cron_expr="$1"

  if ! command -v crontab >/dev/null 2>&1; then
    warn "crontab nicht gefunden – es wurde keine Zeitsteuerung eingerichtet."
    warn "Backup manuell starten mit: ${BACKUP_SCRIPT}"
    return
  fi

  (crontab -l 2>/dev/null | grep -Fv "$BACKUP_SCRIPT" || true; \
    printf '%s %s\n' "$cron_expr" "$BACKUP_SCRIPT") | crontab -
  log "Cronjob eingerichtet: ${cron_expr} ${BACKUP_SCRIPT}"
}

# Prüft Erreichbarkeit, Zugangsdaten und Schreibrechte im Zielordner.
test_connection() {
  log "Verbindung zur Synology wird geprüft..."

  if ! rsync --list-only --contimeout=15 --password-file="$PASSFILE" \
      "${OPT_USER}@${OPT_HOST}::${OPT_MODULE}/" >/dev/null 2>&1; then
    printf 'FEHLER: Synology nicht erreichbar oder Zugangsdaten ungültig.\n' >&2
    printf 'Bitte Host, Modulname, Benutzer und Passwort prüfen.\n' >&2
    return 1
  fi
  log "Anmeldung am Modul '${OPT_MODULE}' erfolgreich."

  # Schreibtest: eine Markierungsdatei hochladen und wieder entfernen.
  local tmpdir marker
  tmpdir="$(mktemp -d)"
  marker=".rsynbacktux-write-test"
  : > "${tmpdir}/${marker}"

  if ! rsync --archive --contimeout=15 --password-file="$PASSFILE" \
      "${tmpdir}/${marker}" \
      "${OPT_USER}@${OPT_HOST}::${OPT_MODULE}/${OPT_SUBDIR}/" >/dev/null 2>&1; then
    rm -rf "$tmpdir"
    printf 'FEHLER: Kein Schreibzugriff auf %s/%s.\n' "$OPT_MODULE" "$OPT_SUBDIR" >&2
    printf 'Bitte die Berechtigungen des rsync-Benutzers auf der Synology prüfen.\n' >&2
    return 1
  fi

  # Markierung wieder aufräumen: Ein leeres Verzeichnis mit --delete spiegeln,
  # dabei über die Filter nur genau diese eine Datei zur Löschung freigeben.
  rm -f "${tmpdir}/${marker}"
  if ! rsync --archive --delete --contimeout=15 --password-file="$PASSFILE" \
      --include="$marker" --exclude='*' \
      "${tmpdir}/" \
      "${OPT_USER}@${OPT_HOST}::${OPT_MODULE}/${OPT_SUBDIR}/" >/dev/null 2>&1; then
    warn "Testdatei '${marker}' konnte nicht entfernt werden – bitte auf der NAS manuell löschen."
  fi
  rm -rf "$tmpdir"

  log "Schreibzugriff auf ${OPT_MODULE}/${OPT_SUBDIR} bestätigt."
  return 0
}

summary() {
  local scheduler="$1" schedule="$2"
  log ""
  log "=== Installation abgeschlossen ==="
  log "Konfiguration:  ${CONF_FILE}"
  log "Ausschlüsse:    ${EXCLUDE_FILE}"
  log "Backup-Script:  ${BACKUP_SCRIPT}"
  log "Logfile:        ${LOGFILE}"
  log "Ziel:           ${OPT_USER}@${OPT_HOST}::${OPT_MODULE}/${OPT_SUBDIR}/"
  case "$scheduler" in
    systemd) log "Zeitsteuerung:  systemd-Timer (${schedule})" ;;
    cron)    log "Zeitsteuerung:  Cronjob (${schedule})" ;;
    *)       log "Zeitsteuerung:  keine – Backup manuell starten" ;;
  esac
}

main() {
  parse_args "$@"
  require_root

  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY RUN] Installer läuft im Testmodus – es wird nichts am System verändert."
  fi

  log "=== rSynBackTux ${RSYNBACKTUX_VERSION} – Synology Backup Installer ==="

  local default_subdir
  default_subdir="$(sanitize_name "$(hostname -s 2>/dev/null || hostname)")"

  prompt_value OPT_HOST   "Synology Host/IP"                    "$DEFAULT_HOST"   "$OPT_HOST"
  prompt_value OPT_MODULE "rsync-Modulname"                     "$DEFAULT_MODULE" "$OPT_MODULE"
  prompt_value OPT_USER   "rsync-Benutzername"                  "$DEFAULT_USER"   "$OPT_USER"
  prompt_value OPT_SUBDIR "Unterordner auf der NAS"             "$default_subdir" "$OPT_SUBDIR"
  prompt_password

  OPT_SUBDIR="$(sanitize_name "$OPT_SUBDIR")"
  validate_inputs

  local scheduler oncalendar cron_expr schedule_label
  scheduler="$(detect_scheduler)"

  if [[ "$scheduler" != "none" && -z "$OPT_TIME" && -z "$OPT_ONCALENDAR" && -z "$OPT_CRON" ]]; then
    prompt_value OPT_TIME "Uhrzeit für das tägliche Backup (HH:MM)" "$DEFAULT_TIME" ""
  fi
  OPT_TIME="${OPT_TIME:-$DEFAULT_TIME}"
  validate_inputs

  oncalendar="${OPT_ONCALENDAR:-*-*-* ${OPT_TIME}:00}"
  if [[ -n "$OPT_CRON" ]]; then
    cron_expr="$OPT_CRON"
  else
    local hh mm
    hh="${OPT_TIME%%:*}"
    mm="${OPT_TIME##*:}"
    # 10# erzwingt Dezimalinterpretation, sonst wäre "08" eine ungültige Oktalzahl
    cron_expr="$((10#$mm)) $((10#$hh)) * * *"
  fi

  case "$scheduler" in
    systemd) schedule_label="$oncalendar" ;;
    cron)    schedule_label="$cron_expr" ;;
    *)       schedule_label="-" ;;
  esac

  if [[ "$DRY_RUN" == true ]]; then
    log ""
    log "[DRY RUN] Es würden folgende Aktionen ausgeführt:"
    log "  - rsync installieren (falls nicht vorhanden)"
    log "  - Passwortdatei anlegen:   ${PASSFILE}"
    log "  - Konfiguration anlegen:   ${CONF_FILE}"
    log "  - Ausschlussliste anlegen: ${EXCLUDE_FILE}"
    log "  - Backup-Script anlegen:   ${BACKUP_SCRIPT}"
    log "  - Logfile anlegen:         ${LOGFILE}"
    log "  - Logrotation einrichten:  ${LOGROTATE_FILE}"
    log "  - Ziel:                    ${OPT_USER}@${OPT_HOST}::${OPT_MODULE}/${OPT_SUBDIR}/"
    log "  - Zeitsteuerung:           ${scheduler} (${schedule_label})"
    log ""
    log "[DRY RUN] Beendet – keine Änderungen vorgenommen."
    return 0
  fi

  install_rsync
  write_passfile

  if [[ "$SKIP_CONNECTION_TEST" == false ]]; then
    if ! test_connection; then
      rm -f "$PASSFILE"
      die "Installation abgebrochen. Passwortdatei wurde wieder entfernt."
    fi
  else
    log "Verbindungstest übersprungen (--skip-connection-test)."
  fi

  write_excludes
  write_config
  write_backup_script
  write_logfile
  write_logrotate

  case "$scheduler" in
    systemd) setup_systemd "$oncalendar" ;;
    cron)    setup_cron "$cron_expr" ;;
    none)    log "Keine Zeitsteuerung eingerichtet (--scheduler none)." ;;
  esac

  if prompt_yes_no "Jetzt einen Testlauf starten?" "no" "$RUN_NOW"; then
    log "Starte Test-Backup..."
    if "$BACKUP_SCRIPT"; then
      log "Testlauf erfolgreich."
    else
      warn "Testlauf fehlgeschlagen – siehe ${LOGFILE}."
    fi
    log "Auszug aus dem Logfile:"
    tail -n 20 "$LOGFILE" || true
  else
    log "Kein Testlauf gestartet."
  fi

  summary "$scheduler" "$schedule_label"
}

main "$@"
