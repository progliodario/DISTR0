# Security

## Reporting a vulnerability

Use GitHub's private reporting: **Security → Report a vulnerability** in this
repository. That opens a draft advisory only the maintainer can see. Please do not
open a public issue for a security problem, and do not test against anyone else's
machine.

Reports that are in scope:

- a way to make the published image differ from what CI built;
- a policy or registry misconfiguration that lets an unsigned (or wrongly signed)
  image be applied to a machine;
- a way for a pull request to reach the signing secret or the push credentials;
- a shipped package, Flatpak or Homebrew formula whose upstream is compromised.

## What the signature protects, and what it does not

CI signs every published image with [cosign](https://docs.sigstore.dev/) using the
private key in the repository secret `SIGNING_SECRET`; [`cosign.pub`](cosign.pub)
is its public half and is shipped inside the image at
`/usr/share/distr0/cosign.pub`.

A machine switched with `bootc switch --enforce-container-sigpolicy` (and every
machine installed from the ISO, which does that itself) verifies that signature
before applying an update, using the scope in `/etc/containers/policy.json` plus
the `registries.d` entry that enables sigstore attachments.
`.github/workflows/verify-image.yml` tests that enforcement weekly against the
real registry.

The signature proves **provenance**: this image was published by this
repository's CI, and a wrong or tampered image will not land. It is not an audit
of the content — that is what the package sources, the pinned base digest and
review of `main` are for.

## Trust boundaries

Anything merged to `main` is built and published automatically. Protect, in this
order:

1. `SIGNING_SECRET` (repository secret) — possession means "can produce images
   your machines accept".
2. Write access to the repository and to the `ghcr.io/progliodario/distr0`
   package.
3. Review on `main` — if branch protection is enabled, requiring a pull request
   and a green `Validate` run is the cheapest gate that exists.

No key material belongs in the repository, in an image, in a workflow file or in
a comment. `cosign.key` is in `.gitignore` for a reason.

## If the signing key leaks

1. Generate a new pair: `cosign generate-key-pair` (an empty passphrase is fine;
   CI consumes the key through `env://`). Do this somewhere offline.
2. Replace the `SIGNING_SECRET` repository secret and commit the new
   `cosign.pub` — it is the single source of truth, copied into the image and
   used by `verify-image.yml`.
3. Push. The next image ships the new key; the policy already points at
   `/usr/share/distr0/cosign.pub`, so no other change is needed.
4. On each machine, switch once:
   `sudo bootc switch --enforce-container-sigpolicy ghcr.io/progliodario/distr0:latest`.

Expected consequences: images published under the old key stop verifying (that is
the point), and any machine that has not switched keeps accepting the old key
until it does. Announce the rotation wherever you announce releases.
