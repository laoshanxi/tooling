#!/usr/bin/env bash
# proxy_setup.sh - point common tools at an HTTP proxy on Debian/Ubuntu
#
#   bash proxy_setup.sh apply   [step ...]   apply (safe to re-run)
#   bash proxy_setup.sh restore [step ...]   undo, back to the pre-apply state
#   bash proxy_setup.sh status               show what is currently applied
#   bash proxy_setup.sh help
#
# Steps: wget curl git apt maven node wsl docker docker-build alias
#
# apply snapshots the files it may touch into
# ${XDG_STATE_HOME:-$HOME/.local/state}/proxy_setup/ the first time it runs.
# Later runs never overwrite that snapshot, so restore puts the machine back
# to how it was before the *first* apply, not before the most recent one.
#
# Environment overrides:
#   PROXY_HOST           default 127.0.0.1
#   PROXY_PORT           default 7890
#   GIT_USER_NAME        git identity. If neither is set, an existing identity
#   GIT_USER_EMAIL       is left untouched rather than overwritten.
#   ALLOW_INSECURE_SSL=1 also set npm/yarn strict-ssl=false. Only needed behind
#                        a MITM proxy; it disables TLS certificate verification.
#   SKIP_PROXY_CHECK=1   write the apt proxy even if it does not work.
#                        By default an unusable proxy is skipped, since a wrong
#                        apt proxy breaks apt entirely.
#
set -uo pipefail

PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-7890}"
PROXY="http://${PROXY_HOST}:${PROXY_PORT}"

# These marker strings are frozen identifiers, not a description of the current
# filename. They are already written into ~/.bashrc and /etc/profile.d on
# machines where this script has run; changing them would orphan those entries
# and leave a stale duplicate block behind. Leave them alone when renaming.
ALIAS_FILE="/etc/profile.d/aliases.sh"
ALIAS_MARK="# written by proxy_setup.sh"
BASHRC_MARK_BEGIN="# BEGIN proxy_setup.sh"
BASHRC_MARK_END="# END proxy_setup.sh"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/proxy_setup"
SNAP_DIR="$STATE_DIR/snapshot"
SNAP_FILES="$SNAP_DIR/files"
SNAP_INDEX="$SNAP_DIR/index.tsv"      # <slot> <TAB> <path>
SNAP_ABSENT="$SNAP_DIR/absent.txt"    # paths that did not exist at snapshot time
SNAP_GIT="$SNAP_DIR/git-proxy.tsv"    # git proxy values before the first apply

STEPS=(wget curl git apt maven node wsl docker docker-build alias)

ok()   { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "$*" >&2; exit 1; }

# Run a command with root privileges. sudo is not always available - minimal
# containers often have none, and when already running as root there is no
# need for it.
as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    warn "not root and sudo is not installed - cannot run: $*"
    return 1
  fi
}

# Detect WSL
is_wsl() {
  grep -qi "microsoft" /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]
}

# Whether a file still looks like something this script wrote. Used before
# deleting a file we created, so a file the user has since taken over is left
# alone.
file_is_ours() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -qF "proxy_setup.sh" "$f" 2>/dev/null && return 0
  grep -qF "${PROXY_HOST}:${PROXY_PORT}" "$f" 2>/dev/null && return 0
  return 1
}

# A TCP connect is not enough to call a proxy usable: something can be
# listening on the port without being a working HTTP proxy, and a broken apt
# proxy takes apt down with it. Make a real request through it when we can.
proxy_works() {
  if command -v curl >/dev/null 2>&1; then
    curl -sS -m 8 -o /dev/null --proxy "$PROXY" \
      http://deb.debian.org/debian/dists/stable/Release >/dev/null 2>&1
  else
    (exec 3<>"/dev/tcp/${PROXY_HOST}/${PROXY_PORT}") 2>/dev/null
  fi
}

# ---- snapshot --------------------------------------------------------------

