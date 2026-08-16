# Custom ParticleOS

This repository builds custom, minimal, immutable Fedora 44 x86-64 ParticleOS
images. The current images target server appliances for VPSs. A single mkosi
dependency graph assembles an unpublished Fedora base directory once and then
copies it into every requested complete role image. Role packages, identity,
policy, finalization, partitioning, dm-verity, and UKI generation are applied
only to those derived images.

The role-oriented layout leaves room for a future desktop variant. It is not a
current build target and will require its own package set, policy, and tests.

| Role | Image ID | Additional packages | Service state |
|---|---|---|---|
| `webserver` | `ParticleOS-Webserver` | `nginx-core`, Certbot | Production role; nginx and renewal enabled |
| `mailserver` | `ParticleOS-Mailserver` | PostgreSQL 18, PostgreSQL-only Stalwart | Production role; local database and Stalwart enabled |
| `dnsserver` | `ParticleOS-Dnsserver` | None | Empty placeholder; not built by OBS |

The PostgreSQL-only Stalwart RPM recipe is maintained in the dedicated
[custom-stalwart](https://github.com/thefutureisprivate/custom-stalwart)
repository. The mail role initializes a checksummed, Unix-socket-only local
PostgreSQL cluster and provisions an unprivileged `stalwart` database role by
peer identity, so no database password exists. Stalwart starts automatically;
its bootstrap/recovery listener on TCP 8080 is never public. The DNS-service
role remains an empty placeholder with no current build target. The aggregate
requests `webserver` and `mailserver` together, so mkosi assembles the shared
`base` dependency once and derives both complete images from it.

There is intentionally no `Containerfile`, OCI image, bootc layer, or
container build. [`mkosi.conf`](./mkosi.conf) is the native dependency-graph
entry point, [`mkosi.role.conf`](./mkosi.role.conf) is the common final-image
policy, and the only OBS dependency recipe is
[`.obs/fedora/x86-64/mkosi.conf`](./.obs/fedora/x86-64/mkosi.conf).

This repository derives its image layout from
[systemd/particleos](https://github.com/systemd/particleos) and adapts the
applicable server and nginx hardening from
[GrapheneOS/infrastructure](https://github.com/GrapheneOS/infrastructure) and
[GrapheneOS/grapheneos.org](https://github.com/GrapheneOS/grapheneos.org), plus
the applicable kernel and allocator hardening from
[secureblue](https://github.com/secureblue/secureblue).
It is not GrapheneOS and is not an official GrapheneOS or systemd project.
Exact reference commits are recorded in [NOTICE](./NOTICE).

## Security baseline

Every current role inherits:

- OBS-signed Unified Kernel Images, an exclusive OBS-project Secure Boot trust
  database, a project-signed IPE policy in enforcement mode, and signed
  dm-verity for the immutable `/usr` slots;
- a TPM2-encrypted writable root mounted `nosuid,nodev` and encrypted swap,
  both bound to Secure Boot PCR 7;
- Fedora SELinux in enforcing targeted mode, with policy loaded from immutable
  usr before switch-root;
- GrapheneOS- and secureblue-derived kernel, allocator, TCP, nftables, chrony,
  OpenSSH, and systemd service hardening;
- authenticated DNS over TLS to Cloudflare with fail-closed local DNSSEC
  validation, no DHCP/RA resolver override, and no plaintext DNS egress;
- complete ptrace attachment denial, SELinux-denied user namespaces outside
  the kernel, PID 1, and the confined sysupdate/homed helper domains,
  secureblue userspace socket-class restrictions, and layered core-dump
  prevention;
- zero set-user-ID or set-group-ID executables: `mount` and `umount` remain
  available to `run0`, while polkit performs PAM authentication in its root,
  socket-activated helper service;
- secureblue's signed `hardened_malloc` package preloaded for system and user
  processes, with its `no_rlimit_as` preload companion for system services;
- irreversible kernel-module loading disablement after the early boot modules
  and firewall are loaded;
- an nftables default-deny policy, pre-conntrack role filtering, strict
  dual-stack reverse-path filtering, an empty SSH source allowlist, and
  identity-, protocol-, and rate-limited service egress;
- key-only Ed25519 SSH with root login, passwords, forwarding, tunnels, and
  unused authentication methods disabled;
- no crash dumps, no suspend/hibernation, no desktop stack, no default password,
  no weak-dependency recommendations, no packaged documentation, and no
  embedded private key;
- HTTPS-only Fedora, openSUSE build-tools, ParticleOS OBS, OBS systemd, and
  system-update transports;
- systemd `run0` plus polkit for administration. `sudo` is not installed.

The webserver role additionally supplies sandboxed nginx-core serving HTTPS
over HTTP/1.1, HTTP/2, and HTTP/3, with bounded journal logging, strict request
limits, modern TLS defaults, security headers, rate limits, and no version
disclosure. Its non-root Certbot integration uses HTTP-01, requires the ACME
`shortlived` profile, and crosses into nginx only through a fixed
file-triggered validation/reload boundary.

The mailserver role supplies the PostgreSQL-only Stalwart package and a
local-only PostgreSQL server behind a role-specific default-deny firewall. It
admits only SMTP 25, HTTPS 443, implicit-TLS submission 465, and implicit-TLS
IMAP 993; POP3, ManageSieve, plaintext client mail ports, PostgreSQL, and
bootstrap HTTP 8080 remain closed. Stalwart egress is limited to SMTP 25 and
HTTPS 443, with resolver traffic confined to the loopback systemd-resolved
TCP proxy stub so Stalwart can validate preserved DNSSEC records for DANE over
the host's authenticated Cloudflare DoT path. A dedicated SELinux domain
independently enforces the selected ports, local database socket, and labelled
file access. Provisioning instructions are installed at
`/usr/share/doc/particleos/stalwart/README`; the adjacent
`BACKUP-RECOVERY.md` defines continuous WAL archiving, verified base backups,
retention constraints, and point-in-time recovery.

See [docs/SECURITY-MODEL.md](./docs/SECURITY-MODEL.md) for trust boundaries,
GrapheneOS hardening coverage, and deliberate exclusions.

## Build in OBS

OBS is the authoritative production build environment. This follows the native
particleOS OBS mechanism documented in the
[OBS image package format guide](https://www.open-build-service.org/help/manuals/obs-user-guide/cha-obs-package-formats)
and its
[SCM build-recipe extraction guide](https://openbuildservice.org/help/manuals/obs-user-guide/cha-obs-concepts).

1. Create the single `custom-particleos` image package in the
   [`home:thefutureisprivate`](https://build.opensuse.org/repositories/home:thefutureisprivate)
   OBS project.

2. Add these lines to the OBS project configuration:

   ```text
   Type: mkosi
   Repotype: checksumsfile:rawsig staticlinks
   ```

3. Copy the generic [`_service`
   template](./.obs/fedora/x86-64/_service.example) into that OBS
   package as `_service`. Replace `REPLACE_WITH_REVIEWED_COMMIT` with the full
   immutable reviewed commit ID. The `obs_scm` service exports the dependency
   closure as OBS's package recipe while mkosi 26 executes the canonical graph
   from the exported SCM tree.

4. Apply [`.obs/project-meta.example.xml`](./.obs/project-meta.example.xml) as
   the project metadata. Both Fedora repositories must inherit from
   `Fedora:44/update`, not the frozen `Fedora:44/standard` release repository.
   Keep the `system:systemd` Fedora 44 repository ahead of Fedora updates for
   the current upstream systemd packages selected by
   [`mkosi.profiles/obs-repos`](./mkosi.profiles/obs-repos). Fedora 44 stable
   still exposes the older `systemd-sysupdate.service/timer` unit interface;
   these images require the current
   `systemd-sysupdate-update.service/timer` interface and carry no
   compatibility path. The image package set requests Fedora's `kernel-core`;
   no COPR or custom kernel repository is configured.

   Stalwart is the exception: build its RPM only in the dedicated
   `stalwart_Fedora_44` repository, which inherits from stable Fedora updates
   without the live `system:systemd` path. Keep that repository first in the
   image repository search order. This preserves normal OBS dependency
   rebuilds while preventing unrelated systemd CI metadata churn from
   continuously rebuilding the mail server or blocking image publication.

5. Link the official `system:systemd/ipe-policy` package into the project and
   enable its Fedora 44 build. OBS then signs that policy with the same project
   certificate used by ParticleOS:

   ```sh
   osc linkpac system:systemd ipe-policy home:thefutureisprivate ipe-policy
   osc meta pkg home:thefutureisprivate ipe-policy \
       -F .obs/ipe-policy-meta.example.xml
   ```

   The image repository deliberately excludes the systemd-project build of
   this package and gives the ParticleOS repository priority. Do not enable IPE
   with a policy signed by a certificate absent from the exclusive UEFI
   database.

6. Run and commit the source service in the generic image package checkout:

   ```sh
   osc service run
   osc commit
   osc results
   ```

The recipe carries `# needssslcertforbuild`, so OBS supplies the public project
certificate. Its presence makes [`mkosi.obs.conf`](./mkosi.obs.conf) load the
upstream `mkosi-obs` build/signing machinery once on the non-installing
aggregate. [`mkosi.role.obs.conf`](./mkosi.role.obs.conf) applies deferred
signing and the matching sysupdate publication source independently to each
complete role. A location-independent adapter invokes the signer from the
active mkosi installation. OBS signs the bootloader, UKIs, and dm-verity
metadata without exposing the project private key to this repository.
That project certificate is the only key enrolled in the image's Secure Boot
database. Root and swap are bound directly to PCR 7; expected-PCR signing is
disabled because OBS's RSA-4096 project key is not accepted as an external
policy key by common TPM2 implementations. The same RSA key remains suitable
for signing and verifying the IPE policy. The configuration also resets
`mkosi-obs`'s implicit PCR split artifact so no unusable `.pcrpkey` is
embedded and auto-combined with the direct PCR 7 policy. The roothash,
OS-release, and repartition definitions remain split for OBS's two-pass
dm-verity signing. OBS forces mkosi to create a first-pass SHA256SUMS aggregate,
which becomes stale when OBS attaches signatures in the second pass. A guarded
post-output hook discards only that aggregate before publication. Release
verification uses the project-signed final per-artifact SHA-256 files from OBS.
The published role manifest intentionally lists the packages added after the
shared base was copied, matching mkosi's base-tree semantics. The separately
published `base.manifest.gz` is the full shared package inventory; review both
manifests for a complete role image. Package-created loose boot artifacts are
removed at the base boundary so only role-generated, OBS-signed UKIs reach the
final ESP.

For automatic source-service triggers, copy
[`.obs/workflows.example.yml`](./.obs/workflows.example.yml) to the SCM
workflow configuration. It triggers only `custom-particleos`, whose service
remains pinned until its reviewed commit is explicitly advanced. DNS remains a
definition in the graph but is not an aggregate dependency while it is empty.

## Validate a change

Run the repository checks before updating the OBS package:

```sh
./scripts/validate.sh
```

Inspect the production graph and local custom repositories before release:

```sh
mkosi --profile=obs-repos summary
```

Static validation also enforces that the base has no final-image hooks, both
production roles depend on `base` and `initrd`, the legacy repository is
filtered to Stalwart and only the mail role selects it, and the dormant DNS
image selects no packages and is not an aggregate dependency.

The checks reject container recipes, Fedora releases other than 44, desktop
packages, `sudo`, known-password credentials, private-key files, and missing
security invariants. A successful static check does not replace an OBS build
and boot test.

For a release, pin the source service to the reviewed commit, build it in OBS,
inspect the manifest, boot the image with Secure Boot and TPM2 in a disposable
machine, and verify the effective unit sandboxes with
`systemd-analyze security`.

Every role release test must also confirm that `resolvectl status` reports DNS
over TLS enabled and DNSSEC supported/enabled, a valid signed name resolves, a
deliberately broken DNSSEC name fails, and the firewall exposes no resolver flow
on port 53.

## Install

The virtual machine must expose UEFI Secure Boot and a TPM2-compatible vTPM.
Guest microcode packages are intentionally omitted: CPU microcode is the VPS
hypervisor/provider's responsibility. Put Secure Boot into setup mode before
the first boot so the OBS project certificate can be enrolled as the exclusive
Secure Boot database key. Protect the firmware settings with an administrator
password afterward.

Import or write the OBS raw disk image directly to the VPS boot volume. The
boot volume must be expanded to at least 8 GiB before the first boot so
systemd-repart has space to create the 2 GiB encrypted swap and writable root
partitions. Booting the unexpanded transport image cannot complete
provisioning. The production UKI intentionally contains no interactive or
destructive installer
profile. On first boot, the console wizard creates a systemd-homed administrator
as an SELinux-labelled directory inside the TPM2/LUKS-encrypted writable root.
The account is added to `wheel` and `systemd-journal`; no fixed account or
password is built into the image.

Use `run0` for privileged operations:

```sh
run0 systemctl --failed
run0 journalctl --boot
```

Published artifacts report either `ParticleOS-Webserver` or
`ParticleOS-Mailserver` plus their complete image version through
`hostnamectl`. `ParticleOS-Dnsserver` remains reserved for the empty image
definition. These values describe the atomic image slot and are separate from
Fedora's package-compatible `ID=fedora` and `VERSION_ID=44`.

### Adopt an existing homed account

Updates and rollbacks retain the encrypted writable root, so locally created
`/home/*.homedir` accounts need no migration step. To recover a homed directory
that was unregistered or restored at another persistent path, preserve its
ownership, ACLs, extended attributes, and embedded `.identity` record, then
adopt it explicitly:

```sh
run0 homectl adopt /persistent/path/admin.homedir
run0 homectl inspect admin
```

`homectl adopt` registers the referenced directory in place; it does not move
or copy it. Keep the path on encrypted persistent storage. A home originating
on another machine remains signed by that machine. Import only that trusted
machine's public homed signing key before adoption—never its private key—and
remove the public key again when homes from that origin should no longer be
accepted:

```sh
run0 homectl add-signing-key --key-name=old-vps.public ./old-vps.public
run0 homectl adopt /persistent/path/admin.homedir
run0 homectl remove-signing-key old-vps.public
```

Use console or out-of-band access and verify the source key fingerprint before
trusting it. Adoption is not a substitute for a backup and does not bypass the
home record's signature or password authentication.

## Operate the web server

Static content lives in Fedora's SELinux-labelled, root-owned mutable directory
`/var/www/html`. Replace the placeholder atomically and do not make
the directory writable by the nginx user:

```sh
run0 install -o root -g root -m 0644 index.html /var/www/html/index.html
```

TCP ports 80 and 443 and UDP port 443 are enabled by the firewall. Port 80
exposes only `/.well-known/acme-challenge/` for ACME HTTP-01 and returns 404 for
every other request until an explicit virtual host is installed. Unknown TLS
and QUIC names are rejected as well. The supplied domain-specific virtual-host
template adds a fixed-host HTTP-to-HTTPS redirect without trusting an arbitrary
Host header.

Point the domain's A and AAAA records at the VPS and confirm port 80 is reachable.
Then create the ACME account and certificate. Supplying `--agree-tos` is an
operator decision and is intentionally not built into the image:

```sh
run0 --user=certbot -- certbot certonly \
    --domain example.invalid \
    --email admin@example.invalid \
    --agree-tos
```

Certbot requires the ACME `shortlived` profile and defaults to the nginx
webroot, an ECDSA P-384 key, and HTTP-01. The renewal service can write only the
pre-created `/var/www/html/.well-known/acme-challenge` leaf, not the rest of the
site. The setgid challenge directory gives new tokens the `nginx` group and
mode 0640, so workers can serve them without gaining write access. Certbot's
private state remains owned by the dedicated `certbot` account under
`/etc/letsencrypt`; nginx's root master can read private keys but its workers
cannot write them.

Prepare a local copy of the supplied HTTPS virtual host, replace every
`example.invalid` with the issued domain, and install that prepared file:

```sh
run0 install -o root -g root -m 0600 \
    ./https.conf \
    /var/lib/particleos/nginx/conf.d/https.conf
run0 nginx -t -c /usr/lib/particleos/nginx/nginx.conf
run0 systemctl reload nginx.service
run0 --user=certbot -- certbot renew --dry-run
run0 systemctl status certbot-renew.timer
```

The enabled renewal timer uses the same webroot. A successful deployment writes
a request into `/run/particleos-certbot`; a systemd path unit then runs the
fixed nginx syntax-check/reload service. Certbot has no access to the systemd
manager socket. The HTTPS example advertises HTTP/3 and enables HSTS without
`includeSubDomains` or preload; opt into those only after every subdomain is
permanently HTTPS-only.

## Enable remote SSH deliberately

The SSH socket is enabled, but nftables admits no SSH source address by default.
Perform initial administration from the console. Edit
`/etc/particleos/ssh-allowlist.nft` and add only individual management
addresses or narrow CIDRs:

```nft
set ssh_ipv4 {
    type ipv4_addr
    flags interval
    elements = { 203.0.113.10 }
}

set ssh_ipv6 {
    type ipv6_addr
    flags interval
    elements = { 2001:db8:1234::10 }
}
```

Then validate and atomically reload the complete policy:

```sh
run0 nft --check --file /usr/lib/particleos/nftables.conf
run0 systemctl reload nftables.service
run0 systemctl daemon-reload
```

Install the administrator's Ed25519 public key before relying on remote access.
Keep console or out-of-band access available: a malformed allowlist correctly
fails the firewall reload rather than opening SSH. The daemon reload repopulates
the dynamic cgroup set if `systemd-sysupdate-update.service` is active while the
firewall ruleset is replaced.

## DNS trust and failure mode

`systemd-resolved` is the sole host resolver. It authenticates Cloudflare's
IPv4 and IPv6 resolver endpoints as `cloudflare-dns.com` over TCP/853 and
performs DNSSEC validation locally. DHCPv4, DHCPv6, and IPv6 Router
Advertisements cannot replace those servers; LLMNR, multicast DNS, fallback
resolvers, and plaintext DNS egress are disabled.

This deliberately makes Cloudflare and the Web PKI additional availability and
privacy trust dependencies. If a VPS provider blocks TCP/853, DNS fails closed
instead of falling back to port 53. Changing providers requires a signed image
change to both the resolved configuration and the destination-address firewall
rules.

Inspect the effective state with:

```sh
resolvectl status
resolvectl query cloudflare.com
resolvectl query dnssec-failed.org
```

The last command must fail DNSSEC validation.

## Updates and customization

The retained particleOS `systemd-sysupdate` transfer definitions update the A/B
`/usr`, verity metadata, and UKI artifacts produced by OBS. Their artifact
patterns derive from `%M`, so the current image can consume only its
matching `ParticleOS-Webserver` or `ParticleOS-Mailserver` update namespace.
The DNS namespace remains reserved and unpublished.

Stalwart itself has an independent application-image lifecycle. The host OS
contains only its fixed UID/GID, systemd unit, configuration, SELinux policy,
PostgreSQL integration, and image selector. The executable, allocator, and
WebUI live in a signed EROFS `RootImage=` DDI with embedded dm-verity metadata.
The selected image and retained previous image live on the encrypted persistent
root, so an OS A/B rollback continues with the same selected Stalwart release.
See `IMAGE-UPDATES.md` in the mailserver image for the signed host/database ABI
contract and explicit patch-only automatic activation rules.

OS updates are fully unattended. `systemd-sysupdate-update.timer` periodically
stages a complete signed version. PID 1 publishes only that service's dynamic
cgroup ID into nftables; its new TCP/443 connections are rate limited, and
generic root processes receive no corresponding egress. The separate
`systemd-sysupdate-reboot.timer` checks during the 04:10–04:40 window and
reboots only when the newest installed version is newer than the booted
version. Inspect or trigger the pipeline through its units:

```sh
run0 systemctl list-timers 'systemd-sysupdate-*'
run0 systemctl start systemd-sysupdate-update.service
```

New UKIs start with three boot attempts. On a counted boot, the generic failed
unit checker must complete before `boot-complete.target`; the webserver role
also validates nginx's configuration and an actual HTTP response on its local
port 80 listener. The mailserver role verifies PostgreSQL peer authentication,
Stalwart's post-migration mode, and the local systemd-resolved interface without
depending on Internet availability. It then performs bounded local protocol
checks: the recovery WebUI while unprovisioned, or SMTP/SMTPS/IMAPS/HTTPS, TLS
certificates, security headers, and the exact packaged WebUI in normal mode. A
failed gate is not blessed and reboots the counted slot. The same gate also
runs after independent Stalwart-image activation; application failure restores
the retained image without changing the OS slot.
After three failed attempts, systemd-boot selects the previous blessed UKI and
A/B `/usr` set. The forced-reboot action is conditional on the
`LoaderBootCountPath` EFI variable, so an already blessed normal boot cannot
fall into a reboot loop from this rollback mechanism.

The image retains `systemd-pull` from `systemd-container` solely as sysupdate's
HTTPS callout and removes the package's container, VM, machine, import-daemon,
D-Bus, NSS, and activation interfaces. GnuPG is retained because systemd-pull
verifies the published `SHA256SUMS.asc`; its vendor keyring is replaced with
the pinned `home:thefutureisprivate` OBS project key. `libcurl-minimal` supplies
systemd-pull's dynamically loaded HTTPS transport; the curl command-line client
is not installed. GnuPG's agent, keyserver, keybox, TPM, user-activation, and
auxiliary verification tools are removed; only the `gpg`/`gpg2` verifier and
its runtime libraries remain.

The update source is fixed to the `home:thefutureisprivate` OBS project's
`*_images` repository. The separate `system:systemd` repository remains only a
build-time source for the required current systemd packages. Fedora packages
use the HTTPS-only Fedora primary mirror rather than mirror-manager responses
that may contain plaintext transports. Treat OBS project membership, the
project certificate, the pinned source-service revision, the vendored
ParticleOS OBS repository key, and Fedora/systemd repositories as
release-critical trust roots.

Configuration under `/usr/lib/particleos` is immutable and changes through a
new signed image. Per-machine SSH policy and homed storage are shared mutable
surfaces. The webserver role additionally permits Certbot state, nginx virtual
hosts, and web content. The mailserver role permits only its labelled Stalwart
configuration/state and PostgreSQL data; the dormant DNS image adds no package
or mutable role policy. Add required virtual hardware drivers to the early
module list before building: module loading is permanently disabled for the
rest of each boot.
