# Contributing

## Checks

CI runs these on every push and pull request. To run them locally from this folder:

```sh
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:v0.10.0 scripts/*.sh
docker compose config --quiet
docker compose build
```

## Commit messages

Commits on `main` follow [Conventional Commits](https://www.conventionalcommits.org/). The type decides the next version, and the message becomes the release note, so write it for someone using the lab.

| Type | Use for | Next version | In the changelog |
|---|---|---|---|
| `feat:` | New features, script options, docs pages | Minor (`0.1.1` → `0.2.0`) | Features |
| `fix:` | Bug fixes | Patch (`0.1.1` → `0.1.2`) | Bug Fixes |
| `docs:` | Doc changes and corrections | Patch | Documentation |
| `feat!:`, `fix!:` or a `BREAKING CHANGE:` footer | Changing something users rely on: IPs, ports, the login account, or a removed or renamed script option | Major (minor while below `1.0.0`) | Marked as breaking |
| `ci:`, `build:`, `chore:`, `refactor:`, `test:`, `style:` | Everything else | None on its own | Hidden |

Example:

```text
feat: add --user option to setup-otp-target.sh
```

## Releasing

[Release Please](https://github.com/googleapis/release-please) handles versions, the changelog and releases. Don't edit `VERSION`, `CHANGELOG.md` or `.github/release-please-manifest.json` by hand.

1. Push or merge Conventional Commits to `main`.
2. The [Release Please workflow](.github/workflows/release-please.yml) opens or updates a release PR that bumps `VERSION` and adds the changelog entry.
3. Merge that PR when you want to release. Release Please then tags `vX.Y.Z` and creates the GitHub release.
