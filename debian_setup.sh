#!/usr/bin/env bash
# debian_setup.sh - common Debian/Ubuntu machine setup
#
#   bash debian_setup.sh apply   [step ...]   apply (safe to re-run)
#   bash debian_setup.sh restore [step ...]   undo, back to the pre-apply state
#   bash debian_setup.sh status               show what is currently applied
#   bash debian_setup.sh help
#
# Steps: apt ssh packages shell
#
# Run it as your normal user, not with sudo: user-level steps write to $HOME,
# and privileged work goes through sudo individually. Running the whole thing
# under sudo would put ~/.ssh/config and ~/.bashrc in /root.
#
# apply snapshots the files it may touch into
# ${XDG_STATE_HOME:-$HOME/.local/state}/debian_setup/ the first time it runs.
# Later runs never overwrite that snapshot, so restore puts the machine back
# to how it was before the *first* apply.
#
# Environment overrides:
#   APT_MIRROR           default mirrors.aliyun.com
#   PACKAGES             space-separated package list for the packages step
#   SHELL_PROMPT=0       leave PS1 alone in the shell step
#   PURGE_PACKAGES=1     let restore uninstall the packages step installed
#
set -uo pipefail

APT_MIRROR="${APT_MIRROR:-mirrors.aliyun.com}"
PACKAGES="${PACKAGES:-curl git vim htop tmux jq unzip ca-certificates}"

# Frozen marker identifier; see README. Do not rename when renaming the script.
MARKER="debian_setup.sh"
BLOCK_BEGIN="# BEGIN ${MARKER}"
BLOCK_END="# END ${MARKER}"

APT_TUNING_FILE="/etc/apt/apt.conf.d/99debian_setup"
SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
BASHRC="$HOME/.bashrc"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/debian_setup"
SNAP_DIR="$STATE_DIR/snapshot"
SNAP_FILES="$SNAP_DIR/files"
SNAP_INDEX="$SNAP_DIR/index.tsv"      # <slot> <TAB> <path>
SNAP_ABSENT="$SNAP_DIR/absent.txt"
PKG_LIST="$STATE_DIR/packages-installed.txt"

STEPS=(apt ssh packages shell)

ok()   { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "$*" >&2; exit 1; }

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

file_is_ours() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -qF "$MARKER" "$f" 2>/dev/null
}

# ---- snapshot --------------------------------------------------------------

step_paths() {
  case "$1" in
    apt)
      # Must list the deb822 files too, or restore silently skips them: they
      # are in the snapshot (all_tracked_paths adds them) but would never be
      # looked up here.
      printf '%s\n' "$APT_TUNING_FILE" /etc/apt/sources.list
      extra_source_files
      ;;
    ssh)      printf '%s\n' "$SSH_CONFIG" ;;
    packages) : ;;
    shell)    printf '%s\n' "$BASHRC" ;;
  esac
}

# Debian 12 and later may keep sources in deb822 .sources files instead of
# the classic sources.list, so both have to be tracked.
extra_source_files() {
  local f
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

all_tracked_paths() {
  { local s; for s in "${STEPS[@]}"; do step_paths "$s"; done
    extra_source_files; } | sort -u
}

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
      if cp -p "$p" "$SNAP_FILES/$slot" 2>/dev/null || as_root cp -p "$p" "$SNAP_FILES/$slot" 2>/dev/null; then
        printf '%s\t%s\n' "$slot" "$p" >> "$SNAP_INDEX"
      else
        warn "could not snapshot $p - it will not be restorable"
      fi
    else
      printf '%s\n' "$p" >> "$SNAP_ABSENT"
    fi
  done < <(all_tracked_paths)

  : > "$SNAP_DIR/.taken"
  echo "[*] snapshotted $(wc -l < "$SNAP_INDEX" | tr -d ' ') file(s) -> $SNAP_DIR"
}

restore_file() {
  local path="$1" slot
  slot="$(awk -F'\t' -v p="$path" '$2 == p { print $1; exit }' "$SNAP_INDEX")"
  if [ -n "$slot" ]; then
    if as_root cp -p "$SNAP_FILES/$slot" "$path" 2>/dev/null; then
      ok "restored $path"
    else
      warn "could not restore $path"
    fi
    return 0
  fi
  if [ ! -e "$path" ]; then
    ok "$path already absent"
    return 0
  fi
  if file_is_ours "$path"; then
    as_root rm -f "$path" 2>/dev/null && ok "removed $path (created by this script)"
  else
    warn "$path did not exist before, but no longer looks like ours - left in place"
  fi
}

# ---- step: apt -------------------------------------------------------------

