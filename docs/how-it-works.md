# How it works

[← Back to README](../README.md)

## How an OTP login works

```mermaid
sequenceDiagram
    autonumber
    actor You as 🧑 You
    participant Bao as 🛎 OpenBao
    participant SSHD as 🐧 sshd (target)
    participant Helper as 🔐 vault-ssh-helper

    Note over You,Bao: EVERY LOGIN: get a fresh password
    You->>Bao: bao write ssh/creds/otp ip=172.30.0.10
    Bao->>Bao: Check role otp:<br/>is the IP inside cidr_list?
    Bao->>Bao: Store a salted hash of the OTP<br/>with user and IP
    Bao-->>You: OTP (e.g. 2f7e25a2-...)<br/>for user at 172.30.0.10

    Note over You,Helper: LOGGING IN
    You->>SSHD: ssh -p 2230 user@localhost
    SSHD-->>You: Password prompt
    You->>SSHD: Paste the OTP
    SSHD->>Helper: PAM hands over the typed OTP
    Helper->>Bao: PUT ssh/verify {otp}
    Bao->>Bao: Known and unused?<br/>Delete it so it can't be reused
    Bao-->>Helper: username=user, ip=172.30.0.10
    Helper->>Helper: Does the user match?<br/>Is that IP one of mine?
    Helper-->>SSHD: exit 0 (OK)
    SSHD-->>You: ✅ Welcome, you are in
```

## Why the same OTP fails the second time

OpenBao deletes an OTP the moment it is verified, so reusing one goes like this:

```mermaid
sequenceDiagram
    actor You as 🧑 You
    participant SSHD as 🐧 sshd
    participant Helper as 🔐 vault-ssh-helper
    participant Bao as 🛎 OpenBao

    You->>SSHD: ssh -p 2230 user@localhost<br/>+ the OTP you already used
    SSHD->>Helper: PAM hands over the OTP
    Helper->>Bao: PUT ssh/verify {otp}
    Bao-->>Helper: ❌ OTP not found
    Helper-->>SSHD: exit 1 (rejected)
    SSHD-->>You: Permission denied
```

## What the target checks, in order

Once [`setup-otp-target.sh`](../scripts/setup-otp-target.sh) has set it up, the target checks every SSH login like this:

```mermaid
flowchart TD
    A[ssh connection on port 2230] --> R{"Logging in as root?"}
    R -- "PermitRootLogin prohibit-password,<br/>and root has no SSH key" --> X1[❌ refused]
    R -- no --> B{"Which login method?"}
    B -- "password: turned off<br/>in 00-otp.conf" --> X1
    B -- "SSH key: user has none" --> X1
    B -- "keyboard-interactive" --> G{"PAM: uid ≥ 1000, in otp-users,<br/>not in sudo / admin / wheel?"}
    G -- no --> X2[❌ Permission denied<br/>OTP not used up]
    G -- yes --> C[PAM: pam_exec runs vault-ssh-helper]
    C --> D{"OpenBao: OTP valid and unused?"}
    D -- no --> X3[❌ Permission denied]
    D -- yes --> E{"Helper: username is user<br/>and IP is 172.30.0.10?"}
    E -- no --> X3
    E -- yes --> F[✅ Logged in as user]
```

Every PAM step is `requisite`, and the normal Linux password check (`common-auth`) is left out, so any failed check ends the login with no fallback. The `user` account has its password set to `*`, so no typed password could ever work on its own.

## Why an OTP can't open an admin account

An OTP must never log someone in to an account that can create admins, so the lab blocks that in three places:

| Layer | Rule | Stops |
|---|---|---|
| OpenBao role | `allowed_users=user` | OpenBao won't even issue an OTP for `root` or any other account. Without it, the role issues OTPs for **any** username |
| sshd (`/etc/ssh/sshd_config.d/00-otp.conf`, written by the script) | `PermitRootLogin prohibit-password`, `PasswordAuthentication no` | Root logging in with a password or OTP. Root could still use an SSH key, but the lab's root has none |
| PAM (`/etc/pam.d/sshd`, edited by the script) | `uid >= 1000`, `ingroup otp-users`, `notingroup sudo:admin:wheel` | System accounts, accounts not approved for OTP, and anyone in an admin group. These run **before** the OTP check, so a refused login doesn't use up the OTP |

`user` is in `otp-users` and nothing else, has no sudo rights, and has no usable password, so it has no way to become root or add users. A personal rule in `/etc/sudoers.d/` isn't caught by the group check, which is why the [real-server script](real-server.md) warns about OTP accounts that have one.

## Which IP the OTP is for

The target sees each client at a different address: traffic through the published port arrives from Docker's gateway (`172.30.0.1`), and traffic from the OpenBao container arrives straight from `172.30.0.2`. Both work, because the IP inside an OTP is the **target's** address, not the client's. It answers "which server is this OTP for?", not "who is logging in?".

## What gets written where

```mermaid
flowchart LR
    subgraph baobox["🛎 openbao"]
        db[("raft.db / vault.db<br/>OTP hashes, role, engine")]
        kh1["~/.ssh/known_hosts<br/>target's host keys"]
    end
    subgraph target["🐧 target"]
        log["/var/log/vault-ssh.log<br/>every attempt"]
        wtmp["/var/log/wtmp, lastlog<br/>successful logins"]
        hist["/home/user/.bash_history"]
    end
    subgraph dev["🧑 dev container"]
        kh2["~/.ssh/known_hosts<br/>[localhost]:2230"]
    end

    issue["bao write ssh/creds/otp"] --> db
    verify["helper verifies OTP"] --> db
    verify --> log
    login["first ssh to target"] --> kh1
    login --> kh2
    session["login and logout"] --> wtmp
    session --> hist
```

| Machine | You create (setup) | Created by each login |
|---|---|---|
| OpenBao | [`bao/bao.hcl`](../bao/bao.hcl), [`bao/Dockerfile`](../bao/Dockerfile). The engine and role live in its storage, not in files | An OTP hash in `raft.db`, deleted again on use. There's no file per OTP |
| target | Nothing by hand: [`setup-otp-target.sh`](../scripts/setup-otp-target.sh) installs `/usr/local/bin/vault-ssh-helper` and writes `/etc/vault-ssh-helper.d/config.hcl`, `/etc/pam.d/sshd` (backup in `sshd.bak-otp`) and `/etc/ssh/sshd_config.d/00-otp.conf` | A block in `/var/log/vault-ssh.log` (the first place to look when a login fails), login records, shell history |
| Whoever runs `ssh` | Nothing | A `known_hosts` entry the first time. A recreated target (`docker compose down` then `up`) gets new host keys when you set it up again, so expect a "host key changed" warning |

## OTP vs signed keys

| | OTP (this lab) | Signed keys |
|---|---|---|
| What you bring | Nothing, just ask OpenBao | Your own key pair |
| What OpenBao gives you | A password that works once | A certificate valid for a set time |
| OpenBao needed at login time? | **Yes**, the server asks it every time | No, the server checks the signature itself |
| Extra software on the server | `vault-ssh-helper` + PAM changes | Just `TrustedUserCAKeys` in sshd |
| Password is sent over the network | Yes, so use TLS outside a lab | No |
