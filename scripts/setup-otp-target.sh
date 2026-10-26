#!/usr/bin/env bash
# Turn a Debian/Ubuntu server into an OpenBao SSH OTP target.
# Does by hand what target/Dockerfile does for the lab. Run as root, and keep
# an existing SSH session open until an OTP login works from a second terminal.
#
#   sudo ./setup-otp-target.sh --bao-addr https://bao.example.com:8200 \
#        --ca-cert /path/to/ca.pem --roles otp [--helper ./vault-ssh-helper] [--otp-only]
#
# --helper       path to a vault-ssh-helper binary (default: build it with Go)
# --roles        comma-separated OpenBao roles allowed for this server (default: otp)
# --mount        SSH engine mount path (default: ssh)
# --otp-only     also turn off public-key login (default: keys keep working)
# --insecure-http  allow plain HTTP to OpenBao; labs only, replaces --ca-cert
set -euo pipefail

HELPER_VERSION=v0.2.4
BIN=/usr/local/bin/vault-ssh-helper
CONF_DIR=/etc/vault-ssh-helper.d
PAM_FILE=/etc/pam.d/sshd
# 00- so it wins over distro drop-ins like 50-cloud-init.conf (first value wins in sshd).
SSHD_DROPIN=/etc/ssh/sshd_config.d/00-otp.conf

bao_addr='' ca_cert='' roles=otp mount=ssh helper='' otp_only=false insecure=false

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --bao-addr)      bao_addr=$2; shift 2 ;;
    --ca-cert)       ca_cert=$2; shift 2 ;;
    --roles)         roles=$2; shift 2 ;;
    --mount)         mount=$2; shift 2 ;;
    --helper)        helper=$2; shift 2 ;;
    --otp-only)      otp_only=true; shift ;;
    --insecure-http) insecure=true; shift ;;
    *) die "unknown option $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run as root"
[[ -n $bao_addr ]] || die "--bao-addr is required"
if $insecure; then
  echo "WARNING: --insecure-http sends OTPs to OpenBao unencrypted. Labs only." >&2
else
  [[ -f $ca_cert ]] || die "--ca-cert FILE is required (or --insecure-http for a lab)"
fi
command -v sshd >/dev/null || die "openssh-server is not installed"
grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config \
  || die "/etc/ssh/sshd_config does not include sshd_config.d/; add the settings by hand"

dev_flag=
if $insecure; then dev_flag=-dev; fi

echo "==> 1/5 Installing vault-ssh-helper to $BIN"
if [[ -n $helper ]]; then
  install -m 0755 "$helper" "$BIN"
elif command -v go >/dev/null; then
  GOBIN=$(mktemp -d) CGO_ENABLED=0 go install "github.com/hashicorp/vault-ssh-helper@$HELPER_VERSION"
  install -m 0755 "$GOBIN/vault-ssh-helper" "$BIN"
else
  die "no --helper given and Go is not installed to build it"
fi

echo "==> 2/5 Writing $CONF_DIR/config.hcl"
install -d -m 0755 "$CONF_DIR"
{
  echo "vault_addr      = \"$bao_addr\""
  echo "ssh_mount_point = \"$mount\""
  echo "allowed_roles   = \"$roles\""
  if ! $insecure; then
    install -m 0644 "$ca_cert" "$CONF_DIR/ca.pem"
    echo "ca_cert         = \"$CONF_DIR/ca.pem\""
  fi
} > "$CONF_DIR/config.hcl"

echo "==> 3/5 Checking the config and the connection to OpenBao"
"$BIN" -verify-only $dev_flag -config="$CONF_DIR/config.hcl" \
  || die "vault-ssh-helper could not verify its setup; nothing in PAM or sshd was changed"

echo "==> 4/5 Updating $PAM_FILE (backup: $PAM_FILE.bak-otp)"
if grep -q vault-ssh-helper "$PAM_FILE"; then
  echo "    already contains vault-ssh-helper, leaving it alone"
else
  cp -p "$PAM_FILE" "$PAM_FILE.bak-otp"
  helper_line="auth requisite pam_exec.so quiet expose_authtok log=/var/log/vault-ssh.log $BIN $dev_flag -config=$CONF_DIR/config.hcl"
  unix_line="auth optional pam_unix.so not_set_pass use_first_pass nodelay"
  if grep -qE '^@include common-auth' "$PAM_FILE"; then
    # Replace the normal password check with the OTP check, in the same place.
    sed -i "s|^@include common-auth|# @include common-auth  (disabled for OpenBao OTP)\n$helper_line\n$unix_line|" "$PAM_FILE"
  else
    sed -i "1i $helper_line\n$unix_line" "$PAM_FILE"
  fi
fi

echo "==> 5/5 Configuring sshd ($SSHD_DROPIN)"
{
  echo "UsePAM yes"
  echo "KbdInteractiveAuthentication yes"
  echo "PasswordAuthentication no"
  if $otp_only; then echo "PubkeyAuthentication no"; fi
} > "$SSHD_DROPIN"

if ! sshd -t; then
  rm -f "$SSHD_DROPIN"
  [[ -f $PAM_FILE.bak-otp ]] && cp -p "$PAM_FILE.bak-otp" "$PAM_FILE"
  die "sshd config test failed; PAM and sshd changes were rolled back"
fi

if command -v systemctl >/dev/null && systemctl is-system-running >/dev/null 2>&1; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
  echo "    sshd reloaded"
else
  echo "    no systemd here; restart sshd yourself"
fi

cat <<EOF

Done. Now, WITHOUT closing this session:
  1. Make sure the OpenBao role's cidr_list includes this server's interface IP:
       $(hostname -I 2>/dev/null || echo "(run: ip addr)")
  2. Get an OTP:   bao write -field=key $mount/creds/<role> ip=<that IP>
  3. Log in from a second terminal and paste it.
If it fails, check /var/log/vault-ssh.log. To undo PAM: cp $PAM_FILE.bak-otp $PAM_FILE
EOF
