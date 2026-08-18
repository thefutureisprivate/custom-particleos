<h1 align="center">Custom ParticleOS</h1>

<p align="center">
  Minimal, immutable Fedora server images for hardened VPS appliances.
</p>

<p align="center">
  <strong>Fedora 44 · x86-64 · UEFI Secure Boot · TPM 2.0</strong>
</p>

## Table of Contents

- [Purpose](#purpose)
- [Architecture](#architecture)
- [Images](#images)
- [Security and Hardening](#security-and-hardening)
- [Trust and Dependencies](#trust-and-dependencies)
- [Build in OBS](#build-in-obs)
- [Installation](#installation)
- [Webserver Operations](#webserver-operations)
- [Mailserver Operations](#mailserver-operations)
- [SSH and DNS](#ssh-and-dns)
- [Updates and Rollback](#updates-and-rollback)
- [Verification](#verification)
- [Licensing](#licensing)

## Purpose

Custom ParticleOS builds two purpose-specific VPS images from one shared Fedora
44 base. The operating system is immutable and authenticated; only explicitly
selected application state lives on the encrypted writable root.

The repository contains native [mkosi](https://github.com/systemd/mkosi)
definitions for [Open Build Service](https://build.opensuse.org/). It does not
contain a `Containerfile`, OCI image, bootc layer, or container build.

## Architecture

[`mkosi.conf`](./mkosi.conf) is the aggregate dependency graph. It constructs
the unpublished `base` image once, then copies that base into each requested
role. [`mkosi.role.conf`](./mkosi.role.conf) applies the common final-image
policy after the copy, so role packages, identities, SELinux policy,
partitioning, dm-verity, and signed UKIs belong only to complete images.

```text
Fedora 44 base
├── ParticleOS-Webserver
│   └── nginx-core + Certbot
└── ParticleOS-Mailserver
    └── PostgreSQL 18 + signed Stalwart service image
```

The mailserver keeps PostgreSQL host-native, Unix-socket-only, and
peer-authenticated. Stalwart itself runs from a separately signed,
dm-verity-protected systemd `RootImage=` Discoverable Disk Image (DDI) stored
on the persistent encrypted root. The application image has its own atomic
current/previous selection and is not replaced by an OS A/B rollback.

## Images

| Role | Image ID | Public services | Included application stack |
|---|---|---|---|
| Webserver | `ParticleOS-Webserver` | SSH 22; HTTP 80; HTTPS TCP/UDP 443 | nginx-core, HTTP/3, Certbot |
| Mailserver | `ParticleOS-Mailserver` | SSH 22; SMTP 25; HTTPS 443; submissions 465; IMAPS 993 | PostgreSQL 18, Stalwart 0.16.17 |

Both images target x86-64 VPS guests. CPU microcode packages are omitted
because the VPS provider controls the physical host's microcode.

## Security and Hardening

Every image includes:

- an OBS-project-key-only Secure Boot database, signed UKIs, A/B `/usr`,
  signed dm-verity, and a project-signed IPE policy in enforcement mode;
- TPM2 encryption for writable root, home backing storage, and swap, bound to
  Secure Boot PCR 7, plus password-backed LUKS encryption for the homed user;
- SELinux targeted policy in enforcing mode, including secureblue-derived
  restrictions for AF_ALG, IPsec, and unused socket classes;
- irreversible ptrace, unprivileged BPF, io_uring, kernel-module-loading, and
  core-dump restrictions;
- SELinux denial of user namespaces outside the kernel, PID 1, and the
  confined systemd-sysupdate and systemd-homed helpers;
- globally preloaded, signed `hardened_malloc` and the `no_rlimit_as` service
  companion;
- a default-deny nftables policy with strict dual-stack reverse-path checks,
  role-specific ingress, identity-specific egress, and bounded connection
  rates;
- strict DNS over TLS to Cloudflare with local DNSSEC validation and no
  plaintext DNS fallback;
- key-only Ed25519 SSH, with root login, passwords, forwarding, and tunnels
  disabled;
- zero set-user-ID or set-group-ID executables. `mount` and `umount` remain
  mode 0755 and are available through `run0`;
- systemd `run0` and polkit for administration. `sudo` is not installed;
- HTTPS-only Fedora, OBS, systemd, and system-update transports;
- no crash dumps, suspend, hibernation, desktop stack, default password,
  embedded private key, or weak-dependency recommendations.

The webserver adds a restricted nginx service, HTTP/1.1, HTTP/2 and HTTP/3,
modern TLS defaults, security headers, bounded requests and logs, and a
non-root Certbot service that requires the ACME `shortlived` profile.

The mailserver adds a dedicated Stalwart SELinux domain, a restrictive systemd
sandbox, a PostgreSQL-only Stalwart feature set, exact packaged-WebUI health
checks, and PostgreSQL peer authentication without a database secret. POP3,
ManageSieve, plaintext client-mail ports, PostgreSQL TCP, and the recovery UI
are not publicly reachable.

The complete design and exclusions are documented in
[`docs/SECURITY-MODEL.md`](./docs/SECURITY-MODEL.md).

## Trust and Dependencies

The image layout is derived from
[systemd/particleos](https://github.com/systemd/particleos). Applicable server
and nginx policy is adapted from
[GrapheneOS/infrastructure](https://github.com/GrapheneOS/infrastructure),
[GrapheneOS/grapheneos.org](https://github.com/GrapheneOS/grapheneos.org), and
[secureblue](https://github.com/secureblue/secureblue). Custom ParticleOS is
not GrapheneOS and is not an official GrapheneOS, Fedora, or systemd project.
Pinned reference revisions are recorded in [`NOTICE`](./NOTICE).

The independently maintained packages are:

- [custom-hardened_malloc](https://github.com/thefutureisprivate/custom-hardened_malloc)
- [custom-no_rlimit_as](https://github.com/thefutureisprivate/custom-no_rlimit_as)
- [custom-ipe-policy](https://github.com/thefutureisprivate/custom-ipe-policy)
- [custom-stalwart](https://github.com/thefutureisprivate/custom-stalwart)

Release-critical trust roots include Fedora and systemd package signing,
membership of the `home:thefutureisprivate` OBS project, the pinned source
commit, the OBS project certificate, the vendored update keyring, reviewed IPE
source, UEFI firmware, and the VPS provider's hypervisor.

## Build in OBS

OBS is the production build environment. The current project is
[`home:thefutureisprivate`](https://build.opensuse.org/repositories/home:thefutureisprivate).

The project requires these packages:

| OBS package | Purpose | Repository |
|---|---|---|
| `custom-particleos` | Builds both complete OS roles | `fedora_44_images` |
| `stalwart-image` | Immutable recovery seed DDI | `stalwart_seed_images` |
| `stalwart-image-updates` | Reviewed application update DDIs | `stalwart_images` |

1. Apply [`.obs/project-config.example`](./.obs/project-config.example) and
   [`.obs/project-meta.example.xml`](./.obs/project-meta.example.xml) to the
   OBS project.
2. Apply
   [`.obs/stalwart-image-meta.example.xml`](./.obs/stalwart-image-meta.example.xml)
   to `stalwart-image` and
   [`.obs/stalwart-image-updates-meta.example.xml`](./.obs/stalwart-image-updates-meta.example.xml)
   to `stalwart-image-updates`. Both release lanes are disabled at rest.
3. Copy [the seed `_service`
   template](./.obs/stalwart-seed/x86-64/_service.example) into
   `stalwart-image`, replace `REPLACE_WITH_REVIEWED_COMMIT` with a reviewed
   immutable commit. Temporarily enable only `stalwart_seed_images`, publish
   the signed seed once, and disable the package again before changing any
   project or dependency metadata.
4. Verify the seed's project signature, embedded dm-verity signature, release
   metadata, and compressed and raw SHA-256 digests. Record those digests in
   [`mkosi.resources/stalwart-seed/release`](./mkosi.resources/stalwart-seed/release).
5. Copy [the application-image `_service`
   template](./.obs/stalwart-image/x86-64/_service.example) into
   `stalwart-image-updates` and pin it to each separately reviewed application
   release. Temporarily enable only `stalwart_images` for that versioned
   build, then disable the package again. Never rebuild an existing image
   version: dependency or recipe changes require a new `IMAGE_VERSION`.
6. Copy [the OS `_service`
   template](./.obs/fedora/x86-64/_service.example) into
   `custom-particleos`, then replace `REPLACE_WITH_REVIEWED_COMMIT` with the
   reviewed repository commit.
7. Synchronize the reviewed recipes from the three dedicated hardening
   repositories into their matching OBS packages. Keep the IPE link pinned to
   the reviewed official `system:systemd/ipe-policy` revision.
8. Run the service and commit the generated OBS sources:

   ```sh
   osc service run
   osc commit
   osc results
   ```

Keep the Fedora repositories based on `Fedora:44/update`. The
`system:systemd` Fedora 44 repository supplies the current systemd interface
required by the images; Fedora's `kernel-core` supplies the kernel. No COPR or
custom kernel repository is used. The `stalwart_Fedora_44` repository is kept
separate so unrelated systemd repository changes do not rebuild Stalwart.

The OS recipe uses `# needssslcertforbuild`. OBS makes only the public project
certificate available to mkosi, while the project private key remains outside
the source repository. OBS signs the bootloader, UKIs, dm-verity metadata, and
published artifact checksums.

## Installation

The VPS must provide UEFI Secure Boot, a TPM2-compatible vTPM, and a boot disk
of at least 8 GiB. Put Secure Boot into setup mode before the first boot so the
OBS project certificate can become the exclusive database key; then protect
firmware settings with an administrator password.

Attach or write the OBS raw image as temporary boot media, then select the
`Installer` profile in systemd-boot. The upstream `systemd-sysinstall`
interface asks for the target disk, whether to erase it, firmware boot-entry
registration, and final confirmation. It copies only the signed ParticleOS
partitions and UKI, installs systemd-boot, and reboots. Detach the installer
media and boot the default profile from the target disk.

The installer keeps SELinux enforcing. Its temporary root read-only bind
mounts the labelled factory policy from the signed `/usr`; the bind is
`nosuid,nodev,noexec`, explicitly ordered into the initrd, and discarded with
the installation environment. Immediately after switch-root, an installer-only
unit restores the policy labels of the tmpfs mount point and its merged-`/usr`
links before userdb, udev, module loading, or early tmpfiles can use them. The
source-media helper relies on its ordered `systemd-udev-settle` dependency and
does not execute udev again inside its `NoNewPrivileges` sandbox. The installer
does not try to update the
bootloader random seed on temporary media; installed systems retain the normal
seed service, and the installation environment requires a hardware or virtual
random-number generator.

The raw image may still be written directly to the final boot volume when a VPS
provider cannot attach installation media. Expand that volume to at least 8
GiB before its first default-profile boot so `systemd-repart` can create the
persistent partitions. Never select the `Installer` profile when the only
available disk contains data that must be retained.

The installed system deliberately receives no credentials from the installer.
On its first boot, the console asks separately for:

- the root password, twice;
- a new homed administrator name;
- the administrator password, twice; and
- one raw Ed25519 SSH public key.

No account, password, SSH key, or private key is built into the image or its
installer profile. Root remains prohibited over SSH. The homed administrator
is a member of `wheel` and `systemd-journal`; its user data is a LUKS/Btrfs
image on the dedicated TPM2-encrypted home partition. The public key is stored
in the signed homed user record, where systemd-userdb can supply it before the
home is open.

On a cold or inactive home, an interactive SSH login therefore has two distinct
steps: sshd first verifies the Ed25519 key, then
`systemd-home-fallback-shell` asks for the homed password and unlocks the user
image before starting the real shell. `PasswordAuthentication` remains off;
the second prompt cannot replace the key. Non-interactive commands and SFTP
cannot answer that unlock prompt, so activate the home through an interactive
login first.

Use `run0` for privileged operations:

```sh
run0 systemctl --failed
run0 journalctl --boot
```

## Webserver Operations

Static content is stored in `/var/www/html`. Keep it root-owned and replace
files atomically:

```sh
run0 install -o root -g root -m 0644 index.html /var/www/html/index.html
```

Port 80 serves only `/.well-known/acme-challenge/` until an explicit virtual
host is installed. Point the domain's A and AAAA records at the VPS, then issue
the certificate as the non-login Certbot account:

```sh
run0 --user=certbot -- certbot certonly \
    --domain example.invalid \
    --email admin@example.invalid \
    --agree-tos
```

Certbot uses HTTP-01, ECDSA P-384, the nginx webroot, and the ACME
`shortlived` profile. Agreement to the ACME subscriber terms remains an
operator decision.

Prepare the supplied `https.conf`, replace `example.invalid`, and install it:

```sh
run0 install -o root -g root -m 0600 \
    ./https.conf \
    /var/lib/particleos/nginx/conf.d/https.conf
run0 nginx -t -c /usr/lib/particleos/nginx/nginx.conf
run0 systemctl reload nginx.service
run0 --user=certbot -- certbot renew --dry-run
run0 systemctl status certbot-renew.timer
```

The virtual-host template advertises HTTP/3 and enables HSTS without
`includeSubDomains` or preload. Enable those directives only after every
subdomain is permanently HTTPS-only.

## Mailserver Operations

The mail image initializes PostgreSQL 18, creates the unprivileged `stalwart`
database role, and starts an unprovisioned Stalwart registry in recovery mode.
Its random temporary administrator credential is written to the protected
service journal:

```sh
run0 journalctl -u stalwart.service
```

Access `localhost:8080` through the console or an SSH tunnel. Create a
permanent administrator and configure the hostname, TLS certificates, Ed25519
DKIM keys, domains, relay policy, and abuse controls before accepting mail.

Installed operational documentation covers provisioning, the health gate,
WAL-based point-in-time recovery, and independent application-image updates:

```text
/usr/share/doc/particleos/stalwart/README
/usr/share/doc/particleos/stalwart/BACKUP-RECOVERY.md
/usr/share/doc/particleos/stalwart/IMAGE-UPDATES.md
```

## SSH and DNS

SSH listens on TCP 22 for every IPv4 and IPv6 source. Authentication accepts
only the provisioned Ed25519 key. systemd-userdb exposes that key while the
home is locked; homed's fallback shell then asks for the home password before
the session starts. nftables applies per-source limits to new connections.

`systemd-resolved` is the sole host resolver. It authenticates Cloudflare's
IPv4 and IPv6 endpoints as `cloudflare-dns.com` over TCP 853 and validates
DNSSEC locally. DHCP, Router Advertisements, LLMNR, multicast DNS, fallback
resolvers, and plaintext DNS cannot replace or bypass that path.

This policy fails closed when TCP 853, certificate validation, or DNSSEC
validation fails. Inspect it with:

```sh
resolvectl status
resolvectl query cloudflare.com
resolvectl query dnssec-failed.org
```

The final command must fail DNSSEC validation.

## Updates and Rollback

`systemd-sysupdate` stages signed, complete A/B `/usr`, verity, and UKI
artifacts from the role-specific OBS update repository. The update and reboot
timers are unattended; reboot occurs only when an installed version is newer
than the booted version.

```sh
run0 systemctl list-timers 'systemd-sysupdate-*'
run0 systemctl start systemd-sysupdate-update.service
```

New UKIs receive three boot attempts. The common health gate rejects failed
units; the webserver also validates nginx configuration and a real local HTTP
response. The mailserver checks PostgreSQL peer authentication, migration
state, the local resolver contract, local protocols, TLS certificates,
security headers, and the exact packaged WebUI without depending on Internet
availability. An unhealthy counted slot is not blessed, so systemd-boot
returns to the previous complete OS version.

Stalwart has a separate signed-image lifecycle. Only explicitly compatible
patch releases with unchanged database format and no migration are activated
automatically. A failed application health check restores the retained
Stalwart image without changing the OS slot. OS rollback preserves the
currently selected Stalwart image.

Immutable policy under `/usr/lib/particleos` changes only through a new signed
OS image. Mutable role data remains on the TPM2-encrypted persistent root.

## Verification

Run static checks before advancing the OBS source revision:

```sh
./scripts/validate.sh
mkosi --profile=obs-repos summary
```

Static validation checks the dependency graph, Fedora release, repository
selection, package scope, absence of container recipes and credentials, and
the required security invariants. It does not replace an OBS build and boot
test.

A release test must verify the OBS signatures and manifests, boot with Secure
Boot and TPM2, confirm dm-verity, IPE and SELinux enforcement, exercise the
role health gate, test update and rollback, inspect exposed ports, validate
DNS-over-TLS/DNSSEC behavior, and review exposed service sandboxes with
`systemd-analyze security`.

## Licensing

The repository is licensed under the GNU Lesser General Public License 2.1.
See [`LICENSE`](./LICENSE). Upstream derivations and their licenses are listed
in [`NOTICE`](./NOTICE).
