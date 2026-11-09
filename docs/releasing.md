# Releasing vmbench

Cutting a release is a maintainer's decision. Nothing publishes by itself: the release workflow runs only when someone pushes a tag `v*` (or starts it by hand). Pull requests, pushes to `main` and CI never create a release.

## What a release is

Two files on the GitHub release page:

| Asset | Content |
|---|---|
| `vmbench-<tag>.tar.gz` | one folder `vmbench-<tag>/` with the committed files of the tagged commit (`git archive`), without `tests/` and `.github/` (see `.gitattributes`), plus a `VERSION` file that holds the tag |
| `SHA256SUMS` | `sha256sum` of the tarball, one line |

`tests/` stays out because users do not need it and it holds the synthetic fixtures; the tests run in CI on the tag before anything is published. To ship them, remove the `tests/` line from `.gitattributes`.

The tarball is reproducible: files sorted, owner `0/0`, every timestamp is the commit time, gzip stores no name or time. Building the same commit twice gives the same sha256 (`tests/test_release.sh` checks this), so anyone can rebuild a release and compare.

## Cut a release

1. Merge everything for the release into `main` through pull requests. `main` is protected.
2. Update `main` locally and check it: `git checkout main && git pull && bash tests/run.sh`.
3. Optional dry run: `bash scripts/build-release.sh v0.1.0 --out /tmp/rel` builds the tarball locally. Or run the *Release* workflow from the Actions tab with `dry_run` on (the default): it tests and builds, publishes nothing.
4. Tag the tested commit and push the tag:

   ```bash
   git tag -a v0.1.0 -m "vmbench v0.1.0"
   git push origin v0.1.0
   ```

   Tag names must look like `v1.2.3`, or `v1.2.3-rc.1` for a pre-release (published as a pre-release, which `latest` skips).
5. The workflow (`.github/workflows/release.yml`) then:
   - refuses a tag that is not on `main` or not of the form `v<number>.<number>.<number>[-suffix]`;
   - runs the whole test suite (`bash tests/run.sh`);
   - builds the tarball and `SHA256SUMS` with `scripts/build-release.sh`, builds it a second time and checks the bytes are identical;
   - in a second job, the only one with `contents: write`, creates the release with the preinstalled `gh` CLI and both assets, with generated release notes. Actions are pinned by commit SHA and no third-party release action is used.

The `VERSION` file in the repository stays `0.0.0-dev`; you do not bump it. The build writes the tag into the tarball's copy. A git checkout reports `git describe`, a release install reports the tag.

## Verify a release

```bash
v=v0.1.0
base=https://github.com/chaloemph/vmbench/releases/download/$v
curl -fsSLO "$base/vmbench-$v.tar.gz" -O "$base/SHA256SUMS"
sha256sum -c --ignore-missing SHA256SUMS
git clone https://github.com/chaloemph/vmbench.git && cd vmbench
bash scripts/build-release.sh "$v" --ref "$v" --out /tmp/rebuilt
cmp /tmp/rebuilt/vmbench-$v.tar.gz ../vmbench-$v.tar.gz && echo reproducible
```

Then install it in a scratch home folder: `HOME=$(mktemp -d) sh get.sh --version v0.1.0` and `~/.local/bin/vmbench version` inside it.

The first release is the first time the real GitHub path (release assets, the `releases/latest` redirect that `get.sh` reads) is exercised. Everything before it was tested only against a local fake release, so check `curl -fsSL .../get.sh | sh` in a scratch home after tagging.

## Withdraw (yank) a release

Delete the release on GitHub (Releases page, or `gh release delete v0.1.0`). `latest` then points to the previous release, or `get.sh` stops with "could not find a release" when none is left. Delete the tag too if the release should not exist at all: `git push origin :refs/tags/v0.1.0`. Do not move or reuse a published tag: people may have pinned it and checked its sha256. Fix forward with a new tag (`v0.1.1`) and say what was wrong in its notes.

Machines that already installed the bad version keep it until `get.sh --uninstall --version <tag>` or a newer install; `get.sh` keeps versions side by side and switches the `current` link.
