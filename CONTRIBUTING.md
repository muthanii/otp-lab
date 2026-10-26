# Contributing

## Checks

CI runs these on every push and pull request. To run them locally from this folder:

```sh
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:v0.10.0 scripts/*.sh
docker compose config --quiet
docker compose build
```

## Changelog

Add user-visible changes under `## [Unreleased]` in [`CHANGELOG.md`](CHANGELOG.md) in the same pull request.

## Versioning

The project follows [Semantic Versioning](https://semver.org/). The current version is in [`VERSION`](VERSION).

| Bump | When |
|---|---|
| Major (`1.0.0` → `2.0.0`) | Something users rely on changes: IPs, ports, the login account, or a removed or renamed script option |
| Minor (`0.1.0` → `0.2.0`) | New features, script options or docs pages that don't break anything |
| Patch (`0.1.0` → `0.1.1`) | Fixes and doc corrections |

## Releasing

1. Update `VERSION`.
2. In `CHANGELOG.md`, move the `[Unreleased]` notes under a new `## [X.Y.Z] - YYYY-MM-DD` heading and add its link at the bottom.
3. Commit, then tag and push:

   ```sh
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin main vX.Y.Z
   ```

The [release workflow](.github/workflows/release.yml) checks that the tag matches `VERSION` and creates a GitHub release from that version's changelog section.
