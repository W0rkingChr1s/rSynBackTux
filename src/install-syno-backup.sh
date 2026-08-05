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

RSYNBACKTUX_VERSION="2.2.0"

# Präfix für alle Zielpfade. Wird nur von der Testsuite gesetzt, damit eine
# vollständige Installation in ein temporäres Verzeichnis laufen kann.
PREFIX="${RSYNBACKTUX_PREFIX:-}"

# Paketmodus. Stammt die Software aus einem Distributionspaket (.deb), dann
# gehören Backup-Runner, systemd-Units und Logrotation dem Paketmanager. Der
# Installer schreibt dann nur noch Konfiguration, Passwortdatei und
# Zeitsteuerung. Aktiv, wenn das Script unter dem Namen 'rsynbacktux-setup'
# aufgerufen wird (so heißt es im Paket), per --packaged oder per
# RSYNBACKTUX_PACKAGED=1.
PACKAGED=false
if [[ "$(basename -- "$0")" == "rsynbacktux-setup" || -n "${RSYNBACKTUX_PACKAGED-}" ]]; then
  PACKAGED=true
fi

# Staging-Verzeichnis für den Paketbau (--emit-package-files), analog zu
# DESTDIR bei 'make install'. Leer bedeutet: direkt ins laufende System.
DESTDIR=""
EMIT_DIR=""

CONF_DIR=""
CONF_FILE=""
EXCLUDE_FILE=""
BACKUP_SCRIPT=""
PASSFILE=""
LOGFILE=""
LOGROTATE_FILE=""
SYSTEMD_DIR=""
UNIT_DIR=""
SERVICE_UNIT=""
TIMER_UNIT=""
DROPIN_DIR=""
DROPIN_FILE=""
LOCKFILE=""

# Setzt alle Zielpfade aus PREFIX und Paketmodus. Wird nach dem Parsen der
# Optionen aufgerufen, weil --packaged die Pfade beeinflusst.
compute_paths() {
  CONF_DIR="${PREFIX}/etc/rsynbacktux"
  CONF_FILE="${CONF_DIR}/backup.conf"
  EXCLUDE_FILE="${CONF_DIR}/excludes.list"
  PASSFILE="${PREFIX}/root/.rsync_pass"
  LOGFILE="${PREFIX}/var/log/backup-to-synology.log"
  LOGROTATE_FILE="${PREFIX}/etc/logrotate.d/rsynbacktux"
  LOCKFILE="${PREFIX}/var/lock/rsynbacktux.lock"

  SYSTEMD_DIR="${PREFIX}/etc/systemd/system"
  DROPIN_DIR="${SYSTEMD_DIR}/rsynbacktux.timer.d"
  DROPIN_FILE="${DROPIN_DIR}/override.conf"

  if [[ "$PACKAGED" == true ]]; then
    # Vom Paket mitgelieferte Dateien
    BACKUP_SCRIPT="${PREFIX}/usr/sbin/rsynbacktux-backup"
    UNIT_DIR="${PREFIX}/usr/lib/systemd/system"
  else
    BACKUP_SCRIPT="${PREFIX}/usr/local/sbin/backup-to-synology.sh"
    UNIT_DIR="$SYSTEMD_DIR"
  fi
  SERVICE_UNIT="${UNIT_DIR}/rsynbacktux.service"
  TIMER_UNIT="${UNIT_DIR}/rsynbacktux.timer"
}
compute_paths

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
DISCOVER=""
DISCOVER_ONLY=false
# Wartezeit je Host beim Absuchen des Netzes. Im LAN antwortet ein Gerät weit
# darunter; höher gedreht dauert der Suchlauf unnötig lange.
DISCOVER_TIMEOUT="${RSYNBACKTUX_DISCOVER_TIMEOUT:-0.3}"

DEFAULT_HOST="192.168.178.5"
DEFAULT_MODULE="NetBackup"
DEFAULT_USER="backup"
DEFAULT_TIME="03:00"

