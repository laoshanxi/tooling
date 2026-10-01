#!/bin/bash
#
# ssh_setup.sh - install and configure the SSH server on Debian/Ubuntu
#
#   sudo bash ssh_setup.sh apply [options]   apply the configuration
#   sudo bash ssh_setup.sh restore           put sshd_config back as it was
#   bash ssh_setup.sh status                 show current state (no root needed)
#   bash ssh_setup.sh help
#
# apply snapshots sshd_config to /var/backups/ssh_setup/ before touching it,
# and only the first apply snapshots - re-running never overwrites the
# original. restore is what puts that snapshot back.
#
# PasswordAuthentication is allowed by default so users can log in with a
# password; --no-password-login turns it off. sshd_config is validated with
# sshd -t before sshd is restarted.
#
set -euo pipefail

SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_DIR="/var/backups/ssh_setup"
SNAPSHOT="${BACKUP_DIR}/sshd_config.orig"
SNAP_TAKEN="${BACKUP_DIR}/.snapshot-taken"

ROOT_LOGIN=""          # empty = ask
PASSWORD_LOGIN="yes"   # allowed by default

usage() {
	cat <<EOF
Usage: sudo bash $(basename "$0") <command> [options]

Commands:
  apply      Install openssh-server if needed and apply the configuration.
             Safe to re-run; the snapshot is only taken once.
  restore    Copy the snapshotted sshd_config back and restart sshd.
             Does not uninstall openssh-server or touch any firewall rule.
  status     Show the current sshd_config settings and snapshot state.
  help       This text.

Options for apply:
  --root-login          PermitRootLogin yes
                        Root may log in with a password. Convenient on
                        throwaway VMs, but exposes root to brute force.

  --no-root-login       PermitRootLogin prohibit-password
                        Root may still log in with a key.

  --password-login      PasswordAuthentication yes (default)

  --no-password-login   PasswordAuthentication no
                        Key-only logins for everyone. Note this also rules out
                        --root-login by password, leaving root key-only.

  With neither root flag the script asks. If stdin is not a terminal it
  defaults to --no-root-login.
EOF
}

die() { echo "$*" >&2; exit 1; }

need_root() {
	[ "$(id -u)" -eq 0 ] || die "This command needs root: sudo bash $0 $1"
}

# /run/systemd/system is the reliable test for systemd actually being the init
# system. Testing for the systemctl binary or `list-unit-files` is not enough:
# systemctl gets pulled in as a dependency without systemd running, and
# read-only queries like list-unit-files still exit 0 in that state.
have_systemd() { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }

# Set a directive, removing any existing occurrence (commented out or not)
# first so repeated runs stay idempotent instead of stacking duplicate lines.
set_sshd_option() {
	local key="$1" value="$2"
	sed -i -E "/^[[:space:]]*#?[[:space:]]*${key}[[:space:]]/d" "$SSHD_CONFIG"
	echo "${key} ${value}" >>"$SSHD_CONFIG"
}

# Validate and restart, restoring the given file if validation fails.
# A broken sshd_config would otherwise lock you out of the machine on restart.
validate_and_restart() {
	local fallback="$1"
	mkdir -p /run/sshd
	if command -v sshd >/dev/null 2>&1; then
		if ! sshd -t; then
			if [ -n "$fallback" ] && [ -f "$fallback" ]; then
				cp -p "$fallback" "$SSHD_CONFIG"
				echo "ERROR: sshd_config failed validation, restored $fallback" >&2
			else
				echo "ERROR: sshd_config failed validation" >&2
			fi
			exit 1
		fi
		echo "sshd_config validated OK"
	else
		echo "[!] sshd not found in PATH - skipping config validation"
	fi

	if have_systemd; then
		systemctl restart ssh
		systemctl enable ssh
	else
		echo "[!] systemd is not the init system here - start sshd yourself if needed"
		echo "    e.g. /usr/sbin/sshd"
	fi
}