# Which files a step touches. Used by restore to work per-step.
step_paths() {
  case "$1" in
    wget)         printf '%s\n' "$HOME/.wgetrc" ;;
    curl)         printf '%s\n' "$HOME/.curlrc" ;;
    git)          : ;;
    apt)          printf '%s\n' "/etc/apt/apt.conf.d/80proxy" ;;
    maven)        printf '%s\n' "$HOME/.m2/settings.xml" ;;
    node)         printf '%s\n' "$HOME/.npmrc" "$HOME/.yarnrc" ;;
    wsl)          printf '%s\n' "/etc/environment" ;;
    docker)       printf '%s\n' "/etc/systemd/system/docker.service.d/http-proxy.conf" ;;
    docker-build) printf '%s\n' "$HOME/.bashrc" ;;
    alias)        printf '%s\n' "$ALIAS_FILE" ;;
  esac
}

all_tracked_paths() {
  local s
  for s in "${STEPS[@]}"; do step_paths "$s"; done | sort -u
}

# Snapshot once, before the first modification. A later apply must never
# overwrite this, or restore would only undo the most recent run.
snapshot_once() {
  if [ -f "$SNAP_DIR/.taken" ]; then
    echo "[*] snapshot already exists, keeping the original: $SNAP_DIR"
    return 0
  fi
  mkdir -p "$SNAP_FILES" || die "cannot create $SNAP_FILES"
  : > "$SNAP_INDEX"
  : > "$SNAP_ABSENT"

  local slot=0 p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -f "$p" ]; then
      slot=$((slot + 1))
      if cp -p "$p" "$SNAP_FILES/$slot" 2>/dev/null; then
        printf '%s\t%s\n' "$slot" "$p" >> "$SNAP_INDEX"
      else
        # Could not read it (permissions). Try as root before giving up.
        if as_root cp -p "$p" "$SNAP_FILES/$slot" 2>/dev/null; then
          printf '%s\t%s\n' "$slot" "$p" >> "$SNAP_INDEX"
        else
          warn "could not snapshot $p - it will not be restorable"
        fi
      fi
    else
      printf '%s\n' "$p" >> "$SNAP_ABSENT"
    fi
  done < <(all_tracked_paths)

  # git proxy values are not in a file we own, so record them individually.
  {
    if command -v git >/dev/null 2>&1; then
      printf 'http.proxy\t%s\n'  "$(git config --global --get http.proxy  2>/dev/null || echo '__unset__')"
      printf 'https.proxy\t%s\n' "$(git config --global --get https.proxy 2>/dev/null || echo '__unset__')"
    fi
  } > "$SNAP_GIT"

  : > "$SNAP_DIR/.taken"
  echo "[*] snapshotted $(wc -l < "$SNAP_INDEX" | tr -d ' ') file(s), $(wc -l < "$SNAP_ABSENT" | tr -d ' ') absent, -> $SNAP_DIR"
}

restore_git_proxy() {
  command -v git >/dev/null 2>&1 || { warn "git not found, skipping git proxy restore"; return 0; }
  [ -f "$SNAP_GIT" ] || { warn "no git snapshot, leaving git proxy as is"; return 0; }
  local key value
  while IFS=$'\t' read -r key value; do
    [ -n "${key:-}" ] || continue
    if [ "$value" = "__unset__" ]; then
      if git config --global --unset "$key" 2>/dev/null; then
        ok "git $key unset"
      else
        ok "git $key was already unset"
      fi
    else
      git config --global "$key" "$value" && ok "git $key -> $value"
    fi
  done < "$SNAP_GIT"
}

# ---- steps: apply ----------------------------------------------------------

set_proxy_wget() {
  echo "[*] Configuring wget proxy..."
  local conf_file="$HOME/.wgetrc"
  touch "$conf_file"
  sed -i '/^[[:space:]]*http_proxy[[:space:]]*=/d; /^[[:space:]]*https_proxy[[:space:]]*=/d' "$conf_file"
  {
    echo "http_proxy = $PROXY"
    echo "https_proxy = $PROXY"
  } >> "$conf_file"
  ok "wget -> $conf_file"
}

