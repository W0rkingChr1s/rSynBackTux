#!/usr/bin/env bash
# shellcheck shell=bash
#
# rSynBackTux – Deinstallation
#
# Entfernt Zeitsteuerung, Backup-Script und Logrotation. Konfiguration,
# Passwortdatei und Logfile bleiben erhalten, sofern nicht --purge angegeben ist.
#
# https://github.com/W0rkingChr1s/rSynBackTux

set -euo pipefail

RSYNBACKTUX_VERSION="2.2.0"

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

PURGE=false
ASSUME_YES=false
DRY_RUN=false

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARNUNG: %s\n' "$*" >&2; }
die()  { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
rSynBackTux – Deinstallation

Verwendung:
  uninstall-syno-backup.sh [OPTIONEN]

Optionen:
  --purge     Zusätzlich Konfiguration, Passwortdatei und Logfile entfernen
  --yes       Ohne Rückfrage ausführen
  --dry-run   Nur anzeigen, was entfernt würde
  --help      Diese Hilfe anzeigen
  --version   Version ausgeben

Ohne --purge bleiben /etc/rsynbacktux, /root/.rsync_pass und das Logfile
erhalten, sodass eine Neuinstallation die alten Einstellungen vorfindet.
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge)      PURGE=true;      shift ;;
      --yes|-y)     ASSUME_YES=true; shift ;;
      --dry-run)    DRY_RUN=true;    shift ;;
      --help|-h)    usage; exit 0 ;;
      --version|-V) printf 'rSynBackTux %s\n' "$RSYNBACKTUX_VERSION"; exit 0 ;;
      *)
        printf 'FEHLER: Unbekannte Option: %s\n\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
}

require_root() {
  if [[ "$DRY_RUN" == true || -n "$PREFIX" ]]; then
    return
  fi
  if [[ $EUID -ne 0 ]]; then
    die "Bitte als root ausführen (z. B. via sudo)."
  fi
}

confirm() {
  if [[ "$ASSUME_YES" == true || "$DRY_RUN" == true ]]; then
    return 0
  fi
  local answer=""
  printf 'Wirklich entfernen? [j/N]: '
  if [[ -r /dev/tty ]]; then
    read -r answer </dev/tty || answer=""
  else
    read -r answer || answer=""
  fi
  case "$answer" in
    j|J|ja|Ja|y|Y|yes|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

remove_path() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    return
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY RUN] würde entfernen: ${path}"
    return
  fi
  rm -rf "$path"
  log "Entfernt: ${path}"
}

remove_systemd() {
  if [[ -z "$PREFIX" ]] && command -v systemctl >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == true ]]; then
      log "[DRY RUN] würde systemd-Timer stoppen und deaktivieren"
    else
      systemctl disable --now rsynbacktux.timer >/dev/null 2>&1 || true
      systemctl stop rsynbacktux.service >/dev/null 2>&1 || true
    fi
  fi

  remove_path "$TIMER_UNIT"
  remove_path "$SERVICE_UNIT"

  if [[ -z "$PREFIX" && "$DRY_RUN" == false ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
  fi
}

remove_cron() {
  if ! command -v crontab >/dev/null 2>&1; then
    return
  fi
  if ! crontab -l 2>/dev/null | grep -Fq "backup-to-synology.sh"; then
    return
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY RUN] würde Cronjob für backup-to-synology.sh entfernen"
    return
  fi
  crontab -l 2>/dev/null | grep -Fv "backup-to-synology.sh" | crontab - || \
    warn "Cronjob konnte nicht entfernt werden – bitte 'crontab -e' prüfen."
  log "Cronjob entfernt."
}

main() {
  parse_args "$@"
  require_root

  log "=== rSynBackTux ${RSYNBACKTUX_VERSION} – Deinstallation ==="
  log "Es werden entfernt:"
  log "  - systemd-Units bzw. Cronjob"
  log "  - ${BACKUP_SCRIPT}"
  log "  - ${LOGROTATE_FILE}"
  if [[ "$PURGE" == true ]]; then
    log "  - ${CONF_DIR} (Konfiguration und Ausschlussliste)"
    log "  - ${PASSFILE}"
    log "  - ${LOGFILE}"
  else
    log "Erhalten bleiben: ${CONF_FILE}, ${EXCLUDE_FILE}, ${PASSFILE}, ${LOGFILE}"
    log "(mit --purge werden diese ebenfalls entfernt)"
  fi
  log ""

  if ! confirm; then
    log "Abgebrochen."
    return 0
  fi

  remove_systemd
  remove_cron
  remove_path "$BACKUP_SCRIPT"
  remove_path "$LOGROTATE_FILE"
  remove_path "$LOCKFILE"

  if [[ "$PURGE" == true ]]; then
    remove_path "$CONF_DIR"
    remove_path "$PASSFILE"
    remove_path "$LOGFILE"
  fi

  log ""
  log "=== Deinstallation abgeschlossen ==="
  log "Der Datenbestand auf der Synology wurde nicht angetastet."
}

main "$@"