apt_mirror_ok() {
  command -v curl >/dev/null 2>&1 || return 0
  local code
  code="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "https://${APT_MIRROR}/" 2>/dev/null)" || return 1
  [ -n "$code" ] && [ "$code" != "000" ]
}

set_apt() {
  echo "[*] Configuring APT..."
  if ! apt_mirror_ok; then
    warn "mirror ${APT_MIRROR} is not answering - skipping the mirror rewrite"
    warn "writing an unreachable mirror breaks apt, so this step only writes the tuning file"
    warn "set APT_MIRROR=... to a working mirror and re-run"
  else
    # Rewrite only the host, leaving suites and components untouched, so this
    # works for both the classic and the deb822 source formats.
    # '#' as the delimiter, not '|': the pattern uses | for alternation and
    # sed would read it as the end of the s/// expression.
    local f changed=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$f" ] || continue
      if as_root sed -i -E "s#https?://[A-Za-z0-9.-]+(/debian|/ubuntu)#https://${APT_MIRROR}\1#g" "$f"; then
        changed=$((changed + 1))
      fi
    done < <({ printf '%s\n' /etc/apt/sources.list; extra_source_files; })
    if [ "$changed" -eq 0 ]; then
      warn "found no apt source files to rewrite - the mirror was NOT changed"
    else
      ok "mirror set to ${APT_MIRROR} in ${changed} file(s)"
    fi
  fi

  as_root mkdir -p "$(dirname "$APT_TUNING_FILE")"
  as_root tee "$APT_TUNING_FILE" >/dev/null <<EOF
// $MARKER
Acquire::Retries "3";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
EOF
  ok "retry/timeout tuning -> $APT_TUNING_FILE"
  warn "run 'sudo apt-get update' to pick up the new sources"
}

# ---- step: ssh -------------------------------------------------------------

set_ssh() {
  echo "[*] Configuring SSH client..."
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  touch "$SSH_CONFIG"

  # Replace only our own marked block. It goes at the end: ssh takes the first
  # value it sees, so a Host * block placed first would override the
  # more specific blocks a user may have above it.
  sed -i "\|^${BLOCK_BEGIN}\$|,\|^${BLOCK_END}\$|d" "$SSH_CONFIG"
  {
    echo "$BLOCK_BEGIN"
    echo "Host *"
    echo "    ServerAliveInterval 60"
    echo "    ServerAliveCountMax 3"
    echo "    TCPKeepAlive yes"
    echo "$BLOCK_END"
  } >> "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"
  ok "keepalive settings -> $SSH_CONFIG"
}

# ---- step: packages --------------------------------------------------------

set_packages() {
  echo "[*] Installing common packages..."
  local p missing=()
  for p in $PACKAGES; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || missing+=("$p")
  done

  if [ ${#missing[@]} -eq 0 ]; then
    ok "all of them are already installed"
  else
    echo "    installing: ${missing[*]}"
    if as_root apt-get install -y "${missing[@]}"; then
      ok "installed ${#missing[@]} package(s)"
    else
      warn "apt-get install failed"
    fi
  fi

  # Recorded so restore can tell you what changed. restore does not uninstall
  # by default - see unset_packages.
  mkdir -p "$STATE_DIR"
  : > "$PKG_LIST"
  for p in $PACKAGES; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed"; then
      printf '%s\n' "$p" >> "$PKG_LIST"
    fi
  done
  ok "recorded $(wc -l < "$PKG_LIST" | tr -d ' ') package(s) in $PKG_LIST"
}

unset_packages() {
  if [ ! -f "$PKG_LIST" ]; then
    warn "no package record at $PKG_LIST - nothing to report"
    return 0
  fi
  if [ "${PURGE_PACKAGES:-}" != "1" ]; then
    warn "the packages step installed these; they are NOT being removed:"
    sed 's/^/      /' "$PKG_LIST"
    warn "uninstalling shared packages can remove things other software needs."
    warn "set PURGE_PACKAGES=1 to remove them anyway"
    return 0
  fi
  warn "PURGE_PACKAGES=1 - removing the recorded packages"
  # shellcheck disable=SC2046
  as_root apt-get remove -y $(cat "$PKG_LIST")
}

# ---- step: shell -----------------------------------------------------------

set_shell() {
  echo "[*] Configuring shell..."
  touch "$BASHRC"
  sed -i "\|^${BLOCK_BEGIN}\$|,\|^${BLOCK_END}\$|d" "$BASHRC"
  {
    echo "$BLOCK_BEGIN"
    echo "HISTSIZE=100000"
    echo "HISTFILESIZE=200000"
    echo "HISTCONTROL=ignoreboth:erasedups"
    echo "HISTTIMEFORMAT='%F %T '"
    echo "shopt -s histappend"
    if [ "${SHELL_PROMPT:-1}" != "0" ]; then
      printf '%s\n' "PS1='\[\e[32m\]\u@\h\[\e[0m\]:\[\e[34m\]\w\[\e[0m\]\\$ '"
    fi
    echo "$BLOCK_END"
  } >> "$BASHRC"
  ok "history and prompt settings -> $BASHRC"
  warn "open a new shell (or 'source ~/.bashrc') to pick them up"
}

# ---- dispatch --------------------------------------------------------------

run_apply_step() {
  case "$1" in
    apt)      set_apt ;;
    ssh)      set_ssh ;;
    packages) set_packages ;;
    shell)    set_shell ;;
    *)        warn "unknown step: $1"; return 1 ;;
  esac
}

