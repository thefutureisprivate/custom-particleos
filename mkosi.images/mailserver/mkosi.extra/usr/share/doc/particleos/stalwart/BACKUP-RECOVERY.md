# ParticleOS mailserver backup and point-in-time recovery

All mutable Stalwart application state is stored in the appliance-owned local
PostgreSQL cluster. ParticleOS therefore uses PostgreSQL base backups plus a
continuous WAL archive as its supported point-in-time recovery (PITR) design.
The immutable OS, Stalwart binary, WebUI and static database policy remain in
the signed image and are not copied into an application backup.

Logical `pg_dump` exports can be useful for inspection, but they are not a PITR
substitute. A recoverable set consists of a `pg_basebackup` directory, its
verified `backup_manifest`, and every archived WAL/history file needed from
the beginning of that backup through the desired recovery time.

## Storage and activation

PITR is deliberately not activated until independent storage is provisioned.
Use an encrypted local volume whose contents are also replicated to protected
off-site storage. A directory on the ParticleOS root/data filesystem is
rejected because it would share the server's failure domain.

1. Provision the filesystem persistently at `/var/lib/pgsql/backup`. Its mount
   must be available before the backup services start.
2. After mounting it, set its owner and SELinux label:

       run0 chown postgres:postgres /var/lib/pgsql/backup
       run0 chmod 0700 /var/lib/pgsql/backup
       run0 restorecon -RF /var/lib/pgsql/backup

3. Enable continuous archiving and synchronously create the first verified
   recovery point:

       run0 systemctl start particleos-postgresql-pitr-enable.service
       run0 journalctl -u particleos-postgresql-pitr-enable.service

4. Only after that service succeeds, enable weekly verified base backups:

       run0 systemctl enable --now particleos-postgresql-basebackup.timer

The activation marker is stored in PostgreSQL's data directory, not on the
backup mount. If the mount later disappears, WAL archiving returns failure and
PostgreSQL retains unarchived WAL locally for retry. Monitor free space,
`pg_stat_archiver`, the timer/service result, and the appearance of new files
under `backup/wal` and `backup/base`.

The timer never removes backups or WAL. Keep at least two verified base
backups, replicate them and the continuous WAL stream off the VPS, and delete
an old WAL segment only when no retained base backup can require it. Treat the
archive like the live mail database: it contains message bodies, credentials,
keys and personal data, so enforce encryption, access control and lifecycle
policy on every replica.

Create an on-demand verified base backup with:

    run0 systemctl start particleos-postgresql-basebackup.service

Each base backup is checked against its SHA-256 manifest and its required WAL
is parsed with the matching PostgreSQL `pg_waldump`. The latter is why the
otherwise optional `postgresql-contrib` RPM is part of the mail image. No
contrib extension is created in either database.

Regularly copy a complete recovery set to an isolated test system and perform
the restore below. A backup that has only been created, but never restored and
protocol-tested, is not considered verified operationally.

## Point-in-time recovery

The supplied preparation helper refuses a running database, refuses backup
paths outside the mounted archive, verifies the backup manifest, validates the
UTC target format and retains the old cluster under a timestamped quarantine
name. Recovery creates a new PostgreSQL timeline; keep its history file.

1. Record the UTC recovery target and chosen verified base backup. The base
   must precede the target and its required WAL chain must be continuous.
2. Stop application access and the database:

       run0 systemctl stop stalwart.service
       run0 systemctl stop postgresql.service

3. Prepare either a point-in-time target or the end of the available archive:

       run0 /usr/lib/particleos/postgresql/prepare-recovery \
           /var/lib/pgsql/backup/base/20260815T120000Z \
           2026-08-15T12:34:56Z

   Use `latest` as the second argument only when replaying every available WAL
   record is intended.
4. Start PostgreSQL alone and inspect its recovery journal:

       run0 systemctl start postgresql.service
       run0 journalctl -u postgresql.service
       run0 -u postgres psql --host=/run/postgresql --dbname=postgres \
           --command='SELECT pg_is_in_recovery(), now()'

5. Validate the selected Stalwart data, administrator records, domains and mail
   state before reopening application access. If the target is wrong, stop
   PostgreSQL, restore the retained `data.pre-pitr.*` directory and retry from
   the untouched base backup on a new timeline.
6. After validation, remove the one-shot recovery configuration, preserve the
   quarantined old cluster until the incident is closed, then start Stalwart:

       run0 rm /var/lib/pgsql/data/conf.d/particleos-recovery.conf
       run0 systemctl start stalwart.service
       run0 systemctl start particleos-mailserver-health.service

The immutable setup service reapplies ParticleOS' current PostgreSQL policy and
strict `pg_hba.conf` before every database start. WAL recovery restores database
changes; it intentionally does not restore OS configuration files. Rebuild or
roll back the signed OS separately if the incident also requires an OS version
change.