# --- Ausgabe ----------------------------------------------------------------
# Farben nur, wenn wirklich ein Terminal daran hängt. In Pipes, Logfiles, der
# Testsuite und bei gesetztem NO_COLOR bleibt die Ausgabe unverändert.
if [[ -t 1 && -z "${NO_COLOR-}" && "${TERM-}" != "dumb" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
fi

log()  { printf '%s\n' "$*"; }
warn() { printf '%sWARNUNG:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%sFEHLER:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# Abschnittsüberschrift
step() { printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }
# Erledigt-Meldung mit Haken
ok()   { printf '  %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
# Aufzählung ohne Wertung
item() { printf '  %s·%s %s\n' "$C_DIM" "$C_RESET" "$*"; }

banner() {
  printf '\n%s%s%s\n' "$C_BOLD" "  rSynBackTux ${RSYNBACKTUX_VERSION}" "$C_RESET"
  printf '%s%s%s\n\n' "$C_DIM" "  Backups von Linux-Servern auf eine Synology NAS" "$C_RESET"
}

usage() {
  cat <<'USAGE'
rSynBackTux – Synology Backup Installer

Verwendung:
  install-syno-backup.sh [OPTIONEN]

Verbindung:
  --host HOST              Synology Host oder IP
  --discover               Netz nach Sicherungszielen absuchen und beenden
  --no-discover            Nicht automatisch nach der Synology suchen
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

Paketmodus (rsynbacktux-setup aus dem .deb-Paket):
  --packaged               Backup-Runner, systemd-Units und Logrotation stammen
                           aus dem Paket; es werden nur Konfiguration,
                           Passwortdatei und Zeitsteuerung geschrieben
  --emit-package-files DIR Nur die statischen Paketdateien nach DIR schreiben
                           (wird vom Paketbau benutzt, verändert nichts am System)

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
      --discover)         DISCOVER_ONLY=true;        shift ;;
      --no-discover)      DISCOVER="no";             shift ;;
      --packaged)         PACKAGED=true;             shift ;;
      --emit-package-files) EMIT_DIR="${2-}";        shift 2 ;;
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

# Hängt ein echtes Terminal an der Eingabe? Bei "curl | bash" oder in der
# Testsuite kommen die Antworten aus einer Umleitung – dann darf nichts
# ungefragt eine Zeile verbrauchen, etwa eine Auswahlliste.
has_tty() {
  [[ -z "${RSYNBACKTUX_NO_TTY-}" && -r /dev/tty ]]
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

# --- Suche nach der Synology ------------------------------------------------
# Sucht im lokalen Netz nach Hosts mit offenem rsync-Port und fragt dort die
# Modulliste ab. Damit ist nicht nur "irgendein Gerät" gefunden, sondern eines,
# das tatsächlich als Sicherungsziel taugt.
#
# Bewusst ohne nmap, avahi & Co: bash kann TCP-Verbindungen selbst öffnen,
# die Modulabfrage macht rsync. Beides ist ohnehin vorhanden.

# Ermittelt die eigenen IPv4-Netze als "IP/Präfix".
local_networks() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show scope global 2>/dev/null | awk '{ print $4 }'
  elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig 2>/dev/null | awk '/inet /{ print $2 "/24" }' | grep -v '^127\.'
  elif command -v hostname >/dev/null 2>&1; then
    # Letzter Ausweg für schlanke Systeme ohne iproute2 und net-tools.
    hostname -I 2>/dev/null | tr ' ' '\n' | awk 'NF { print $1 "/24" }'
  fi
}

# Prüft einen einzelnen Host auf offenen rsync-Port.
probe_rsync_port() {
  local host="$1"
  timeout "$DISCOVER_TIMEOUT" bash -c "exec 3<>/dev/tcp/${host}/873" 2>/dev/null
}

discover_synology() {
  local net base ip pids=() found=() networks=()

  mapfile -t networks < <(local_networks || true)
  if [[ "${#networks[@]}" -eq 0 ]]; then
    return 1
  fi

  local scanned=""
  for net in "${networks[@]}"; do
    ip="${net%%/*}"
    [[ "$ip" == 127.* ]] && continue
    # Nur das eigene /24 absuchen – alles Größere dauert zu lange, um es
    # jemanden interaktiv abwarten zu lassen.
    base="${ip%.*}"
    [[ " ${scanned} " == *" ${base} "* ]] && continue
    scanned="${scanned} ${base}"

    local tmpdir
    tmpdir="$(mktemp -d)"
    local last
    for ((last = 1; last <= 254; last++)); do
      {
        if probe_rsync_port "${base}.${last}"; then
          printf '%s\n' "${base}.${last}" > "${tmpdir}/${last}"
        fi
      } &
      pids+=("$!")
      # Nicht mehr als 64 Sonden gleichzeitig, sonst geht dem System die
      # Puste aus.
      if [[ "${#pids[@]}" -ge 64 ]]; then
        wait "${pids[@]}" 2>/dev/null || true
        pids=()
      fi
    done
    if [[ "${#pids[@]}" -gt 0 ]]; then
      wait "${pids[@]}" 2>/dev/null || true
      pids=()
    fi

    local f
    for f in "$tmpdir"/*; do
      [[ -e "$f" ]] || continue
      found+=("$(cat "$f")")
    done
    rm -rf "$tmpdir"
  done

  if [[ "${#found[@]}" -eq 0 ]]; then
    return 1
  fi

  printf '%s\n' "${found[@]}" | sort -t. -k4 -n
}

# Fragt die Modulliste eines rsync-Daemons ab (ohne Anmeldung).
list_rsync_modules() {
  local host="$1"
  rsync --contimeout=5 --list-only "rsync://${host}/" 2>/dev/null \
    | awk 'NF { print $1 }'
}

# Sucht, zeigt die Treffer und lässt auswählen. Setzt bei Erfolg OPT_HOST und,
# wenn eindeutig, auch OPT_MODULE.
offer_discovery() {
  local hosts=() host modules

  step "Suche nach einem Sicherungsziel im Netz"
  item "rsync-Port im lokalen Netz, das dauert ein paar Sekunden..."

  mapfile -t hosts < <(discover_synology || true)

  if [[ "${#hosts[@]}" -eq 0 ]]; then
    item "Nichts gefunden – bitte den Host von Hand angeben."
    return 1
  fi

  local -a host_modules=()
  local i=1
  for host in "${hosts[@]}"; do
    modules="$(list_rsync_modules "$host" | paste -sd' ' - || true)"
    host_modules+=("$modules")
    if [[ -n "$modules" ]]; then
      ok "$(printf '%d) %-15s Module: %s' "$i" "$host" "$modules")"
    else
      ok "$(printf '%d) %-15s (keine Module abfragbar)' "$i" "$host")"
    fi
    i=$((i + 1))
  done
  item "0) anderer Host"

  local choice=""
  printf '\nAuswahl [1]: '
  read_input -r choice || choice=""
  choice="${choice:-1}"

  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "${#hosts[@]}" ]]; then
    return 1
  fi

  OPT_HOST="${hosts[$((choice - 1))]}"
  modules="${host_modules[$((choice - 1))]}"

  # Modul nur vorbelegen, wenn die Wahl eindeutig ist: entweder gibt es genau
  # eins, oder der Standardname ist dabei.
  if [[ " ${modules} " == *" ${DEFAULT_MODULE} "* ]]; then
    OPT_MODULE="${OPT_MODULE:-$DEFAULT_MODULE}"
  elif [[ -n "$modules" && "$(printf '%s' "$modules" | wc -w)" -eq 1 ]]; then
    OPT_MODULE="${OPT_MODULE:-$modules}"
  fi

  return 0
}

# --discover: nur suchen und anzeigen.
run_discovery_only() {
  local hosts=() host modules

  banner
  step "Suche nach Sicherungszielen im Netz"

  mapfile -t hosts < <(discover_synology || true)
  if [[ "${#hosts[@]}" -eq 0 ]]; then
    item "Kein Host mit erreichbarem rsync-Dienst gefunden."
    log ""
    log "Auf der Synology müssen dafür aktiviert sein:"
    item "rsync-Dienst aktivieren"
    item "Netzwerksicherungsziel aktivieren"
    return 1
  fi

  for host in "${hosts[@]}"; do
    modules="$(list_rsync_modules "$host" | paste -sd' ' - || true)"
    ok "$(printf '%-15s Module: %s' "$host" "${modules:-–}")"
  done
  log ""
  log "Einrichten mit: ${0##*/} --host <IP>"
  return 0
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
  local out="${DESTDIR}${EXCLUDE_FILE}"

  # Im Paketmodus gehört die Ausschlussliste dem Paket (conffile). Eine
  # bestehende Datei wird deshalb nicht überschrieben – eigene Einträge
  # überleben so jedes 'rsynbacktux-setup'.
  if [[ "$PACKAGED" == true && -z "$DESTDIR" && -f "$out" ]]; then
    log "Ausschlussliste vorhanden, bleibt unverändert: ${EXCLUDE_FILE}"
    return
  fi

  install -d -m 755 "${DESTDIR}${CONF_DIR}"
  cat > "$out" <<EXCLUDES
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
  chmod 644 "$out"
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
  local out="${DESTDIR}${BACKUP_SCRIPT}"
  install -d -m 755 "$(dirname "$out")"

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
  } > "$out"

  chmod 755 "$out"
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
  local out="${DESTDIR}${LOGROTATE_FILE}"

  if [[ ! -d "$(dirname "$out")" ]] && [[ -z "$PREFIX" && -z "$DESTDIR" ]]; then
    warn "logrotate scheint nicht installiert zu sein – Logrotation wird übersprungen."
    return
  fi
  install -d -m 755 "$(dirname "$out")"
  cat > "$out" <<ROTATE
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
  chmod 644 "$out"
  log "Logrotation eingerichtet: ${LOGROTATE_FILE}"
}

