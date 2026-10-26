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
    cidr_list=172.30.0.0/24
```

Keep the init output outside the containers and outside this folder, for example in a password manager. Storing unseal keys next to OpenBao's data defeats the point of sealing.

After a container restart OpenBao is sealed again: run `bao operator unseal` three times before logging in.

You can also run these inside the OpenBao container (`docker compose exec openbao sh`). There `BAO_ADDR` is already set to `http://127.0.0.1:8200`, so skip the `export`.

## A token that can only request OTPs (optional)

The root token can do anything. For everyday logins, or to hand to a script, create a token limited to this role:

```sh
bao policy write otp-only - <<'EOF'
path "ssh/creds/otp" { capabilities = ["update"] }
EOF
bao token create -policy=otp-only -ttl=8h -field=token
```

## Every login

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
docker compose logs target                              # sshd messages
```

| You see in the helper log | Meaning |
|---|---|
| `user@172.30.0.10 authenticated!` | Success |
| `OTP not found` | Already used, or never issued |
| `uuid string is wrong length` | Not an OTP at all (typo or a normal password) |
| `Vault is sealed` | Unseal OpenBao |

## Tear down

```sh
docker compose down -v   # -v also deletes OpenBao's data, so you'll need the setup again
```