set_proxy_curl() {
  echo "[*] Configuring curl proxy..."
  local conf_file="$HOME/.curlrc"
  touch "$conf_file"
  sed -i '/^[[:space:]]*proxy[[:space:]]*=/d' "$conf_file"
  echo "proxy = ${PROXY_HOST}:${PROXY_PORT}" >> "$conf_file"
  ok "curl -> $conf_file"
}

set_proxy_git() {
  echo "[*] Configuring git proxy..."
  if ! command -v git >/dev/null 2>&1; then
    warn "git not found, skipping git proxy"
    return 0
  fi
  git config --global http.proxy "$PROXY"
  git config --global https.proxy "$PROXY"
  ok "git -> $PROXY"
}

set_git_user() {
  echo "[*] Configuring git user..."
  if ! command -v git >/dev/null 2>&1; then
    warn "git not found, skipping git identity"
    return 0
  fi
  if [ -n "${GIT_USER_NAME:-}" ] || [ -n "${GIT_USER_EMAIL:-}" ]; then
    [ -n "${GIT_USER_NAME:-}" ]  && git config --global user.name "$GIT_USER_NAME"
    [ -n "${GIT_USER_EMAIL:-}" ] && git config --global user.email "$GIT_USER_EMAIL"
    ok "git identity set from environment"
    return 0
  fi
  local cur_name cur_email
  cur_name="$(git config --global user.name 2>/dev/null || true)"
  cur_email="$(git config --global user.email 2>/dev/null || true)"
  if [ -n "$cur_name" ] && [ -n "$cur_email" ]; then
    ok "git identity already set ($cur_name <$cur_email>) - left untouched"
  else
    warn "git identity is not fully set; export GIT_USER_NAME/GIT_USER_EMAIL to configure it"
  fi
}

set_proxy_apt() {
  echo "[*] Configuring apt proxy..."
  local conf_file="/etc/apt/apt.conf.d/80proxy"

  # A wrong apt proxy does not degrade gracefully - it breaks apt completely,
  # including the apt you would use to repair the machine. Probe first.
  if [ "${SKIP_PROXY_CHECK:-}" != "1" ] && ! proxy_works; then
    warn "proxy ${PROXY_HOST}:${PROXY_PORT} is not usable (no working HTTP response through it)"
    warn "skipping the apt proxy: writing it now would break apt until the proxy works"
    warn "start the proxy and re-run, or set SKIP_PROXY_CHECK=1 to write it anyway"
    return 0
  fi

  as_root mkdir -p "$(dirname "$conf_file")"
  as_root tee "$conf_file" >/dev/null <<EOF
// $ALIAS_MARK
Acquire {
  HTTP { Proxy "$PROXY"; }
  HTTPS { Proxy "$PROXY"; }
}
EOF
  ok "apt -> $conf_file"
}

set_proxy_maven() {
  echo "[*] Configuring Maven proxy..."
  local m2_dir="$HOME/.m2"
  local settings_file="${m2_dir}/settings.xml"
  mkdir -p "$m2_dir"

  # Don't blow away a settings.xml we didn't write - it may hold mirrors,
  # servers or credentials.
  if [ -f "$settings_file" ] && ! grep -q 'default-proxy' "$settings_file"; then
    warn "$settings_file exists and was not written by this script - left untouched"
    warn "add the proxy block manually, or remove the file and re-run"
    return 0
  fi

  cat > "$settings_file" <<EOF
<!-- $ALIAS_MARK -->
<settings>
  <proxies>
    <proxy>
      <id>default-proxy</id>
      <active>true</active>
      <protocol>http</protocol>
      <host>${PROXY_HOST}</host>
      <port>${PROXY_PORT}</port>
      <nonProxyHosts>localhost|127.0.0.1</nonProxyHosts>
    </proxy>
  </proxies>
</settings>
EOF

  ok "maven -> $settings_file"
}

