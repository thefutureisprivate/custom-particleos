# Stalwart service-image updates

Stalwart runs from `/var/lib/particleos/stalwart/current.raw`, a root-owned
systemd Discoverable Disk Image on the TPM-bound encrypted persistent root.
PID 1 requires an EROFS root partition, dm-verity data, and an embedded PKCS#7
root-hash signature trusted by the ParticleOS OBS project certificate. The OS
contains the unit, fixed UID/GID 993, SELinux policy, configuration seed, and
database integration, but no Stalwart executable or WebUI.

The first boot copies the already signed, release-pinned seed from immutable
`/usr` into the encrypted image store. OS A/B updates and rollbacks never
replace `current.raw`; they validate and continue using the persistent
selection. `previous.raw` retains the last healthy application version.

`particleos-stalwart-update.timer` acquires whole images from the separate
`stalwart_images` OBS repository with systemd-sysupdate's signed SHA256SUMS
verification into a distinct staging directory. Downloader retention can
therefore never unlink `current.raw`, `previous.raw`, or their protected image
files. Acquisition does not select an image. The image manager then
mounts it through a transient `RootImage=` unit so PID 1 verifies its embedded
signature and dm-verity tree before the release metadata can be read, and only
then copies the candidate into the protected image store for selection. A
dedicated `stalwart_image_manager_t` SELinux domain is the only userspace
domain allowed to write that store. Promotion fails closed unless the new file
inherits the exact `stalwart_image_t` label; the capability-free service never
changes ownership or relabels files at runtime.

Automatic activation is allowed only when every condition below is explicit
in the signed metadata:

- the candidate covers both the current and A/B rollback host ABI numbers;
- the Stalwart major/minor release train is unchanged;
- `UPDATE_KIND=patch` and `AUTOMATIC_UPDATE=yes`;
- `DATABASE_MIGRATION=none`, with unchanged database format and schema;
- `ROLLBACK_COMPATIBLE_FROM` names the exact selected image version.

Minor/major releases, schema changes, and any migration marker are rejected.
They must not be relabelled as compatible: first implement and review a
database-aware migration and rollback procedure using the PITR facilities in
`BACKUP-RECOVERY.md`, then define a new signed metadata contract and host ABI.

Activation changes `previous.raw` and `current.raw` with atomic renames,
restarts Stalwart, and runs the bounded protocol/datastore/WebUI health probe.
Failure restores the prior links and service. A rejected or unhealthy image is
retained as `blocked.raw` until a newer release is acquired, without changing
the selected runtime. An explicit rollback also blocks the image being left so
the daily timer cannot immediately undo the operator's decision; manually
activating that version again clears the block after it passes health checks.

Operators can inspect and control the independent application lifecycle with:

```sh
run0 systemctl status particleos-stalwart-update.service
run0 systemctl start particleos-stalwart-update.service
run0 /usr/lib/particleos/stalwart/image-manager activate VERSION
run0 /usr/lib/particleos/stalwart/image-manager rollback
```
