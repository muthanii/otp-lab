# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Docker Compose lab that demonstrates OpenBao's SSH **one-time password (OTP)** mode: an SSH server that accepts nothing except single-use passwords issued and verified by OpenBao. There is no application code or test suite — only container and daemon configuration, plus `scripts/setup-otp-target.sh`, which applies the same target setup to a real Debian/Ubuntu server. User-facing docs live in `README.md` (kept short) and `docs/`, with Mermaid diagrams.

Host ports are **8210** (OpenBao) and **2230** (SSH), published inside the dev container.

## Commands

The dev container provides Docker (docker-in-docker) and the `bao` CLI (OpenBao 2.7.1).

```sh
docker compose up -d --build          # start the lab (rebuild after editing target/* or bao/Dockerfile)
docker compose logs -f target         # sshd output (-e sends it to stderr)
docker compose exec target cat /var/log/vault-ssh.log   # helper's verify log, first stop when a login fails
docker compose down -v                # tear down, including the Raft data volume (forces re-init)
```

Nothing in the repo initialises OpenBao; after a fresh volume it must be done by hand:

```sh
export BAO_ADDR=http://127.0.0.1:8210
bao operator init                     # then unseal with 3 keys and `bao login` with the root token
bao secrets enable ssh                # mount path must be `ssh` (target/config.hcl)
bao write ssh/roles/otp key_type=otp default_user=user allowed_users=user cidr_list=172.30.0.0/24
bao write ssh/creds/otp ip=172.30.0.10    # prints the OTP
ssh -p 2230 user@localhost           # paste the OTP at the prompt; a second use must fail
```

The OpenBao image (`bao/Dockerfile`) adds an ssh client, so the same login also works from inside it: `docker compose exec openbao sh`, then `ssh user@172.30.0.10` (`BAO_ADDR` is preset there to port 8200).

CI (`.github/workflows/ci.yml`) checks that `VERSION` matches the Release Please manifest, then runs shellcheck, `docker compose config` and `docker compose build`. Shellcheck isn't installed in the dev container; run it with:

```sh
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:v0.10.0 scripts/*.sh
```

## How the pieces fit together

The login path spans several files in `target/`, and they only work as a set:

1. `otp.conf` turns off password and public-key auth and root login in sshd, leaving only keyboard-interactive login through PAM.
2. `pam-sshd` replaces the whole PAM stack for sshd. Three `pam_succeed_if` guards come first and refuse uid < 1000, accounts outside `otp-users` and members of `sudo:admin:wheel`, before any OTP is checked or used up. Then `pam_exec ... expose_authtok` passes the typed password to `vault-ssh-helper` on stdin. The step is `requisite`, and `common-auth` is intentionally not included, so the OTP is the only way in. `pam_unix ... use_first_pass` is `optional` and is there only to satisfy the PAM stack.
3. `vault-ssh-helper` (config in `config.hcl`) calls `ssh/verify` on OpenBao at `172.30.0.2:8200`. OpenBao deletes the OTP on use, so it can't be replayed. The helper also checks that the OTP's username and IP match this machine.
4. The `user` account is in `otp-users` only (no sudo or admin groups), and its password is set to `*`: the account is unlocked but has no password that could ever work.

**An OTP must never open an account that can create admins.** That's enforced by the role's `allowed_users=user` (without it OpenBao issues OTPs for any username, including root), `PermitRootLogin`, and the PAM group guards. Don't loosen any of them, and keep new OTP accounts out of admin groups.

Things that break this chain:
- **Static IPs.** The `172.30.0.0/24` network and fixed addresses in `docker-compose.yml` are relied on by `config.hcl` (`vault_addr`), `bao.hcl` (`api_addr`) and the role's `cidr_list`. Request OTPs for the target's own IP `172.30.0.10`, not `localhost`, or the helper rejects them. The client's address doesn't matter (logins via port 2230 arrive from the Docker gateway `172.30.0.1`).
- **`-dev` flag** in `pam-sshd` lets the helper talk to OpenBao over plain HTTP. `bao.hcl` has `tls_disable = true` on purpose for the lab. Enabling TLS means changing both, plus giving the helper a CA cert (`ca_cert` in `config.hcl`).
- **The helper is built from source** (`github.com/hashicorp/vault-ssh-helper@v0.2.4`) in a Go build stage, because HashiCorp's download site is geo-blocked here. Don't switch to downloading a release binary.
- **The OpenBao server is not in dev mode.** `command: server` makes it use `bao.hcl` and Raft storage on the `bao-data` volume, so it comes up sealed after every restart and needs unsealing before logins work.

## The real-server script

`scripts/setup-otp-target.sh` reproduces the `target/` setup on a real server, so a change to `pam-sshd`, `otp.conf` or `config.hcl` usually needs the same change in the script and in `docs/real-server.md`. Unlike the lab, it edits the existing `/etc/pam.d/sshd` instead of replacing it, writes `sshd_config.d/00-otp.conf` (so it wins over `50-cloud-init.conf`), adds the same PAM guards (group from `--otp-group`, default `otp-users`, created if missing), uses `PermitRootLogin prohibit-password` so root keeps key login, warns about `otp-users` members with admin groups or personal sudoers rules, keeps public-key login unless `--otp-only`, requires TLS unless `--insecure-http`, and stops before touching PAM if `vault-ssh-helper -verify-only` fails.

Test it in a throwaway container on the lab network, never in the lab's own containers. Step 3 needs OpenBao unsealed; to test PAM and sshd while it's sealed, pass `--helper` a stub that exits 0 for `-verify-only` and execs the real helper otherwise. Check the guards by SSHing as different accounts with `SSH_ASKPASS=<script echoing a bad OTP> SSH_ASKPASS_REQUIRE=force` and counting blocks in `/var/log/vault-ssh.log` (only accounts that pass the guards reach the helper):

```sh
docker compose cp target:/usr/local/bin/vault-ssh-helper /tmp/t/
docker run --rm --network otp-lab_lab --ip 172.30.0.20 -v /tmp/t:/t -v "$PWD/scripts:/s:ro" ubuntu:26.04 bash -c \
  'apt-get update -qq && apt-get install -y -qq openssh-server && mkdir -p /run/sshd &&
   /s/setup-otp-target.sh --bao-addr http://172.30.0.2:8200 --insecure-http --helper /t/vault-ssh-helper'
```

## Versioning and commits

Semver, managed by Release Please (`.github/workflows/release-please.yml`, `.github/release-please-config.json`, `.github/release-please-manifest.json`). It reads Conventional Commits on `main`, keeps a release PR that bumps `VERSION` and `CHANGELOG.md`, and tags and releases when that PR is merged. Never edit `VERSION`, `CHANGELOG.md` or the manifest by hand, and keep the Release Please files in `.github/`, not the repo root. When a release is created, the same workflow uploads `scripts/setup-otp-target.sh` and its `SHA256SUMS` to it, so servers can download the script alone from `releases/latest/download/`; keep that filename stable, since the README links to it.

Every commit message must be a Conventional Commit, written for lab users because it becomes the release note. `feat:`, `fix:` and `docs:` appear in the changelog and trigger a release; `ci:`, `build:`, `chore:`, `refactor:`, `test:` and `style:` are hidden. Changing IPs, ports, the login account or script options is a breaking change (`feat!:`); below 1.0.0 that bumps the minor version. Commit types and the human release steps are in `CONTRIBUTING.md`; keep the README to a one-line pointer.

`.gitattributes` forces LF line endings because the files run inside Linux containers. `.gitignore` excludes `bao operator init` output, tokens and keys; never commit them.
