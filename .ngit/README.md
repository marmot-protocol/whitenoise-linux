# .ngit — CI on the primary forge

ngit is this repo's primary forge; GitHub is a secondary mirror. `ngit-ci`
watches the repo over Nostr and runs `act/workflows/` using the
[NIP-C1 CI protocol](https://ngit.dev/protocol/ci/specification).

## Workflows

| File | Runs on | Notes |
| --- | --- | --- |
| `act/workflows/pr-precommit.yml` | ngit-ci and GitHub | Canonical quality gate. Runs `.githooks/pre-commit` against the whole tree using an isolated Git index; normalization fails the gate. The hook maintains the byte-identical `.github/workflows/pr-precommit.yml` mirror. Edit the canonical file only. |
| `act/workflows/release-appimage.yml` | ngit-ci | Native build and tests, AppImage packaging, then a headless launch of the packaged app. Publishes the AppImage to Blossom. |
| `act/workflows/release-cross.yml` | ngit-ci | Linux ARM64 cross-build and packaged-app smoke run. |
| `act/workflows/release-windows.yml` | ngit-ci | Windows AMD64 cross-build and packaged-app smoke run under Wine. Separate workflow and runner selector allow it to overlap the native/ARM64 slot. |
| `.github/workflows/ci.yml` + `_build.yml` | GitHub | Linux release-profile builds. Quality gates come from the mirrored `pr-precommit.yml`. |
| `.github/workflows/release.yml` | GitHub | Tag-triggered (`v*`) GitHub Release of the build tarballs. |

## wn-build-server

Two independent coordinator/adapter pairs share the host's enforced CI resource
budget. Each pair runs one disposable KVM guest at a time. Two pairs allow
concurrent builds without the upstream adapter's overlapping-cache fallback.
GitHub runner services and their routing are independent of these services.

| Slot | Selector | Coordinator |
| --- | --- | --- |
| 1 | `wn-ngit-windows` | `npub1g60evye0t0adawuttrgl7xvymm7latgz86f6406kcfpx52mj8szqmjykaj` |
| 2 | `ubuntu-24.04` | `npub16j3janvkrze82x22cl0f7p2nqeqlsck8dacfry4w58yh29gdlzxs4xdnv9` |

`runner/` contains the SDK recipe, guest boot configuration, service templates,
slot mappings, and service-account policy. The deployed coordinator, adapter,
and guest-agent binaries come from upstream commit
`1dde76e67f7606438f38c0ee676a6b64b7e53560`; this is an unreleased source pin,
not the published 0.1.1 binary release. Binaries live under `/opt/ngit-ci/<commit>/`.

The guest starts from Debian 13's `20261021-2638` generic image. Its SDK image
uses the pinned base image, Odin, Rust, and SDL revisions in `runner/Containerfile`.
The worker tag is `localhost/wn-ngit-worker:<Containerfile-sha256>`; both
`runner/slot*.conf` mappings must match the image baked into the guest template.
A recipe change requires rebuilding that template, not pulling SDK packages in
every job. Install the guest files before sealing the template:

- `act.sh` as `/usr/bin/act`, with the pinned act binary at `/opt/ngit-ci/act`.
- `guest-cache.service` and `guest-ssh-key.service` as the corresponding
  `ngit-ci-mount-act-cache.service` and `ngit-ci-install-ssh-key.service` units.
- `guest-ssh-runtime.conf` as the SSH service drop-in; enable `podman.socket`.
- `guest-modules.conf` under `/etc/modules-load.d/`.
- `guest-grub.cfg` under `/etc/default/grub.d/`; run `update-grub`. Serial-only
  GRUB is required because the adapter deliberately omits a VGA device.
- The statically linked guest agent as `/usr/bin/ngit-ci-vsock-agent`.

Disable cloud-init and remove the bootstrap authorized key before sealing the
standalone `/var/lib/ngit-ci-vm/templates/template-exclusive-cache.qcow2` image.
Job SSH keys arrive through per-boot systemd
credentials. The host owns the read-only template; worker accounts cannot alter
it. Keep coordinator state directories private: they contain signing keys.

The guest runs Podman, including the Docker-compatible API used by act. There is
no Docker engine. Privileged build containers exist only inside the disposable
VM; jobs receive no container-daemon socket. Each VM has six vCPUs and 24 GiB
RAM; job containers are limited to six CPUs and 20 GiB. The shared host slice
caps aggregate CI CPU at 80%, with the existing memory guard stopping CI if less
than 8 GiB remains available.

The native build/test child drops `DAC_OVERRIDE` and `DAC_READ_SEARCH` while
retaining access to root-owned caches. Read-only-directory fixtures must fail
at the filesystem boundary, just as they do for an ordinary user.

## Persistent build state

Each slot has a separate 48 GiB loop-backed cache filesystem, mounted
`nodev,nosuid,noexec` on the host. Remove its empty `lost+found/` after formatting:
the adapter scans top-level directories as repository partitions.
The adapter partitions it by repository and trusted/untrusted authority and
evicts idle entries above 44 GiB. The guest mounts its selected scope with
`cache=loose`: metadata and data stay cached within the exclusive writer lease.
Do not modify an active scope from the host or share it with another guest.
`cache=mmap` failed APT signature/hash checks; `cache=loose` passed the full ARM
sysroot bootstrap without weakening package authentication.

`act.sh` binds the selected partition's `worker/` directly into the job at
`/var/cache/wn-ci`, without copying the cache on every run. After act exits,
including a failed build, `sync -f` flushes writeback before the adapter destroys
the guest and releases its lease.

`scripts/ngit-stage.sh` restores the exact workflow revision
from the coordinator's shallow checkout to the fixed `worktree/` path without
discarding ignored build outputs. Cargo registries, toolchains, MDK targets,
native archives, Odin objects, and AppImage
tools persist there. `scripts/ngit-cross.sh` also preserves the cross SDK as a
content-keyed OCI archive and retains its Rust and vcpkg state. Outputs still
follow the existing build scripts' input keys; a cache hit does not skip tests
or packaged-app smoke runs.

Native test executables are keyed by application, test, compiler, library, and
flag inputs. Unchanged tests execute the cached binary in a fresh process; the
isolated UI cases remain separate processes. Each flag variant replaces its
previous executable when inputs change rather than accumulating generations.

## Requests and results

Both coordinators use `request-required` execution policy and advertise through
`wss://relay.cyberguy.fyi` and `wss://relay.ngit.dev`. A maintainer-signed
`ngit ci request <coordinator>` enables automatic service; `ngit ci stop
<coordinator>` withdraws it. Manual runs use `ngit ci trigger <coordinator>
<commit> --workflow <path> --ref <ref>`. Publish the branch's signed repository
state first; a manual non-proposal commit must be reachable from that state.

Check results with `ngit ci status <commit> --json --require-ci-trust
maintainer-directed`. Success means signed job/workflow results from the
requested coordinator, with the expected workflow revision and trigger
provenance. Blossom publishing is configured on the coordinator with a 1 GiB
artifact cap. Optional observability write tokens are not provisioned by these
files; no maintainer credentials are baked into the SDK or cache.