write_systemd_units() {
  local oncalendar="$1"

  install -d -m 755 "${DESTDIR}${UNIT_DIR}"

  cat > "${DESTDIR}${SERVICE_UNIT}" <<SERVICE
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

  cat > "${DESTDIR}${TIMER_UNIT}" <<TIMER
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

  chmod 644 "${DESTDIR}${SERVICE_UNIT}" "${DESTDIR}${TIMER_UNIT}"
}

# Im Paketmodus liefert das Paket die Units mit. Die Uhrzeit kommt dann aus
# einem Drop-in, damit ein Paket-Update die Einstellung nicht überschreibt.
write_timer_override() {
  local oncalendar="$1"

  install -d -m 755 "$DROPIN_DIR"
  cat > "$DROPIN_FILE" <<OVERRIDE
# rSynBackTux – von rsynbacktux-setup erzeugt.
# Der leere OnCalendar-Eintrag löscht den Wert aus der mitgelieferten Unit,
# sonst würden beide Zeiten gelten.
[Timer]
OnCalendar=
OnCalendar=${oncalendar}
OVERRIDE
  chmod 644 "$DROPIN_FILE"
  log "Zeitsteuerung gesetzt: ${DROPIN_FILE}"
}

setup_systemd() {
  local oncalendar="$1"

  if [[ "$PACKAGED" == true ]]; then
    write_timer_override "$oncalendar"
  else
    write_systemd_units "$oncalendar"
  fi

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

# Schreibt die statischen Dateien des Distributionspakets in ein
# Staging-Verzeichnis: Backup-Runner, systemd-Units, Logrotation und
# Ausschlussliste. Die Pfade darin sind absolut, also unabhängig von
# RSYNBACKTUX_PREFIX – das Paket landet später ohnehin unter /.
emit_package_files() {
  local dir="$1"

  [[ -n "$dir" ]] || die "--emit-package-files benötigt ein Zielverzeichnis."

  PACKAGED=true
  PREFIX=""
  compute_paths
  DESTDIR="$dir"

  install -d -m 755 "$dir"
  write_backup_script
  write_systemd_units "*-*-* ${DEFAULT_TIME}:00"
  write_logrotate
  write_excludes

  log "Paketdateien geschrieben nach: ${dir}"
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
  local scheduler="$1" schedule="$2" schedule_text

  case "$scheduler" in
    systemd) schedule_text="systemd-Timer (${schedule})" ;;
    cron)    schedule_text="Cronjob (${schedule})" ;;
    *)       schedule_text="keine – Backup manuell starten" ;;
  esac

  log ""
  if [[ "$PACKAGED" == true ]]; then
    step "=== Einrichtung abgeschlossen ==="
  else
    step "=== Installation abgeschlossen ==="
  fi
  printf '  %-14s %s\n' "Konfiguration:" "$CONF_FILE"
  printf '  %-14s %s\n' "Ausschlüsse:"   "$EXCLUDE_FILE"
  printf '  %-14s %s\n' "Backup-Script:" "$BACKUP_SCRIPT"
  printf '  %-14s %s\n' "Logfile:"       "$LOGFILE"
  printf '  %-14s %s%s%s\n' "Ziel:" "$C_BOLD" \
    "${OPT_USER}@${OPT_HOST}::${OPT_MODULE}/${OPT_SUBDIR}/" "$C_RESET"
  printf '  %-14s %s\n' "Zeitsteuerung:" "$schedule_text"

  log ""
  case "$scheduler" in
    systemd)
      item "Status:  systemctl list-timers rsynbacktux.timer"
      item "Sofort:  systemctl start rsynbacktux.service"
      ;;
    cron)
      item "Status:  crontab -l"
      ;;
    *)
      item "Start:   ${BACKUP_SCRIPT}"
      ;;
  esac
  item "Log:     ${LOGFILE}"
}

