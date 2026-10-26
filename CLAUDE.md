# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Docker Compose lab that demonstrates OpenBao's SSH **one-time password (OTP)** mode: an SSH server that accepts nothing except single-use passwords issued and verified by OpenBao. There is no application code or test suite — only container and daemon configuration, plus `scripts/setup-otp-target.sh`, which applies the same target setup to a real Debian/Ubuntu server. User-facing docs live in `README.md` and `docs/`.

Host ports are **8210** (OpenBao) and **2230** (SSH).

## Commands

The dev container provides Docker (docker-in-docker) and the `bao` CLI (OpenBao 2.7.1).

```sh
docker compose up -d --build          # start the lab (rebuild after editing target/* or bao/Dockerfile)
docker compose logs -f target         # sshd output (-e sends it to stderr)
docker compose exec target cat /var/log/vault-ssh.log   # helper's verify log, first stop when a login fails
docker compose down -v                # tear down, including the Raft data volume (forces re-init)
```

CI (`.github/workflows/ci.yml`) runs shellcheck, `docker compose config` and `docker compose build`. Shellcheck isn't installed in the dev container; run it with:

```sh
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:v0.10.0 scripts/*.sh
```

## Versioning

Semver, with the version in `VERSION` and notes in `CHANGELOG.md` (Keep a Changelog). Add user-visible changes under `## [Unreleased]` as you make them. Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`, which fails unless the tag equals `VERSION` and `CHANGELOG.md` has a `## [X.Y.Z]` section. Changing IPs, ports, the login account or script options is a breaking change. `.gitattributes` forces LF line endings because the files run inside Linux containers.

Nothing in the repo initialises OpenBao; after a fresh volume it must be done by hand:

```sh
export BAO_ADDR=http://127.0.0.1:8210
bao operator init                     # then unseal with 3 keys and `bao login` with the root token
bao secrets enable ssh                # mount path must be `ssh` (target/config.hcl)
bao write ssh/roles/otp key_type=otp default_user=user cidr_list=172.30.0.0/24
bao write ssh/creds/otp ip=172.30.0.10    # prints the OTP
ssh -p 2230 user@localhost           # paste the OTP at the prompt; a second use must fail
```

## How the pieces fit together

The login path spans several files in `target/`, and they only work as a set:

1. `otp.conf` turns off password and public-key auth in sshd, leaving only keyboard-interactive login through PAM.
2. `pam-sshd` replaces the whole PAM stack for sshd. `pam_exec ... expose_authtok` passes the typed password to `vault-ssh-helper` on stdin. The step is `requisite`, and `common-auth` is intentionally not included, so the OTP is the only way in. `pam_unix ... use_first_pass` is `optional` and is there only to satisfy the PAM stack.
3. `vault-ssh-helper` (config in `config.hcl`) calls `ssh/verify` on OpenBao at `172.30.0.2:8200`. OpenBao marks the OTP used, so it can't be replayed. The helper also checks that the OTP's username and IP match this machine.
4. The `user` account's password is set to `*`: the account is unlocked but has no password that could ever work.

Things that break this chain:
- **Static IPs.** The `172.30.0.0/24` network and fixed addresses in `docker-compose.yml` are relied on by `config.hcl` (`vault_addr`), `bao.hcl` (`api_addr`) and the role's `cidr_list`. Request OTPs for `172.30.0.10`, not `localhost` or `127.0.0.1`, or the helper rejects them.
- **`-dev` flag** in `pam-sshd` lets the helper talk to OpenBao over plain HTTP. `bao.hcl` has `tls_disable = true` on purpose for the lab. Enabling TLS means changing both, plus giving the helper a CA cert (`ca_cert` in `config.hcl`).
- **The helper is built from source** (`github.com/hashicorp/vault-ssh-helper@v0.2.4`) in a Go build stage, because HashiCorp's download site is geo-blocked here. Don't switch to downloading a release binary.
- **The OpenBao server is not in dev mode.** It uses Raft storage on the `bao-data` volume, so it comes up sealed after every restart and needs unsealing before logins work.
