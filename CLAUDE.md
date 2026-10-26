# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Docker Compose lab that demonstrates OpenBao's SSH **one-time password (OTP)** mode: an SSH server that accepts nothing except single-use passwords issued and verified by OpenBao. There is no application code or test suite. The lab is OpenBao plus a **fresh** `ubuntu:26.04` `target` container (`sleep infinity`, no sshd, nothing preinstalled); all SSH/OTP configuration comes from `scripts/setup-otp-target.sh`, the same script used on real Debian/Ubuntu servers. There is no second copy of that configuration in the repo. User-facing docs live in `README.md` (kept short) and `docs/`, with Mermaid diagrams.

Host ports are **8210** (OpenBao) and **2230** (SSH), published inside the dev container.

## Commands

The dev container provides Docker (docker-in-docker) and the `bao` CLI (OpenBao 2.7.1).

```sh
docker compose up -d --build          # start the lab (rebuild after editing bao/Dockerfile); target is a fresh Ubuntu
docker compose exec target cat /var/log/vault-ssh.log   # helper's verify log, first stop when a login fails
docker compose down -v                # tear down, including the Raft data volume (forces re-init)
```

Nothing in the repo initialises OpenBao; after a fresh volume it must be done by hand:

```sh
export BAO_ADDR=http://127.0.0.1:8210
bao operator init                     # then unseal with 3 keys and `bao login` with the root token
bao secrets enable ssh                # the script's default --mount is ssh
bao write ssh/roles/otp key_type=otp default_user=user allowed_users=user cidr_list=172.30.0.0/24
docker compose exec target bash -c 'apt-get update -qq && apt-get install -y -qq wget >/dev/null &&
  wget -qO- https://github.com/muthanii/otp-lab/releases/latest/download/setup-otp-target.sh |
  bash -s -- --bao-addr http://172.30.0.2:8200 --insecure-http --users user'   # set up the target
bao write ssh/creds/otp ip=172.30.0.10    # prints the OTP
ssh -p 2230 user@localhost           # paste the OTP at the prompt; a second use must fail
```

The OpenBao image (`bao/Dockerfile`) adds an ssh client, so the same login also works from inside it: `docker compose exec openbao sh`, then `ssh user@172.30.0.10` (`BAO_ADDR` is preset there to port 8200).

CI (`.github/workflows/ci.yml`) checks that `VERSION` matches the Release Please manifest, then runs shellcheck, `docker compose config` and `docker compose build`. Shellcheck isn't installed in the dev container; run it with:

```sh
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:v0.10.0 scripts/*.sh
```

## How the pieces fit together

After `setup-otp-target.sh` runs on the target, the login path is:

1. `/etc/ssh/sshd_config.d/00-otp.conf` turns off password auth and root password logins (`PermitRootLogin prohibit-password`) and enables keyboard-interactive login through PAM. Key login stays on unless `--otp-only`; the lab's accounts have no keys.
2. `/etc/pam.d/sshd` (edited in place, backup `sshd.bak-otp`): `common-auth` is commented out; three `pam_succeed_if` guards refuse uid < 1000, accounts outside `otp-users` and members of `sudo:admin:wheel`, before any OTP is checked or used up; then `pam_exec ... expose_authtok` passes the typed password to `vault-ssh-helper` on stdin. All `requisite`, so the OTP is the only way in.
3. `vault-ssh-helper` (config in `/etc/vault-ssh-helper.d/config.hcl`) calls `ssh/verify` on OpenBao at `172.30.0.2:8200`. OpenBao deletes the OTP on use. The helper also checks that the OTP's username and IP match this machine.
4. `user` is created by `--users user` in `otp-users` only, with password `*`: unlocked, but no password could ever work.

**An OTP must never open an account that can create admins.** That's enforced by the role's `allowed_users=user` (without it OpenBao issues OTPs for any username, including root), `PermitRootLogin`, the PAM group guards and the script refusing admin accounts in `--users`. Don't loosen any of them.

Things that break this chain:
- **Static IPs.** The `172.30.0.0/24` network and fixed addresses in `docker-compose.yml` are relied on by `bao.hcl` (`api_addr`), the `--bao-addr` used on the target and the role's `cidr_list`. Request OTPs for the target's own IP `172.30.0.10`, not `localhost`, or the helper rejects them. The client's address doesn't matter (logins via port 2230 arrive from the Docker gateway `172.30.0.1`).
- **Plain HTTP.** `bao.hcl` has `tls_disable = true` on purpose, so the lab passes `--insecure-http` (helper `-dev`). Enabling TLS means dropping that flag and, for a private CA, passing `--ca-cert`.
- **No init in the target.** The container runs `sleep infinity`, so after `docker compose restart` sshd isn't running: rerun the script (it starts sshd) or start `/usr/sbin/sshd`. `down` then `up` gives a fresh, unconfigured target.
- **The OpenBao server is not in dev mode.** `command: server` makes it use `bao.hcl` and Raft storage on the `bao-data` volume, so it comes up sealed after every restart and the script stops at step 4 until it's unsealed.