main() {
  parse_args "$@"

  if [[ -n "$EMIT_DIR" ]]; then
    emit_package_files "$EMIT_DIR"
    return 0
  fi

  compute_paths

  if [[ "$DISCOVER_ONLY" == true ]]; then
    run_discovery_only
    return $?
  fi

  require_root

  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY RUN] Installer läuft im Testmodus – es wird nichts am System verändert."
  fi

  banner
  if [[ "$PACKAGED" == true ]]; then
    log "=== rSynBackTux ${RSYNBACKTUX_VERSION} – Einrichtung (Paketinstallation) ==="
  else
    log "=== rSynBackTux ${RSYNBACKTUX_VERSION} – Synology Backup Installer ==="
  fi

  local default_subdir
  default_subdir="$(sanitize_name "$(hostname -s 2>/dev/null || hostname)")"

  # Vor der ersten Frage einmal ins Netz schauen – aber nur, wenn ohnehin
  # gefragt wird und der Host nicht schon feststeht.
  if [[ "$NON_INTERACTIVE" == false && "$DRY_RUN" == false && \
        -z "$OPT_HOST" && "$DISCOVER" != "no" ]] && has_tty; then
    offer_discovery || true
  fi

  step "Verbindung zur Synology"
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
    if [[ "$PACKAGED" == true ]]; then
      log "  - Backup-Script:           ${BACKUP_SCRIPT} (aus dem Paket)"
      log "  - Logrotation:             ${LOGROTATE_FILE} (aus dem Paket)"
    else
      log "  - Backup-Script anlegen:   ${BACKUP_SCRIPT}"
      log "  - Logrotation einrichten:  ${LOGROTATE_FILE}"
    fi
    log "  - Logfile anlegen:         ${LOGFILE}"
    log "  - Ziel:                    ${OPT_USER}@${OPT_HOST}::${OPT_MODULE}/${OPT_SUBDIR}/"
    log "  - Zeitsteuerung:           ${scheduler} (${schedule_label})"
    log ""
    log "[DRY RUN] Beendet – keine Änderungen vorgenommen."
    return 0
  fi

  if [[ "$PACKAGED" == true && ! -x "$BACKUP_SCRIPT" ]]; then
    die "Backup-Runner nicht gefunden: ${BACKUP_SCRIPT}. Ist das Paket rsynbacktux installiert?"
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
  write_logfile
  # Im Paketmodus gehören Backup-Runner und Logrotation dem Paketmanager.
  if [[ "$PACKAGED" == false ]]; then
    write_backup_script
    write_logrotate
  fi

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
