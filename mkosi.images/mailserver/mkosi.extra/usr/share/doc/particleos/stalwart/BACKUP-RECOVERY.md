<h1 align="center">PostgreSQL Backup and Recovery</h1>

<p align="center">
  Verified base backups and continuous WAL archiving for point-in-time recovery.
</p>

## Table of Contents

- [Recovery Model](#recovery-model)
- [Backup Storage](#backup-storage)
- [Enable PITR](#enable-pitr)
- [Operations and Retention](#operations-and-retention)
- [Point-in-Time Recovery](#point-in-time-recovery)
- [Validation](#validation)

## Recovery Model

All mutable Stalwart application data is stored in the appliance-owned local
PostgreSQL 18 cluster. The supported point-in-time recovery (PITR) set consists
of:

- one verified `pg_basebackup` directory;
- its verified `backup_manifest`; and
- every archived WAL and timeline-history file required from the start of that
  backup through the selected recovery target.

The immutable OS, Stalwart executable, WebUI, and static database policy remain
in signed images and are not application-backup contents. A logical `pg_dump`
can aid inspection but is not a PITR substitute.

## Backup Storage

PITR stays disabled until independent storage is mounted at
`/var/lib/pgsql/backup`. Use a dedicated encrypted filesystem and replicate it
to protected off-site storage. The activation service rejects a directory on
the ParticleOS root/data filesystem because it shares the VPS failure domain.

After mounting the filesystem:

```sh
run0 chown postgres:postgres /var/lib/pgsql/backup
run0 chmod 0700 /var/lib/pgsql/backup
run0 restorecon -RF /var/lib/pgsql/backup
```

The mount must be available before backup services start and must retain the
`postgresql_db_t` SELinux label.

## Enable PITR

Enable WAL archiving and create the first synchronous verified recovery point:

```sh
run0 systemctl start particleos-postgresql-pitr-enable.service
run0 journalctl -u particleos-postgresql-pitr-enable.service
```

Only after that service succeeds, enable weekly verified base backups:

```sh
run0 systemctl enable --now particleos-postgresql-basebackup.timer
```

The activation marker is stored in PostgreSQL's data directory, not on the
backup mount. If the mount disappears, archiving fails and PostgreSQL retains
unarchived WAL locally for retry instead of silently discarding it.

## Operations and Retention

Create an on-demand verified base backup with:

```sh
run0 systemctl start particleos-postgresql-basebackup.service
```

Each base backup is checked against its SHA-256 manifest. Its required WAL is
parsed with PostgreSQL 18's matching `pg_waldump`; this is why
`postgresql-contrib` is installed. No contrib extension is created in either
database.

Monitor:

- free space on the backup mount and live PostgreSQL volume;
- `pg_stat_archiver`;
- timer and service results; and
- new files below `backup/wal` and `backup/base`.

The timer never removes backups or WAL. Keep at least two verified base
backups. Delete a WAL segment only after confirming that no
retained base backup can require it. The archive contains message bodies,
credentials, keys, and personal data; apply encryption, access control, and a
documented lifecycle to every replica.

## Point-in-Time Recovery

The preparation helper refuses a running database, rejects backup paths
outside the mounted archive, verifies the backup manifest, validates the UTC
target, and quarantines the old cluster under a timestamped name. PostgreSQL
creates a new timeline; preserve its history file.

1. Select a verified base backup that precedes the target and confirm that its
   WAL chain is continuous.
2. Stop Stalwart and PostgreSQL:

   ```sh
   run0 systemctl stop stalwart.service
   run0 systemctl stop postgresql.service
   ```

3. Prepare the recovery. Replace the example path and timestamp with the
   selected recovery set and UTC target:

   ```sh
   run0 /usr/lib/particleos/postgresql/prepare-recovery \
       /var/lib/pgsql/backup/base/YYYYMMDDTHHMMSSZ \
       YYYY-MM-DDTHH:MM:SSZ
   ```

   Use `latest` as the second argument only when replaying every available WAL
   record is intended.
4. Start PostgreSQL alone and inspect recovery:

   ```sh
   run0 systemctl start postgresql.service
   run0 journalctl -u postgresql.service
   run0 -u postgres psql --host=/run/postgresql --dbname=postgres \
       --command='SELECT pg_is_in_recovery(), now()'
   ```

5. Validate administrator records, domains, messages, queues, and the selected
   recovery target before reopening application access. If the target is
   wrong, stop PostgreSQL, restore the retained `data.pre-pitr.*` cluster, and
   retry from the untouched base backup on a new timeline.
6. After validation, remove the one-shot recovery configuration, retain the
   quarantined old cluster until the incident is closed, and restart the mail
   service:

   ```sh
   run0 rm /var/lib/pgsql/data/conf.d/particleos-recovery.conf
   run0 systemctl start stalwart.service
   run0 systemctl start particleos-mailserver-health.service
   ```

The immutable setup service reapplies the current PostgreSQL policy and strict
`pg_hba.conf` before every database start. WAL recovery restores database
changes only. Roll back or rebuild the signed OS separately when an incident
also requires an OS change.

## Validation

Regularly restore a complete recovery set on an isolated system, start the
mail services, and perform bounded protocol tests. A backup that has only been
created, but never restored and exercised, is not operationally verified.
