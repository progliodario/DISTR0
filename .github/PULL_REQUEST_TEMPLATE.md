## What and why

<!-- One or two sentences: what changes, and which problem it solves. -->

## Checks

- [ ] `just check`, `just lint` and `just test-unit` pass locally
- [ ] `just build` and `just test` pass if the image changed (`Containerfile`, `build.sh`, `system_files/`)
- [ ] every new promise has a check (self-test or boot gate) and a row in `docs/claims.md`
- [ ] docs updated if behaviour changed (`README.md`, `AGENTS.md`, `LEGGIMI.md` for users, `docs/ROADMAP.md` when a step is done)
- [ ] new pins (image digest, action commit) explained in a comment or the commit body

## Notes for the reviewer

<!-- Anything CI cannot prove: on-device behaviour, hardware, why a pin was bumped. -->
