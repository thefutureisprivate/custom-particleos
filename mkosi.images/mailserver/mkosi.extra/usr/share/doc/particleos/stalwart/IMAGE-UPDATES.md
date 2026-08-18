<h1 align="center">Stalwart Image Updates</h1>

<p align="center">
  Signed acquisition, compatibility checks, atomic selection, and rollback.
</p>

## Table of Contents

- [Image Store](#image-store)
- [Acquisition and Verification](#acquisition-and-verification)
- [Compatibility Contract](#compatibility-contract)
- [Activation and Rollback](#activation-and-rollback)
- [Operator Commands](#operator-commands)

## Image Store

Stalwart runs from `/var/lib/particleos/stalwart/current.raw`, a root-owned
systemd Discoverable Disk Image on the TPM-bound encrypted persistent root.
PID 1 requires EROFS, dm-verity data, and an embedded PKCS#7 root-hash
signature trusted by the ParticleOS OBS project certificate.

The host contains the unit, fixed UID/GID 993, SELinux policy, configuration,
health gate, image manager, and PostgreSQL integration. It does not contain the
Stalwart executable or WebUI.

On first boot the OS copies the signed, release-pinned seed from immutable
`/usr` into the encrypted image store. OS A/B updates and rollbacks never
replace `current.raw`; they continue using the persistent selection.
`previous.raw` retains the last healthy application image, and `blocked.raw`
records a rejected selection.

## Acquisition and Verification

`particleos-stalwart-update.timer` acquires complete images from the separate
`stalwart_images` OBS repository. systemd-sysupdate verifies the signed
`SHA256SUMS` and writes into an isolated staging directory. Downloader
retention cannot unlink the protected current, previous, blocked, or managed
image files.

The latest verified acquisition remains as sysupdate's installed version
marker. Acquisition does not select or execute it. The image manager mounts a
candidate through a transient `RootImage=` unit so PID 1 verifies the embedded
signature and dm-verity tree before release metadata is read.

After verification, the manager promotes the candidate into the protected
store using a reflink when supported. A dedicated
`stalwart_image_manager_t` SELinux domain is the only userspace domain allowed
to write the store. Promotion succeeds only when the managed file has the
exact `stalwart_image_t` label; the manager has no capability to change
ownership or labels at runtime. Only the separately labelled managed copy is
selectable or executable.

The image manager has no network access. systemd-sysupdate's labelled
`systemd-pull` child alone transitions into Fedora's confined `systemd_importd_t` domain,
and the unit-cgroup nftables allow-list gives that descendant bounded HTTPS.
The manager may start and observe only the separately labelled Stalwart and
mail-health units.

## Compatibility Contract

Automatic activation requires every condition below in signed metadata:

- the candidate covers both the current host ABI and the ABI of the retained
  OS rollback slot;
- the Stalwart major/minor release train is unchanged;
- `UPDATE_KIND=patch` and `AUTOMATIC_UPDATE=yes`;
- `DATABASE_MIGRATION=none`, with unchanged database format and schema; and
- `ROLLBACK_COMPATIBLE_FROM` names the exact selected image version.

The RPM embeds its Stalwart version and package release. The service-image
build compares that record with the signed metadata and fails if an OBS
dependency rebuild combines mismatched runtime and release declarations.

Minor and major releases, schema changes, and every migration marker are
rejected. Such a change requires a database-aware migration and rollback
procedure based on [`BACKUP-RECOVERY.md`](./BACKUP-RECOVERY.md), followed by a
reviewed signed metadata and host-ABI change.

## Activation and Rollback

Activation updates `previous.raw` and `current.raw` through atomic renames,
restarts Stalwart, and executes the bounded protocol, TLS, datastore, and WebUI
health gate. Failure restores the prior selection and service without changing
the OS slot.

An unhealthy or incompatible image remains as `blocked.raw` until a newer
version is acquired. Explicit rollback also blocks the image being left, so
the daily timer cannot immediately reverse the operator's decision. Explicitly
activating that version again clears the block only after its health check
succeeds.

## Operator Commands

Inspect acquisition and select the current published patch image
`0.16.17.26` with:

```sh
run0 systemctl status particleos-stalwart-update.service
run0 systemctl start particleos-stalwart-update.service
run0 systemctl start particleos-stalwart-image-activate@0.16.17.26.service
run0 systemctl start particleos-stalwart-image-rollback.service
```

The control units execute the internal manager through PID 1 so SELinux can
transition it into `stalwart_image_manager_t`. Direct execution from an
administrator shell is unsupported and receives no manager-domain transition.
