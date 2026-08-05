# bash-Vervollständigung für rsynbacktux-setup
# shellcheck shell=bash

_rsynbacktux_setup() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD - 1]}"

    opts="--host --discover --no-discover --module --user --subdir --password-file
          --source --one-file-system
          --scheduler --time --oncalendar --cron
          --non-interactive --run-now --no-run-now --skip-connection-test
          --dry-run --packaged --help --version"

    case "$prev" in
        --password-file|--source)
            # _filedir kommt aus dem Paket bash-completion; ohne das Paket
            # bleibt die einfache Dateivervollständigung.
            if declare -F _filedir >/dev/null 2>&1; then
                _filedir
            else
                mapfile -t COMPREPLY < <(compgen -f -- "$cur")
            fi
            return
            ;;
        --scheduler)
            mapfile -t COMPREPLY < <(compgen -W "auto systemd cron none" -- "$cur")
            return
            ;;
        --time)
            mapfile -t COMPREPLY < <(compgen -W "01:00 02:00 03:00 04:00 05:00" -- "$cur")
            return
            ;;
        --module)
            mapfile -t COMPREPLY < <(compgen -W "NetBackup" -- "$cur")
            return
            ;;
        --user)
            mapfile -t COMPREPLY < <(compgen -W "backup" -- "$cur")
            return
            ;;
        --subdir)
            mapfile -t COMPREPLY < <(compgen -W "$(hostname -s 2>/dev/null || hostname)" -- "$cur")
            return
            ;;
        --host)
            # Bereits eingerichtete NAS vorschlagen, sonst nichts raten.
            local known=""
            if [[ -r /etc/rsynbacktux/backup.conf ]]; then
                known="$(awk -F= '/^SYNO_HOST=/ { gsub(/["'"'"']/, "", $2); print $2 }' \
                    /etc/rsynbacktux/backup.conf 2>/dev/null)"
            fi
            mapfile -t COMPREPLY < <(compgen -W "$known" -- "$cur")
            return
            ;;
        --oncalendar|--cron)
            return
            ;;
    esac

    mapfile -t COMPREPLY < <(compgen -W "$opts" -- "$cur")
}

complete -F _rsynbacktux_setup rsynbacktux-setup
complete -F _rsynbacktux_setup install-syno-backup.sh