set_proxy_node() {
  echo "[*] Configuring Node.js (npm / yarn) proxy..."
  local insecure="${ALLOW_INSECURE_SSL:-}"

  if command -v npm >/dev/null 2>&1; then
    npm config set proxy "$PROXY"
    npm config set https-proxy "$PROXY"
    if [ "$insecure" = "1" ]; then
      npm config set strict-ssl false
      warn "npm strict-ssl disabled (ALLOW_INSECURE_SSL=1) - TLS verification is now off"
    fi
    ok "npm configured"
  else
    warn "npm not found, skipping npm proxy"
  fi

  if command -v yarn >/dev/null 2>&1; then
    yarn config set proxy "$PROXY"
    yarn config set https-proxy "$PROXY"
    if [ "$insecure" = "1" ]; then
      yarn config set strict-ssl false
    fi
    ok "yarn configured"
  else
    warn "yarn not found, skipping yarn proxy"
  fi
}

set_proxy_wsl_environment() {
  if ! is_wsl; then
    echo "[*] Not running in WSL - skipping /etc/environment proxy config."
    return 0
  fi

  echo "[*] Configuring system-wide proxy (/etc/environment)..."
  local env_file="/etc/environment"
  local tmpf
  tmpf="$(mktemp)"
  if [ -f "$env_file" ]; then
    cp "$env_file" "$tmpf"
    chmod --reference="$env_file" "$tmpf" 2>/dev/null || true
  fi
  sed -i '/^http_proxy=/d; /^https_proxy=/d; /^HTTP_PROXY=/d; /^HTTPS_PROXY=/d; /^no_proxy=/d; /^NO_PROXY=/d' "$tmpf"
  {
    echo "http_proxy=$PROXY"
    echo "https_proxy=$PROXY"
    echo "HTTP_PROXY=$PROXY"
    echo "HTTPS_PROXY=$PROXY"
    echo 'no_proxy="localhost,127.0.0.1,::1"'
    echo 'NO_PROXY="localhost,127.0.0.1,::1"'
  } >> "$tmpf"
  as_root cp "$tmpf" "$env_file"
  rm -f "$tmpf"
  ok "system-wide proxy -> $env_file"
  warn "log out and back in (or reboot) for environment changes to take effect"
}

set_alias_ll() {
  echo "[*] Setting up system-wide 'll' alias..."
  if [ -f "$ALIAS_FILE" ] && ! grep -qF "$ALIAS_MARK" "$ALIAS_FILE"; then
    warn "$ALIAS_FILE exists and was not written by this script - left untouched"
    warn "remove it or add the aliases manually if you want them"
    return 0
  fi
  as_root tee "$ALIAS_FILE" >/dev/null <<EOF
#!/bin/bash
$ALIAS_MARK
alias ll='ls -l'
alias la='ls -A'
alias l='ls -CF'
EOF
  as_root chmod +x "$ALIAS_FILE"
  ok "aliases -> $ALIAS_FILE"
}

set_proxy_docker() {
  echo "[*] Configuring Docker proxy..."
  local conf_dir="/etc/systemd/system/docker.service.d"
  local conf_file="${conf_dir}/http-proxy.conf"
  as_root mkdir -p "$conf_dir"
  as_root tee "$conf_file" >/dev/null <<EOF
# $ALIAS_MARK
[Service]
Environment="HTTP_PROXY=${PROXY}" "HTTPS_PROXY=${PROXY}" "NO_PROXY=localhost,127.0.0.1,docker.internal"
EOF
  ok "docker -> $conf_file"

  # /run/systemd/system is the reliable test for systemd actually being init;
  # the systemctl binary can exist without systemd running, and read-only
  # queries still exit 0 in that state.
  if [ ! -d /run/systemd/system ]; then
    warn "systemd is not the init system here - skipping daemon-reload/restart"
    return 0
  fi
  if ! systemctl list-unit-files docker.service >/dev/null 2>&1; then
    warn "docker.service not found - skipping daemon-reload/restart"
    return 0
  fi

  as_root systemctl daemon-reload
  if systemctl is-active --quiet docker; then
    warn "restarting Docker will stop any containers that are currently running"
    as_root systemctl restart docker
    ok "docker restarted"
  else
    ok "docker is not running - config takes effect on next start"
  fi
}

