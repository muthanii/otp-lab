#!/usr/bin/env bash
# Turn a Debian/Ubuntu server into an OpenBao SSH OTP target.
# Does by hand what target/Dockerfile does for the lab. Run as root, and keep
# an existing SSH session open until an OTP login works from a second terminal.
# Run with --help for the options.
set -euo pipefail

# Release CI replaces "latest" with the release tag, so the script downloads the
# helper from the same release it came from.
SCRIPT_VERSION=latest
REPO=muthanii/otp-lab
DOWNLOAD_URL=${OTP_LAB_DOWNLOAD_URL:-}
HELPER_VERSION=v0.2.4
BIN=/usr/local/bin/vault-ssh-helper
CONF_DIR=/etc/vault-ssh-helper.d
PAM_FILE=/etc/pam.d/sshd
ADMIN_GROUPS=sudo:admin:wheel
# 00- so it wins over distro drop-ins like 50-cloud-init.conf (first value wins in sshd).
SSHD_DROPIN=/etc/ssh/sshd_config.d/00-otp.conf

bao_addr='' ca_cert='' roles=otp mount=ssh helper='' users='' otp_group=otp-users otp_only=false insecure=false

usage_hint() { echo "error: $*" >&2; echo "Run with --help for the options." >&2; exit 1; }
die() { echo "error: $*" >&2; exit 1; }
warn() { echo "    WARNING: $*" >&2; }

usage() {
  cat <<EOF
setup-otp-target.sh $SCRIPT_VERSION
Turn a Debian/Ubuntu server into an OpenBao SSH OTP target. Run as root, and keep
an existing SSH session open until an OTP login works from a second terminal.

Usage:
  sudo ./setup-otp-target.sh --bao-addr URL --users LIST [options]
  curl -fsSL https://github.com/$REPO/releases/latest/download/setup-otp-target.sh \\
    | sudo bash -s -- --bao-addr URL --users LIST [options]

Required:
  --bao-addr URL     OpenBao's address, https://
  --users LIST       comma-separated OTP accounts; created with no usable password
                     if missing, refused if root, system (uid < 1000) or admin accounts

Options:
  --ca-cert FILE     CA that signed OpenBao's certificate (default: system's trusted CAs)
  --roles LIST       OpenBao roles allowed for this server (default: otp)
  --mount PATH       SSH engine mount path (default: ssh)
  --helper FILE      use this vault-ssh-helper instead of downloading it from the release
  --otp-group NAME   only members may log in with an OTP (default: otp-users)
  --otp-only         also turn off public-key login (default: keys keep working)
  --insecure-http    allow plain HTTP to OpenBao; labs only
  -h, --help         show this help and exit

OTP logins are refused for root, system accounts, accounts outside --otp-group and
members of the sudo, admin and wheel groups, so an OTP can never open an account
that can create admins.
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)       usage; exit 0 ;;
    --bao-addr)      bao_addr=$2; shift 2 ;;
    --users)         users=$2; shift 2 ;;
    --ca-cert)       ca_cert=$2; shift 2 ;;
    --roles)         roles=$2; shift 2 ;;
    --mount)         mount=$2; shift 2 ;;
    --helper)        helper=$2; shift 2 ;;
    --otp-group)     otp_group=$2; shift 2 ;;
    --otp-only)      otp_only=true; shift ;;
    --insecure-http) insecure=true; shift ;;
    *) usage_hint "unknown option $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run as root"
[[ -n $bao_addr ]] || usage_hint "--bao-addr is required"
[[ -n $users ]] || usage_hint "--users is required: the accounts that may log in with an OTP, e.g. --users user"
if $insecure; then
  echo "WARNING: --insecure-http sends OTPs to OpenBao unencrypted. Labs only." >&2