restore_step() {
  case "$1" in
    packages)
      unset_packages
      ;;
    *)
      # File-level restore covers the marked blocks too: a file that existed
      # is put back as it was (without our block), and one we created is
      # removed outright. No separate block stripping is needed.
      local p
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        restore_file "$p"
      done < <(step_paths "$1")
      ;;
  esac
}

cmd_status() {
  echo
  echo "debian_setup status"
  echo

  local mir
  mir="$(grep -rhoE 'https?://[A-Za-z0-9.-]+/(debian|ubuntu)' /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null | sed -E 's|https?://([^/]+)/.*|\1|' | sort -u | tr '\n' ' ')"
  printf '  %-10s %s\n' apt "${mir:-unknown}"
  printf '  %-10s %s\n' "" "$([ -f "$APT_TUNING_FILE" ] && echo 'tuning file present' || echo 'no tuning file')"

  if [ -f "$SSH_CONFIG" ] && grep -qF "$BLOCK_BEGIN" "$SSH_CONFIG" 2>/dev/null; then
    printf '  %-10s applied (%s)\n' ssh "$SSH_CONFIG"
  else
    printf '  %-10s not applied\n' ssh
  fi

  if [ -f "$PKG_LIST" ]; then
    printf '  %-10s %s package(s) recorded\n' packages "$(wc -l < "$PKG_LIST" | tr -d ' ')"
  else
    printf '  %-10s not applied\n' packages
  fi

  if [ -f "$BASHRC" ] && grep -qF "$BLOCK_BEGIN" "$BASHRC" 2>/dev/null; then
    printf '  %-10s applied (%s)\n' shell "$BASHRC"
  else
    printf '  %-10s not applied\n' shell
  fi

  echo
  if [ -f "$SNAP_DIR/.taken" ]; then
    printf '  snapshot:  present - %s\n' "$SNAP_DIR"
  else
    printf '  snapshot:  none - nothing to restore\n'
  fi
  echo
}

usage() {
  cat <<EOF
Usage: bash $(basename "$0") <command> [step ...]

Commands:
  apply      Apply the configuration. Safe to re-run.
  restore    Put everything back the way it was before the first apply.
  status     Show what is currently applied.
  help       This text.

Steps: ${STEPS[*]}

  No step given means all of them.

Environment:
  APT_MIRROR (mirrors.aliyun.com)
  PACKAGES ("$PACKAGES")
  SHELL_PROMPT=0       leave PS1 alone
  PURGE_PACKAGES=1     let restore uninstall the packages step installed

State: $STATE_DIR
EOF
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

  local steps=() s
  if [ $# -eq 0 ]; then
    steps=("${STEPS[@]}")
  else
    for s in "$@"; do
      case " ${STEPS[*]} " in
        *" $s "*) steps+=("$s") ;;
        *) echo "Unknown step: $s" >&2; usage >&2; return 2 ;;
      esac
    done
  fi

  if [ "$cmd" = "apply" ]; then
    snapshot_once
    local rc=0
    for s in "${steps[@]}"; do run_apply_step "$s" || rc=1; done
    [ "$rc" -eq 0 ] && ok "Done."
    echo "Undo with: bash $0 restore"
    return $rc
  fi

  if [ ! -f "$SNAP_DIR/.taken" ]; then
    die "No snapshot at $SNAP_DIR - nothing to restore. Run 'apply' first."
  fi
  local rc=0
  for s in "${steps[@]}"; do restore_step "$s" || rc=1; done
  [ "$rc" -eq 0 ] && ok "Restored."
  echo "The snapshot is kept, so restore can be run again."
  return $rc
}

main "$@"