set_proxy_docker_build_image() {
  echo "[*] Configuring Docker build-time proxy..."
  # The apt proxy is written by set_proxy_apt (80proxy); don't write a second
  # apt config here the way this script used to.
  local rc="$HOME/.bashrc"
  touch "$rc"
  # Replace only our own marked block, so unrelated http_proxy lines survive.
  sed -i "\|^${BASHRC_MARK_BEGIN}\$|,\|^${BASHRC_MARK_END}\$|d" "$rc"
  {
    echo "$BASHRC_MARK_BEGIN"
    echo "export http_proxy=$PROXY"
    echo "export https_proxy=$PROXY"
    echo "$BASHRC_MARK_END"
  } >> "$rc"
  ok "build-time proxy vars -> $rc"
  warn "reload your shell (source ~/.bashrc) for build-time proxy vars"
}

# ---- steps: restore --------------------------------------------------------

restore_file() {
  local path="$1"
  local slot
  slot="$(awk -F'\t' -v p="$path" '$2 == p { print $1; exit }' "$SNAP_INDEX")"
  if [ -n "$slot" ]; then
    if as_root cp -p "$SNAP_FILES/$slot" "$path" 2>/dev/null; then
      ok "restored $path"
    else
      warn "could not restore $path"
    fi
    return 0
  fi
  # Not in the snapshot, so it did not exist before the first apply.
  if [ ! -e "$path" ]; then
    ok "$path already absent"
    return 0
  fi
  if file_is_ours "$path"; then
    if as_root rm -f "$path" 2>/dev/null; then
      ok "removed $path (created by this script)"
    else
      warn "could not remove $path"
    fi
  else
    warn "$path did not exist before, but no longer looks like ours - left in place"
  fi
}

restore_step() {
  local p
  case "$1" in
    git)
      restore_git_proxy
      ;;
    docker)
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        restore_file "$p"
      done < <(step_paths docker)
      # apply creates the drop-in directory; removing only the file inside
      # leaves an empty directory behind.
      local d="/etc/systemd/system/docker.service.d"
      if [ -d "$d" ] && [ -z "$(ls -A "$d" 2>/dev/null)" ]; then
        as_root rmdir "$d" 2>/dev/null && ok "removed empty $d"
      fi
      ;;
    *)
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        restore_file "$p"
      done < <(step_paths "$1")
      ;;
  esac
}

# ---- status ----------------------------------------------------------------

status_line() { printf '  %-14s %s\n' "$1" "$2"; }

cmd_status() {
  echo
  echo "proxy_setup status  (proxy ${PROXY})"
  echo

  if [ -f "$HOME/.wgetrc" ] && grep -qF "${PROXY_HOST}:${PROXY_PORT}" "$HOME/.wgetrc" 2>/dev/null; then
    status_line wget "applied"
  else
    status_line wget "not applied"
  fi

  if [ -f "$HOME/.curlrc" ] && grep -qF "${PROXY_HOST}:${PROXY_PORT}" "$HOME/.curlrc" 2>/dev/null; then
    status_line curl "applied"
  else
    status_line curl "not applied"
  fi

  local githttp=""
  command -v git >/dev/null 2>&1 && githttp="$(git config --global --get http.proxy 2>/dev/null || true)"
  if [ -n "$githttp" ]; then status_line git "applied ($githttp)"; else status_line git "not applied"; fi

  if [ -f /etc/apt/apt.conf.d/80proxy ]; then
    status_line apt "applied (/etc/apt/apt.conf.d/80proxy)"
  else
    status_line apt "not applied"
  fi

  if [ -f "$HOME/.m2/settings.xml" ] && grep -q 'default-proxy' "$HOME/.m2/settings.xml" 2>/dev/null; then
    status_line maven "applied"
  else
    status_line maven "not applied"
  fi

  if command -v npm >/dev/null 2>&1 && [ -n "$(npm config get proxy 2>/dev/null | grep -v '^null$' || true)" ]; then
    status_line node "applied"
  else
    status_line node "not applied"
  fi

  if is_wsl && grep -q '^http_proxy=' /etc/environment 2>/dev/null; then
    status_line wsl "applied"
  else
    status_line wsl "not applied"
  fi

  if [ -f /etc/systemd/system/docker.service.d/http-proxy.conf ]; then
    status_line docker "applied"
  else
    status_line docker "not applied"
  fi

  if [ -f "$HOME/.bashrc" ] && grep -qF "$BASHRC_MARK_BEGIN" "$HOME/.bashrc" 2>/dev/null; then
    status_line docker-build "applied"
  else
    status_line docker-build "not applied"
  fi

  if [ -f "$ALIAS_FILE" ] && grep -qF "$ALIAS_MARK" "$ALIAS_FILE" 2>/dev/null; then
    status_line alias "applied"
  else
    status_line alias "not applied"
  fi

  echo
  if [ -f "$SNAP_DIR/.taken" ]; then
    status_line snapshot "present - $SNAP_DIR"
    status_line "" "$(wc -l < "$SNAP_INDEX" | tr -d ' ') file(s) captured"
  else
    status_line snapshot "none - nothing to restore"
  fi
  echo
}