else
  [[ $bao_addr == https://* ]] || die "--bao-addr must start with https:// (or pass --insecure-http for a lab)"
  [[ -z $ca_cert || -f $ca_cert ]] || die "--ca-cert $ca_cert: no such file"
fi
users=${users//,/ }
for u in $users; do
  [[ $u =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "--users: '$u' is not a valid account name"
  [[ $u != root ]] || die "--users: root can never log in with an OTP"
  if id "$u" >/dev/null 2>&1; then
    (( $(id -u "$u") >= 1000 )) || die "--users: $u is a system account (uid < 1000)"
    if id -nG "$u" | tr ' ' '\n' | grep -qxE "${ADMIN_GROUPS//:/|}"; then
      die "--users: $u is in an admin group (${ADMIN_GROUPS//:/, }); OTP accounts must not be admins"
    fi
    if command -v sudo >/dev/null && sudo -l -U "$u" 2>/dev/null | grep -qE '^\s+\('; then
      die "--users: $u has sudo rules; OTP accounts must not be able to reach root"
    fi
  fi
done

if [[ -z $DOWNLOAD_URL ]]; then
  if [[ $SCRIPT_VERSION == latest ]]; then
    DOWNLOAD_URL=https://github.com/$REPO/releases/latest/download
  else
    DOWNLOAD_URL=https://github.com/$REPO/releases/download/$SCRIPT_VERSION
  fi
fi

dev_flag=
if $insecure; then dev_flag=-dev; fi

echo "==> 1/8 Checking prerequisites"
if ! command -v sshd >/dev/null; then
  command -v apt-get >/dev/null || die "openssh-server is not installed and apt-get is not available"
  echo "    installing openssh-server"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server >/dev/null
fi
grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config \
  || die "/etc/ssh/sshd_config does not include sshd_config.d/; add the settings by hand"

echo "==> 2/8 Installing vault-ssh-helper to $BIN"
fetch() { curl -fsSL -o "$2" "$1" 2>/dev/null || wget -q -O "$2" "$1" 2>/dev/null; }
if [[ -n $helper ]]; then
  install -m 0755 "$helper" "$BIN"
else
  case $(uname -m) in
    x86_64)        arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *)             arch='' ;;
  esac
  tmp=$(mktemp -d)
  asset=vault-ssh-helper-linux-$arch
  if [[ -n $arch ]] && fetch "$DOWNLOAD_URL/$asset" "$tmp/$asset" && fetch "$DOWNLOAD_URL/SHA256SUMS" "$tmp/SHA256SUMS"; then
    (cd "$tmp" && grep " $asset\$" SHA256SUMS | sha256sum -c --quiet) \
      || die "checksum mismatch for $asset; refusing to install it"
    install -m 0755 "$tmp/$asset" "$BIN"
    echo "    downloaded $asset from $DOWNLOAD_URL"
  elif command -v go >/dev/null; then
    echo "    no download available; building $HELPER_VERSION with Go"
    GOBIN=$tmp CGO_ENABLED=0 go install "github.com/hashicorp/vault-ssh-helper@$HELPER_VERSION"
    install -m 0755 "$tmp/vault-ssh-helper" "$BIN"
  else
    die "could not download vault-ssh-helper for $(uname -m) and Go is not installed; pass --helper FILE"
  fi
  rm -rf "$tmp"
fi

echo "==> 3/8 Writing $CONF_DIR/config.hcl"
install -d -m 0755 "$CONF_DIR"
{
  echo "vault_addr      = \"$bao_addr\""
  echo "ssh_mount_point = \"$mount\""
  echo "allowed_roles   = \"$roles\""
  if [[ -n $ca_cert ]] && ! $insecure; then
    install -m 0644 "$ca_cert" "$CONF_DIR/ca.pem"
    echo "ca_cert         = \"$CONF_DIR/ca.pem\""
  fi
} > "$CONF_DIR/config.hcl"

echo "==> 4/8 Checking the config and the connection to OpenBao"
"$BIN" -verify-only $dev_flag -config="$CONF_DIR/config.hcl" \
  || die "vault-ssh-helper could not verify its setup; nothing in PAM or sshd was changed"

echo "==> 5/8 Setting up OTP accounts (group: $otp_group)"
groupadd -f "$otp_group"
for u in $users; do
  if id "$u" >/dev/null 2>&1; then
    echo "    $u exists"
  else
    # '*' unlocks the account without giving it a usable password, like the lab's user.
    useradd -m -s /bin/bash "$u" && usermod -p '*' "$u"
    echo "    created $u"
  fi
  usermod -aG "$otp_group" "$u"
done

echo "==> 6/8 Updating $PAM_FILE (backup: $PAM_FILE.bak-otp)"
backup_pam() { [[ -f $PAM_FILE.bak-otp ]] || cp -p "$PAM_FILE" "$PAM_FILE.bak-otp"; }
if grep -q vault-ssh-helper "$PAM_FILE"; then
  echo "    already contains vault-ssh-helper"
else
  backup_pam
  helper_line="auth requisite pam_exec.so quiet expose_authtok log=/var/log/vault-ssh.log $BIN $dev_flag -config=$CONF_DIR/config.hcl"
  unix_line="auth optional pam_unix.so not_set_pass use_first_pass nodelay"
  if grep -qE '^@include common-auth' "$PAM_FILE"; then
    # Replace the normal password check with the OTP check, in the same place.
    sed -i "s|^@include common-auth|# @include common-auth  (disabled for OpenBao OTP)\n$helper_line\n$unix_line|" "$PAM_FILE"
  else
    sed -i "1i $helper_line\n$unix_line" "$PAM_FILE"
  fi
fi
if grep -q "user ingroup $otp_group" "$PAM_FILE"; then
  echo "    already restricts OTP logins to $otp_group"
else
  backup_pam
  # Before the helper, so a refused account never uses up an OTP.
  sed -i "0,/vault-ssh-helper/{/vault-ssh-helper/i # OTP logins only for $otp_group members that are not root or admins.\nauth requisite pam_succeed_if.so quiet uid >= 1000\nauth requisite pam_succeed_if.so quiet user ingroup $otp_group\nauth requisite pam_succeed_if.so quiet user notingroup $ADMIN_GROUPS
}" "$PAM_FILE"
fi

echo "==> 7/8 Configuring sshd ($SSHD_DROPIN)"
{
  echo "UsePAM yes"
  echo "KbdInteractiveAuthentication yes"
  echo "PasswordAuthentication no"
  # Root keeps key login (if it has one) but never gets a password or OTP prompt.
  echo "PermitRootLogin prohibit-password"
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

echo "==> 8/8 Checking $otp_group members for admin rights"
members=$(getent group "$otp_group" | cut -d: -f4 | tr ',' ' ')
if [[ -z $members ]]; then
  echo "    $otp_group has no members"
fi
for u in $members; do
  if id -nG "$u" | tr ' ' '\n' | grep -qxE "${ADMIN_GROUPS//:/|}"; then
    warn "$u is in an admin group, so PAM will refuse its OTP logins"
  elif command -v sudo >/dev/null && sudo -l -U "$u" 2>/dev/null | grep -qE '^\s+\('; then
    warn "$u has its own sudo rules, so an OTP for it can reach root; remove them from /etc/sudoers*"
  else
    echo "    $u: ok, no admin rights"
  fi
done

ip=$(hostname -I 2>/dev/null | awk '{print $1}')
# The suggested role allows exactly the --users accounts, which all passed the checks.
first=${users%% *}
allowed=${users// /,}
cat <<EOF

Done. Now, WITHOUT closing this session:
  1. In OpenBao, allow only these accounts and this server's interface IP:
       bao write $mount/roles/${roles%%,*} key_type=otp default_user=$first allowed_users=$allowed cidr_list=${ip:-<server IP>}/32
       (this replaces the role's users and cidr_list; if the role also serves other
        servers, add this server's IP and accounts to them instead)
  2. Get an OTP:   bao write -field=key $mount/creds/${roles%%,*} ip=${ip:-<server IP>}
  3. Log in from a second terminal as one of: $users
If it fails, check /var/log/vault-ssh.log. To undo PAM: cp $PAM_FILE.bak-otp $PAM_FILE
EOF