cmd_apply() {
	need_root apply

	# Settle the root-login choice before doing any work
	if [[ -z "$ROOT_LOGIN" ]]; then
		if [[ -t 0 ]]; then
			echo
			echo "Allow root to log in over SSH with a password?"
			echo "  yes - convenient on throwaway VMs, but exposes root to brute force"
			echo "  no  - root may still log in with a key (recommended)"
			read -r -p "Allow root password login? [y/N] " reply || reply=""
			case "$reply" in
				[yY]|[yY][eE][sS]) ROOT_LOGIN="yes" ;;
				*)                 ROOT_LOGIN="no" ;;
			esac
		else
			ROOT_LOGIN="no"
			echo "[!] stdin is not a terminal and no flag was given - defaulting to --no-root-login"
			echo "[!] pass --root-login if you do want root password login"
		fi
	fi

	if [[ "$ROOT_LOGIN" == "yes" ]]; then
		ROOT_LOGIN_VALUE="yes"
		if [[ "$PASSWORD_LOGIN" == "yes" ]]; then
			echo "[!] root login over SSH will be ENABLED - root will be reachable by password"
		else
			echo "[*] root login over SSH limited to key authentication"
		fi
	else
		ROOT_LOGIN_VALUE="prohibit-password"
		echo "[*] root login over SSH limited to key authentication"
	fi
	if [[ "$PASSWORD_LOGIN" == "yes" ]]; then
		echo "[*] password authentication enabled"
	else
		echo "[*] password authentication DISABLED - key-only logins"
	fi

	echo "Setting up SSH remote login..."

	# Install SSH server
	apt-get update
	apt-get install -y openssh-server

	# Snapshot once, before the first modification. A later apply must not
	# overwrite this, or restore would only undo the most recent run.
	mkdir -p "$BACKUP_DIR"
	chmod 700 "$BACKUP_DIR"
	if [ -f "$SNAP_TAKEN" ]; then
		echo "[*] snapshot already exists, keeping the original: $SNAPSHOT"
	else
		cp -p "$SSHD_CONFIG" "$SNAPSHOT"
		: > "$SNAP_TAKEN"
		echo "[*] snapshotted $SSHD_CONFIG -> $SNAPSHOT"
	fi

	set_sshd_option PermitRootLogin "$ROOT_LOGIN_VALUE"
	set_sshd_option PasswordAuthentication "$PASSWORD_LOGIN"

	validate_and_restart "$SNAPSHOT"

	# Open firewall port (only if ufw is actually installed)
	if command -v ufw >/dev/null 2>&1; then
		ufw allow 22
	else
		echo "[!] ufw not found - skipping firewall rule; open port 22 yourself if needed"
	fi

	echo "SSH setup complete!"
	echo "Connection command: ssh username@server_ip_address"
	echo "Undo with: sudo bash $0 restore"
}

cmd_restore() {
	need_root restore

	if [ ! -f "$SNAPSHOT" ]; then
		die "No snapshot at $SNAPSHOT - nothing to restore. Run 'apply' first."
	fi

	echo "Restoring $SSHD_CONFIG from $SNAPSHOT"
	cp -p "$SNAPSHOT" "$SSHD_CONFIG"

	# The snapshot was valid when taken, so validation failing here means
	# something else is wrong (a missing Include target, for instance).
	# validate_and_restart reports it and exits non-zero rather than leaving a
	# half-restored state.
	validate_and_restart ""

	echo "Restored. openssh-server is still installed and the firewall rule is untouched."
	echo "The snapshot is kept, so restore can be run again."
}

cmd_status() {
	echo
	echo "ssh_setup status"
	echo
	echo "  sshd_config settings:"
	local key
	for key in PermitRootLogin PasswordAuthentication; do
		local active
		active="$(grep -E "^[[:space:]]*${key}[[:space:]]" "$SSHD_CONFIG" 2>/dev/null | tail -1 || true)"
		if [ -n "$active" ]; then
			printf '    %-24s %s\n' "$key" "${active#*[[:space:]]}"
		else
			printf '    %-24s %s\n' "$key" "not set (sshd default)"
		fi
	done

	echo
	if [ -r "$SNAPSHOT" ]; then
		printf '  snapshot:  %s\n' "$SNAPSHOT"
		printf '             taken %s\n' "$(stat -c %y "$SNAPSHOT" 2>/dev/null | cut -d. -f1 || echo unknown)"
	else
		printf '  snapshot:  none (or not readable without root)\n'
		printf '             %s\n' "$BACKUP_DIR"
	fi

	echo
	if command -v sshd >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 && have_systemd; then
		if systemctl is-active --quiet ssh; then
			printf '  sshd:      running\n'
		else
			printf '  sshd:      not running\n'
		fi
	else
		printf '  sshd:      cannot determine (no systemd)\n'
	fi
	echo
}

# ---- argument handling ----------------------------------------------------

CMD="${1:-}"
# Not `[ $# -gt 0 ] && shift` - under set -e that statement fails when there
# are no arguments, killing the script before it can print usage.
if [ $# -gt 0 ]; then
	shift
fi

case "$CMD" in
	help|-h|--help)
		usage; exit 0 ;;
	apply|restore|status) ;;
	"")
		usage >&2; exit 1 ;;
	*)
		echo "Unknown command: $CMD" >&2
		usage >&2
		exit 2
		;;
esac

if [ "$CMD" != "apply" ] && [ $# -gt 0 ]; then
	echo "Note: options only apply to 'apply'; ignoring them for '$CMD'." >&2
fi

for arg in "$@"; do
	case "$arg" in
		--root-login)        ROOT_LOGIN="yes" ;;
		--no-root-login)     ROOT_LOGIN="no" ;;
		--password-login)    PASSWORD_LOGIN="yes" ;;
		--no-password-login) PASSWORD_LOGIN="no" ;;
		-h|--help)           usage; exit 0 ;;
		*) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
	esac
done

if [[ "$ROOT_LOGIN" == "yes" && "$PASSWORD_LOGIN" == "no" ]]; then
	echo "[!] --root-login with --no-password-login leaves root key-only," >&2
	echo "    which is the same as --no-root-login. Continuing anyway." >&2
fi

case "$CMD" in
	apply)   cmd_apply ;;
	restore) cmd_restore ;;
	status)  cmd_status ;;
esac
