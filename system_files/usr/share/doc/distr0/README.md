# DISTR0

This file is shipped by the `system_files/` overlay of the DISTR0 image.

Everything committed under `system_files/` in
https://github.com/progliodario/DISTR0 is copied verbatim to the root of the
image at build time, so a file placed in `system_files/etc/foo.conf` becomes
`/etc/foo.conf`. Files are installed read-only: changing them means changing the
repository and building a new image, not editing the running system.

DISTR0 is built on Bluefin, which is built on Fedora Atomic Desktops by the
Universal Blue project.
