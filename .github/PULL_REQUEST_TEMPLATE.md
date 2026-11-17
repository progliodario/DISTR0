## What and why

<!-- One or two sentences: what changes, and which problem it solves. -->

## Checks

- [ ] `just check` and `just lint` pass locally
- [ ] `just build` passes if the image changed (`Containerfile`, `build.sh`, `system_files/`)
- [ ] docs updated if behaviour changed (`README.md`, `AGENTS.md`, or the doc shipped in the image)
- [ ] new pins (image digest, action commit) explained in a comment or the commit body

## Notes for the reviewer

<!-- Anything CI cannot prove: on-device behaviour, hardware, why a pin was bumped. -->
