# Setting up a real server

[← Back to README](../README.md)

On a real Debian or Ubuntu server, [`scripts/setup-otp-target.sh`](../scripts/setup-otp-target.sh) does what [`target/Dockerfile`](../target/Dockerfile) does for the lab. Download the script from a [release](https://github.com/muthanii/otp-lab/releases/latest) (each release has `setup-otp-target.sh` and its `SHA256SUMS`; the [README](../README.md#use-it-on-a-real-server) has the commands), copy a `vault-ssh-helper` binary to the server, then run as root:

```sh
sudo ./setup-otp-target.sh --bao-addr https://bao.example.com:8200 \
     --ca-cert ca.pem --roles otp --helper ./vault-ssh-helper
```

## What the script does

```mermaid
flowchart TD
    S1["1 · Install vault-ssh-helper"] --> S2["2 · Write config.hcl<br/>(https + ca_cert)"]
    S2 --> S3{"3 · verify-only:<br/>can it reach OpenBao?"}
    S3 -- no --> STOP1["❌ Stop<br/>PAM and sshd untouched"]
    S3 -- yes --> S4["4 · Edit /etc/pam.d/sshd<br/>OTP check + otp-users / admin guards<br/>backup: sshd.bak-otp"]
    S4 --> S5{"5 · Add sshd_config.d/00-otp.conf<br/>sshd -t passes?"}
    S5 -- no --> STOP2["↩ Roll back PAM and sshd"]
    S5 -- yes --> S6["Reload sshd"]
    S6 --> S7["6 · Warn about otp-users members<br/>with admin or sudo rights ✅"]
```

| Option | Meaning |
|---|---|
| `--bao-addr URL` | OpenBao's address (required) |
| `--ca-cert FILE` | CA that signed OpenBao's TLS certificate (required unless `--insecure-http`) |
| `--roles LIST` | Comma-separated OpenBao roles allowed for this server (default `otp`) |
| `--helper FILE` | A `vault-ssh-helper` binary. Without it, the script builds one with Go |
| `--mount PATH` | SSH engine mount path (default `ssh`) |
| `--otp-group NAME` | Only members of this group may log in with an OTP (default `otp-users`). Created if missing |
| `--otp-only` | Also turn off public-key login |
| `--insecure-http` | Allow plain HTTP to OpenBao. Labs only |

Running it again is safe: it doesn't duplicate PAM lines. On a server set up with an older version, it adds the group checks in front of the existing OTP check.

## Keeping OTP accounts away from admin rights

An OTP must never open an account that can create admins. The script sets up the same layers as the lab (see [why an OTP can't open an admin account](how-it-works.md#why-an-otp-cant-open-an-admin-account)), and you finish them:

1. **Limit the role in OpenBao** to the OTP accounts on this server. Without `allowed_users`, the role issues OTPs for any username, including `root`:

   ```sh
   bao write ssh/roles/otp key_type=otp default_user=alice allowed_users=alice,dave cidr_list=10.0.1.5/32
   ```

2. **Add only non-admin accounts to `otp-users`** with `usermod -aG otp-users <name>`. PAM refuses OTP logins for root, system accounts (uid below 1000), anyone outside `otp-users`, and anyone in `sudo`, `admin` or `wheel`. Admins keep using keys.
3. **Read the warnings from step 6.** PAM can't see personal rules in `/etc/sudoers.d/`, so the script lists `otp-users` members that have one. Remove those rules, or that account can reach root with an OTP.

## How the lab files map to a real server

| Lab file | On a real server |
|---|---|
| [`target/config.hcl`](../target/config.hcl) | Written by the script, with `https://`, `ca_cert` and the role names you pass |
| [`target/pam-sshd`](../target/pam-sshd) | **Not copied.** The script edits the existing `/etc/pam.d/sshd` and swaps `common-auth` for the same group checks and OTP check, without `-dev` |
| [`target/otp.conf`](../target/otp.conf) | Written as `00-otp.conf`, so it wins over drop-ins like `50-cloud-init.conf` that turn password login back on. Uses `PermitRootLogin prohibit-password` instead of `no`, so root keeps key login if you rely on it |
| [`target/Dockerfile`](../target/Dockerfile) | Not used. The script installs the helper and creates the `otp-users` group; you create the accounts and add them to it |

## Before and after running it

- **Keep your current SSH session open** until an OTP login works from a second terminal. To undo the PAM change: `cp /etc/pam.d/sshd.bak-otp /etc/pam.d/sshd`.
- **Public-key login keeps working** unless you pass `--otp-only`. That's your way in if OpenBao is down, because the server asks OpenBao at every OTP login.
- **Use the server's own interface IP** in the role's `cidr_list` and when requesting OTPs. A cloud VM behind NAT knows its private IP (e.g. `10.0.1.5`), not the public one you connect to. The script prints the right one at the end.
- **Name the role in `--roles`** rather than `*`, and give people a limited policy (see [running the lab](running-the-lab.md#a-token-that-can-only-request-otps-optional)) instead of the root token.

## Lab-only shortcuts

These are fine for the lab but not for a real server:

- OpenBao listens on plain HTTP (`tls_disable = true`), and the helper runs with `-dev` so it accepts that. For anything real, turn on TLS and give the helper a `ca_cert`.
- `allowed_roles = "*"` lets any OpenBao role issue OTPs for the target.
- Public-key login is off in [`target/otp.conf`](../target/otp.conf), so OTP is the only way in. That's also why the lab can use `PermitRootLogin no`.
- The OpenBao container has an ssh client so it can act as the client. A real OpenBao server wouldn't run one.
- `vault-ssh-helper` is built from source in [`target/Dockerfile`](../target/Dockerfile) because HashiCorp's download site is geo-blocked here.
