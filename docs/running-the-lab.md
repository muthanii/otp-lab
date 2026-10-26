# Running the lab

[← Back to README](../README.md)

## Start it

From the `otp-lab` folder, in a dev container terminal (it has Docker and the `bao` CLI):

```sh
docker compose up -d --build
```

The ports are published inside the dev container. To open the OpenBao UI from a Windows browser, forward `8210` in VS Code's **Ports** tab, then go to http://localhost:8210.

## One-time setup (after a fresh start)

OpenBao runs as a real server with Raft storage, not in dev mode, so it starts uninitialised and sealed:

```sh
export BAO_ADDR=http://127.0.0.1:8210
bao operator init                 # save the unseal keys and root token somewhere safe
bao operator unseal               # run 3 times, one key each
bao login                         # paste the root token

bao secrets enable ssh
bao write ssh/roles/otp \
    key_type=otp \
    default_user=user \
    allowed_users=user \
    cidr_list=172.30.0.0/24
```

`allowed_users=user` matters: without it, OpenBao issues OTPs for **any** username, including `root` and admin accounts. If you created the role before, run the `bao write ssh/roles/otp` command again to add it. The target refuses root and admin logins on its own too (see [what the target checks](how-it-works.md#what-the-target-checks-in-order)), but the role is the first line of defence.

Keep the init output outside the containers and outside this folder, for example in a password manager. Storing unseal keys next to OpenBao's data defeats the point of sealing.

After a container restart OpenBao is sealed again: run `bao operator unseal` three times before logging in.

You can also run these inside the OpenBao container (`docker compose exec openbao sh`). There `BAO_ADDR` is already set to `http://127.0.0.1:8200`, so skip the `export`.

## Set up the target

`target` starts as a **fresh Ubuntu server**: no SSH server, no accounts, no OTP setup. You set it up with [`setup-otp-target.sh`](../scripts/setup-otp-target.sh), exactly as you would a real server. OpenBao must be unsealed, since the script checks the connection before changing anything.

```sh
docker compose exec target bash
# inside the target:
apt-get update && apt-get install -y wget
wget -q https://github.com/muthanii/otp-lab/releases/latest/download/setup-otp-target.sh
wget -q https://github.com/muthanii/otp-lab/releases/latest/download/SHA256SUMS
sha256sum -c --ignore-missing SHA256SUMS
chmod +x setup-otp-target.sh
./setup-otp-target.sh --bao-addr http://172.30.0.2:8200 --insecure-http --users user
exit
```

| Option | Why in the lab |
|---|---|
| `--bao-addr http://172.30.0.2:8200` | OpenBao's address inside the lab network. `localhost:8210` only works from the dev container |
| `--insecure-http` | The lab's OpenBao uses plain HTTP |
| `--users user` | Matches the `otp` role's `default_user` and `allowed_users` |

The script installs `openssh-server`, downloads `vault-ssh-helper`, creates `user`, sets up PAM and sshd, and starts sshd (the container has no systemd). Every step should show a green ✓. Skip the role command it prints at the end: the `otp` role above already covers the whole lab network, and the printed command would narrow it to this one server.

### After a restart

| What you ran | What happens to the target | What to do |
|---|---|---|
| `docker compose restart`, or the dev container restarted | Setup is kept, but sshd isn't running (nothing starts it in a container) | Rerun the script, or `docker compose exec target sh -c 'mkdir -p /run/sshd && /usr/sbin/sshd'` |
| `docker compose down` then `up` | A new, fresh target | Set it up again |

### Testing a change to the script

To try a local copy before it's released, copy it in instead of downloading it. It still downloads `vault-ssh-helper` from the latest release:

```sh
docker compose cp scripts/setup-otp-target.sh target:/root/setup-otp-target.sh
docker compose exec target /root/setup-otp-target.sh --bao-addr http://172.30.0.2:8200 --insecure-http --users user
```

## More fresh servers (try servers)

To test against several servers, or keep `target` untouched, start more fresh Ubuntu containers on the lab network, each with its own IP and port:

```sh
docker run -d --name try-server --hostname try-server --network otp-lab_lab \
  --ip 172.30.0.20 -p 2240:22 ubuntu:26.04 sleep infinity
```

Then set it up exactly like the target (use `docker exec -it try-server bash` to get in). The `otp` role already covers `172.30.0.20`. Log in with an OTP for **`172.30.0.20`**, using `ssh user@172.30.0.20` or `ssh -p 2240 user@localhost`. Remove it with `docker rm -f try-server`.

## A token that can only request OTPs (optional)

The root token can do anything. For everyday logins, or to hand to a script, create a token limited to this role:

```sh
bao policy write otp-only - <<'EOF'
path "ssh/creds/otp" { capabilities = ["update"] }
EOF
bao token create -policy=otp-only -ttl=8h -field=token
```

## Every login

After [setting up the target](#set-up-the-target):

You can log in from the dev container or from the OpenBao container. The only difference is the address you SSH to.

**From the dev container**, through the published port:

```sh
bao write -field=key ssh/creds/otp ip=172.30.0.10   # prints the OTP
ssh -p 2230 user@localhost                          # paste it at the prompt
```

**From the OpenBao container**, straight across the `lab` network:

```sh
docker compose exec openbao sh
# inside the container:
export BAO_TOKEN=<token>
bao write -field=key ssh/creds/otp ip=172.30.0.10
ssh user@172.30.0.10                                # port 22, no -p needed
```

The OpenBao image is the stock one plus an ssh client, added in [`bao/Dockerfile`](../bao/Dockerfile).

In both cases, ask for the OTP for **`172.30.0.10`**, the target's address inside the lab. An OTP issued for `localhost` or `127.0.0.1` is rejected, because the helper checks the IP against its own network interfaces.

## When a login fails

```sh
docker compose exec target cat /var/log/vault-ssh.log   # what the helper saw
```

If there's no such file, the target hasn't been set up, or PAM refused the account before the OTP check (check the username). "Connection refused" means sshd isn't running: see [after a restart](#after-a-restart).

| You see in the helper log | Meaning |
|---|---|
| `user@172.30.0.10 authenticated!` | Success |
| `OTP not found` | Already used, or never issued |
| `uuid string is wrong length` | Not an OTP at all (typo or a normal password) |
| `Vault is sealed` | Unseal OpenBao |

When the setup script itself stops at step 4, its error says why: OpenBao is sealed, not initialised, or unreachable at that address.

## Tear down

```sh
docker compose down -v   # -v also deletes OpenBao's data, so you'll need the setup again
docker rm -f try-server  # if you started any try servers
```

The next `up` gives you a fresh target again.