## The real-server script

Every change to how a server is configured happens in `scripts/setup-otp-target.sh` (and its docs: `docs/real-server.md`, `docs/how-it-works.md`); the lab target picks it up by rerunning the script. It's meant to be downloaded with `wget` (or run as `wget -qO- ... | sudo bash -s -- --bao-addr ... --users ...`); it accepts either curl or wget for its own downloads: it installs `openssh-server` if missing, downloads `vault-ssh-helper-linux-<amd64|arm64>` from the release and checks it against `SHA256SUMS`, requires `--users` and validates every name before changing anything (refuses root, uid < 1000, admin groups and sudo rules), creates missing accounts with password `*` in `--otp-group`, adds the PAM guards described above before the OTP check, writes `sshd_config.d/00-otp.conf` with `PermitRootLogin prohibit-password`, stops before touching PAM if `vault-ssh-helper -verify-only` fails, and reloads sshd (or starts it when there is no systemd, detected by `/run/systemd/system`) then fails unless sshd accepts connections on its port. `--update` (`self_update`) replaces the script file via a temporary file and `mv`, never in place, because bash is still reading it; a normal run calls `notice_if_outdated`. Both read the latest release from `LATEST_URL`, which `OTP_LAB_DOWNLOAD_URL` also overrides for tests. Output uses `step`/`ok`/`info`/`warn`/`die`, coloured only when stdout and stderr are terminals and `NO_COLOR` is unset. It ends by printing the `bao write ssh/roles/...` command for the `--users` accounts and this server's IP. Keep it working when piped (no reads from stdin) and rerunnable (no duplicate PAM lines). The `usage()` heredoc is the only option reference inside the script (`--help`); update it, and the Arguments section in `docs/real-server.md` including its detailed argument table and pasted `--help` output, whenever an option changes.

Release assets come from `scripts/build-release-assets.sh TAG OUT_DIR` (the helper is built from source there because HashiCorp's download site is geo-blocked here; don't switch to downloading a release binary): it pins `SCRIPT_VERSION=latest` to the tag (so the script downloads the helper from its own release), builds the helper for amd64 and arm64 in `golang:1.27` using the script's `HELPER_VERSION`, and writes `SHA256SUMS`. The Release Please workflow runs it and uploads `dist/*` when a release is created. Asset names are part of the public download URLs; don't rename them.

Test on the lab target or on throwaway containers on the lab network, with OpenBao unsealed (step 4 checks the connection). For a quick check of a local edit: `docker compose cp scripts/setup-otp-target.sh target:/root/` and run it there; it still downloads the helper from the latest release. For release assets, serve a local build: `OTP_LAB_DOWNLOAD_URL` points the script at that mirror:

```sh
scripts/build-release-assets.sh v0.0.0-test /tmp/dist
docker run -d --name otp-dl --network otp-lab_lab --ip 172.30.0.30 -v /tmp/dist:/srv:ro busybox:1.37 httpd -f -p 8080 -h /srv
docker run --rm --network otp-lab_lab --ip 172.30.0.20 ubuntu:26.04 bash -c \
  'apt-get update -qq && apt-get install -y -qq curl && curl -fsSL http://172.30.0.30:8080/setup-otp-target.sh |
   OTP_LAB_DOWNLOAD_URL=http://172.30.0.30:8080 bash -s -- --bao-addr http://172.30.0.2:8200 --insecure-http --users user'
docker rm -f otp-dl
```

The script starts `sshd` itself in such containers; check the PAM guards by SSHing as different accounts with `SSH_ASKPASS=<script echoing a bad OTP> SSH_ASKPASS_REQUIRE=force`, counting blocks in `/var/log/vault-ssh.log` (only accounts that pass the guards reach the helper).

## Versioning and commits

Semver, managed by Release Please (`.github/workflows/release-please.yml`, `.github/release-please-config.json`, `.github/release-please-manifest.json`). It reads Conventional Commits on `main`, keeps a release PR that bumps `VERSION` and `CHANGELOG.md`, and tags and releases when that PR is merged. Never edit `VERSION`, `CHANGELOG.md` or the manifest by hand, and keep the Release Please files in `.github/`, not the repo root. When a release is created, the same workflow builds and uploads the release assets (see above).

Every commit message must be a Conventional Commit, written for lab users because it becomes the release note. `feat:`, `fix:` and `docs:` appear in the changelog and trigger a release; `ci:`, `build:`, `chore:`, `refactor:`, `test:` and `style:` are hidden. Changing IPs, ports, the login account or script options is a breaking change (`feat!:`); below 1.0.0 that bumps the minor version. Commit types and the human release steps are in `CONTRIBUTING.md`; keep the README to a one-line pointer.

`.gitattributes` forces LF line endings because the files run inside Linux containers. `.gitignore` excludes `bao operator init` output, tokens and keys; never commit them.
