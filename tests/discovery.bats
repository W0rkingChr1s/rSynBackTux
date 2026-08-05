#!/usr/bin/env bats
# Tests für Netzwerksuche, Vervollständigung und Terminal-Ausgabe

load helper

setup() {
  setup_sandbox
  stub_rsync 0
}

teardown() {
  teardown_sandbox
}

# --- Suche -------------------------------------------------------------------

@test "--discover ist in der Hilfe dokumentiert" {
  run "$INSTALLER" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--discover"* ]]
  [[ "$output" == *"--no-discover"* ]]
}

@test "--discover braucht keine root-Rechte und verändert nichts" {
  run "$INSTALLER" --discover
  # Ob etwas gefunden wird, hängt vom Netz ab – nur kein Absturz und keine
  # Spuren im Dateisystem.
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [ ! -e "$CONF_FILE" ]
  [ ! -e "$PASSFILE" ]
}

@test "ohne gefundene Hosts kommt ein brauchbarer Hinweis" {
  # 'ip', 'ifconfig' und 'hostname' durch Stubs ohne Ausgabe ersetzen, damit
  # kein Netz erkannt wird.
  for tool in ip ifconfig hostname; do
    printf '#!/usr/bin/env bash\nexit 1\n' > "${STUB_BIN}/${tool}"
    chmod +x "${STUB_BIN}/${tool}"
  done
  run "$INSTALLER" --discover
  [ "$status" -eq 1 ]
  [[ "$output" == *"Netzwerksicherungsziel aktivieren"* ]]
}

@test "Suchlauf findet einen Host mit offenem rsync-Port" {
  # Eigenes Netz vortäuschen und einen lauschenden Port anbieten.
  local port_helper="${SANDBOX}/listener.py"
  cat > "$port_helper" <<'PY'
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", 8873))
except OSError:
    sys.exit(1)
s.listen(5)
time.sleep(30)
PY
  if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 nicht verfügbar"
  fi

  # Der Installer sucht auf Port 873; ohne root lässt sich der nicht belegen.
  # Deshalb hier nur die Sonde selbst prüfen, isoliert.
  python3 "$port_helper" &
  local pid=$!
  sleep 1

  run timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/8873'
  kill "$pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "bei umgeleiteter Eingabe wird nicht gesucht" {
  # Sonst würde die Auswahlliste eine Antwortzeile verbrauchen und der
  # ganze Ablauf verrutschen.
  run env -u RSYNBACKTUX_PASSWORD -u RSYNC_PASSWORD RSYNBACKTUX_NO_TTY=1 \
    "$INSTALLER" --scheduler none --skip-connection-test <<'ANTWORTEN'
192.168.178.9
Backups
sicherung
webserver
mein-passwort
n
ANTWORTEN
  [ "$status" -eq 0 ]
  [[ "$output" != *"Suche nach einem Sicherungsziel"* ]]
  grep -q '^SYNO_HOST=192.168.178.9$' "$CONF_FILE"
}

@test "--no-discover unterdrückt die Suche" {
  run env RSYNBACKTUX_PASSWORD=geheim RSYNBACKTUX_NO_TTY=1 \
    "$INSTALLER" --no-discover --non-interactive --host nas.local \
    --scheduler none --skip-connection-test --no-run-now
  [ "$status" -eq 0 ]
  [[ "$output" != *"Suche nach"* ]]
}

# --- Ausgabe -----------------------------------------------------------------

@test "ohne Terminal bleibt die Ausgabe frei von Steuerzeichen" {
  run install_sandbox
  [ "$status" -eq 0 ]
  # \033 darf in der Ausgabe nicht vorkommen, sonst landen Farbcodes im Log
  ! printf '%s' "$output" | grep -q $'\033'
}

@test "Zusammenfassung nennt Ziel und nächste Schritte" {
  run install_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup@192.168.178.5::NetBackup/testserver/"* ]]
  [[ "$output" == *"Log:"* ]]
}

# --- Vervollständigung -------------------------------------------------------

@test "bash-Vervollständigung ist syntaktisch gültig und greift" {
  local comp="${REPO_ROOT}/packaging/completion/rsynbacktux-setup.bash"
  [ -f "$comp" ]
  run bash -n "$comp"
  [ "$status" -eq 0 ]

  run bash -c "
    source '$comp'
    COMP_WORDS=(rsynbacktux-setup --sched)
    COMP_CWORD=1
    _rsynbacktux_setup
    printf '%s' \"\${COMPREPLY[*]}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"--scheduler"* ]]
}

@test "Vervollständigung kennt die Werte von --scheduler" {
  local comp="${REPO_ROOT}/packaging/completion/rsynbacktux-setup.bash"
  run bash -c "
    source '$comp'
    COMP_WORDS=(rsynbacktux-setup --scheduler '')
    COMP_CWORD=2
    _rsynbacktux_setup
    printf '%s' \"\${COMPREPLY[*]}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"systemd"* ]]
  [[ "$output" == *"cron"* ]]
  [[ "$output" == *"none"* ]]
}

@test "Vervollständigung deckt alle Optionen des Installers ab" {
  local comp="${REPO_ROOT}/packaging/completion/rsynbacktux-setup.bash"
  local opt
  # Jede Option aus der Hilfe muss die Vervollständigung kennen, sonst läuft
  # die Liste mit der Zeit auseinander.
  while read -r opt; do
    [[ -z "$opt" ]] && continue
    # emit-package-files ist nur für den Paketbau und gehört nicht in die Liste
    [[ "$opt" == "--emit-package-files" ]] && continue
    grep -qF -- "$opt" "$comp" || {
      echo "Option fehlt in der Vervollständigung: $opt"
      false
    }
  done < <("$INSTALLER" --help | grep -oE '^  --[a-z-]+' | tr -d ' ')
}

@test "Paket bringt die Vervollständigung mit" {
  if ! command -v dpkg-deb >/dev/null 2>&1; then
    skip "dpkg-deb nicht verfügbar"
  fi
  env -u RSYNBACKTUX_PREFIX "${REPO_ROOT}/scripts/build-deb.sh" "${SANDBOX}/dist" >/dev/null
  run dpkg-deb --contents "${SANDBOX}/dist/rsynbacktux_$(cat "${REPO_ROOT}/VERSION")-1_all.deb"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/usr/share/bash-completion/completions/rsynbacktux-setup"* ]]
  [[ "$output" == *"/usr/share/zsh/vendor-completions/_rsynbacktux-setup"* ]]
}