# ---- dispatch --------------------------------------------------------------

usage() {
  cat <<EOF
Usage: bash $(basename "$0") <command> [step ...]

Commands:
  apply      Apply the proxy configuration. Safe to re-run.
  restore    Put everything back the way it was before the first apply.
  status     Show which steps are currently applied.
  help       This text.

Steps: ${STEPS[*]}

  No step given means all of them.

Environment:
  PROXY_HOST (127.0.0.1)  PROXY_PORT (7890)
  GIT_USER_NAME / GIT_USER_EMAIL
  ALLOW_INSECURE_SSL=1    also disable npm/yarn strict-ssl (MITM proxies only)
  SKIP_PROXY_CHECK=1      write the apt proxy even if it does not work

State: $STATE_DIR
EOF
}

run_apply_step() {
  case "$1" in
    wget)         set_proxy_wget ;;
    curl)         set_proxy_curl ;;
    git)          set_proxy_git; set_git_user ;;
    apt)          set_proxy_apt ;;
    maven)        set_proxy_maven ;;
    node)         set_proxy_node ;;
    wsl)          set_proxy_wsl_environment ;;
    docker)       set_proxy_docker ;;
    docker-build) set_proxy_docker_build_image ;;
    alias)        set_alias_ll ;;
    *)            warn "unknown step: $1"; return 1 ;;
  esac
}

cmd_apply() {
  snapshot_once
  local rc=0 s
  for s in "$@"; do run_apply_step "$s" || rc=1; done
  [ "$rc" -eq 0 ] && ok "Proxy configuration applied."
  echo "Undo with: bash $0 restore"
  return $rc
}

cmd_restore() {
  if [ ! -f "$SNAP_DIR/.taken" ]; then
    die "No snapshot at $SNAP_DIR - nothing to restore. Run 'apply' first."
  fi
  local rc=0 s
  for s in "$@"; do restore_step "$s" || rc=1; done
  [ "$rc" -eq 0 ] && ok "Restored."
  echo "The snapshot is kept, so restore can be run again."
  return $rc
}

main() {
  local cmd="${1:-}"
  if [ $# -gt 0 ]; then shift; fi

  case "$cmd" in
    help|-h|--help) usage; return 0 ;;
    apply|restore|status) ;;
    "") usage >&2; return 1 ;;
    *) echo "Unknown command: $cmd" >&2; usage >&2; return 2 ;;
  esac

  if [ "$cmd" = "status" ]; then
    [ $# -gt 0 ] && warn "steps are ignored by 'status'"
    cmd_status
    return 0
  fi

  # Resolve the step list: arguments, or every step.
  local steps=()
  if [ $# -eq 0 ]; then
    steps=("${STEPS[@]}")
  else
    local s
    for s in "$@"; do
      case " ${STEPS[*]} " in
        *" $s "*) steps+=("$s") ;;
        *) echo "Unknown step: $s" >&2; usage >&2; return 2 ;;
      esac
    done
  fi

  if [ "$cmd" = "apply" ]; then
    cmd_apply "${steps[@]}"
  else
    cmd_restore "${steps[@]}"
  fi
}

main "$@"
