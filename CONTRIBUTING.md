# Contributing

DISTR0 is a personal image, but changes are welcome. Read
[AGENTS.md](AGENTS.md) first: it documents the invariants the image depends on
and the checks your change has to pass. This page is the short version.

## Setup

On a bootc desktop (Bluefin, DISTR0 itself) everything needed is already there:

```bash
git clone https://github.com/progliodario/DISTR0 && cd DISTR0
just --list
```

You also want `shellcheck`, `hadolint` and `actionlint` for the full `just lint`;
without them it skips those parts and still runs `scripts/validate.py`.

## The loop

1. Make the smallest change that does the job. Most changes are one file under
   `system_files/`, one line in a preinstall list, or one `dnf5 install` in
   `build_files/build.sh`.
2. Run the checks:

   ```bash
   just check
   just lint
   ```

3. If you touched the image itself (`Containerfile`, `build.sh`, `system_files/`),
   build it: `just build`. A change that breaks `bootc container lint` or the
   smoke tests at the end of `build.sh` is not ready.
4. Commit with an imperative subject and a body that explains *why*. One logical
   change per commit.
5. Open a pull request. CI runs `Validate` (about a minute) and builds the image
   without publishing it: a pull request publishes nothing, `latest` never
   moves. Once the change is on `main`, the boot gate boots the published image
   and checks it against [`docs/claims.md`](docs/claims.md).

## Pull request checklist

- [ ] `just check` and `just lint` pass locally
- [ ] the image still builds if any build input changed (`just build`)
- [ ] documentation updated when behaviour changed (`README.md`, `AGENTS.md`, or
      the doc shipped in `system_files/usr/share/doc/distr0/`)
- [ ] any new pin (image digest, action commit) explained in a comment or the
      commit body

## Releasing

There is nothing to release by hand: every push to `main` builds, rechunks, signs
and publishes `latest`, `latest.<YYYYMMDD>` and `<YYYYMMDD>`. Machines pick the
update up with `bootc upgrade`, or automatically through Bluefin's `uupd` timer.

## Security

Never commit a private key. The signing key lives only in the repository secret
`SIGNING_SECRET`; `cosign.pub` is its public half. If you think the key or the
supply chain is compromised, read [SECURITY.md](SECURITY.md).
