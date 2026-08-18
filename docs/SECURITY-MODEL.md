<h1 align="center">Custom ParticleOS Security Model</h1>

<p align="center">
  Trust boundaries, enforced controls, and deliberate exclusions for the
  webserver and mailserver images.
</p>

## Table of Contents

- [Scope](#scope)
- [Security Objectives](#security-objectives)
- [Trust Chain](#trust-chain)
- [Hardening Coverage](#hardening-coverage)
- [Boot and Kernel Policy](#boot-and-kernel-policy)
- [Network and DNS Policy](#network-and-dns-policy)
- [Administration](#administration)
- [Webserver Role](#webserver-role)
- [Mailserver Role](#mailserver-role)
- [Trust Boundaries and Exclusions](#trust-boundaries-and-exclusions)
- [Release Verification](#release-verification)

## Scope

This document describes the shared Fedora 44 server base and the webserver and
mailserver roles. The images adapt applicable settings from GrapheneOS
infrastructure and secureblue, but they are not GrapheneOS and do not provide
Android's security architecture. Reference revisions and license notices are
recorded in [`../NOTICE`](../NOTICE).

The mailserver runs Stalwart from a separately signed,
dm-verity-protected systemd service image. PostgreSQL 18 remains host-native,
Unix-socket-only, and peer-authenticated. There is no database secret.

## Security Objectives

The design protects:

- authenticity and integrity of the boot chain and immutable OS payload;
- confidentiality of writable state while the VPS is powered off;
- explicit separation of OS A/B rollback from Stalwart image selection;
- integrity of root-owned web content and nginx policy;
- key-only remote administration without password or root SSH;
- containment of exposed and privileged services;
- a small, reviewable package set and mutable configuration surface.

The image alone cannot guarantee availability against volumetric denial of
service, defend against malicious firmware or a live root attacker, or recover
from compromise of OBS administration, Fedora signing infrastructure, or the
VPS provider.

## Trust Chain

1. UEFI firmware verifies the OBS-signed bootloader and Unified Kernel Image
   through Secure Boot.
2. The UKI authenticates the kernel, command line, and initrd. Its command line
   enables lockdown confidentiality mode, IPE enforcement, auditing, SELinux,
   signed dm-verity discovery, and `nosuid,nodev` writable-root mounts.
3. Signed dm-verity metadata authenticates the immutable `/usr` partition.
4. TPM2 policies bound to PCR 7 unlock encrypted root, home backing storage,
   and swap only while the exclusive OBS project certificate defines the
   Secure Boot state. The homed user image has its own password-backed LUKS
   boundary inside that storage.
5. `systemd-sysupdate` installs complete A/B `/usr`, verity, signature, and UKI
   artifacts. Boot counting preserves a previously blessed image. After two
   update UKIs exist, a successful counted boot removes the installer-era
   Type-1 entries whose original `/usr` slot is no longer retained.
6. On the mailserver, PID 1 verifies the selected Stalwart DDI's embedded
   root-hash signature and dm-verity tree before execution. Selection is stored
   on the encrypted persistent root, independently of the OS slot.

Only role builds may populate the ESP. Package-created loose boot artifacts
are removed from the shared base before it is copied into a role.

The UEFI database intentionally contains only the current OBS project
certificate. Broader Microsoft and distribution signing authorities cannot
reproduce the same PCR 7 state and unlock the disk. PCR 7 does not prevent an
older image signed by that same key from booting; reviewed source pinning,
signed publication, boot health, and release operations remain responsible for
rollback control.

The `custom-ipe-policy` package pins a reviewed revision of systemd's official
IPE policy and rebuilds it in the ParticleOS OBS project. The systemd-project
IPE binary package is excluded, so the policy is signed by the same certificate
that the kernel trusts through UEFI.

## Hardening Coverage

| Area | Enforced default |
|---|---|
| Image integrity | Project-key-only Secure Boot, signed UKI, A/B `/usr`, signed dm-verity, signed IPE policy |
| State protection | PCR 7-bound TPM2 encryption for root, home backing storage, and swap; password-backed LUKS homed image; writable root and user home mounted `nosuid,nodev` |
| Mandatory access control | SELinux targeted/enforcing with role-specific policy and `handle-unknown=deny` |
| Kernel | Lockdown, signed modules, Yama scope 3, unprivileged BPF and io_uring denial, restricted perf/kexec/log access, irreversible module lockdown |
| Memory | Allocation/free initialization, allocator randomization, signed `hardened_malloc`, `no_rlimit_as` for managed services |
| Userspaces | SELinux-denied user namespaces except kernel, PID 1, and the confined sysupdate/homed helpers; core dumps disabled in every layer |
| Network | Default-deny nftables, pre-conntrack role filtering, dual-stack FIB reverse-path checks, source and global admission limits |
| DNS | Cloudflare DNS over TLS only, strict local DNSSEC, no DHCP/RA resolver override or plaintext fallback |
| Socket classes | SELinux denial of AF_ALG, IPsec control, packet-radio, and unused legacy families |
| Time | Multiple authenticated NTS sources with source agreement |
| SSH | Ed25519 keys only, ML-KEM hybrid key exchange, no root/password/forwarding/tunnels, source-keyed rate limit |
| Privilege elevation | systemd `run0`, polkit authentication, no `sudo`; only Linux-PAM's constrained `unix_chkpwd` verifier retains set-user-ID |
| Services | Capability bounds, namespace isolation, read-only filesystems, syscall/address-family filters, OOM policy |

“GrapheneOS-derived” means that a server setting was adapted to Fedora 44 and
the installed component set. It does not mean that an upstream deployment was
copied wholesale.

## Boot and Kernel Policy

The authenticated `/usr` slots are mounted read-only and `nodev`; writable root
is mounted `nosuid,nodev`, and homed user images are `nosuid,nodev`. Current
Linux-PAM always delegates protected-shadow verification to `unix_chkpwd`, so
that narrow upstream helper retains mode 4755 in dm-verity-authenticated
`/usr`. The build strips set-user-ID and set-group-ID bits from every other
executable under `/usr`, `/etc`, `/opt`, and `/var`, then fails unless the
helper is the sole exception. `mount` and `umount` remain mode 0755 for use
through an already privileged `run0` context.

The `hardened_malloc` and `no_rlimit_as` shared objects retain secureblue's
non-executable mode 4644. On a shared object this bit is loader metadata used
by glibc in secure-execution mode, not an executable privilege transition.

SELinux is loaded from immutable `/usr` before switch-root. The writable-root
factory skeleton is labelled at build time, including the merged-`/usr`
compatibility links and `/etc/selinux` link. PID 1 relabels `/dev`, `/dev/shm`,
and `/run` after loading policy. Udev sockets are recreated with SELinux active
instead of carrying an unlabelled pre-policy netlink socket across
switch-root.

The installer profile has no persistent root to supply `/etc/selinux`. During
its initrd boot, `systemd-fstab-generator` bind mounts the labelled factory
policy from the signed `/usr` into the temporary root as read-only,
`nosuid,nodev,noexec` content. The `x-initrd.mount` option makes this a required
pre-switch-root mount instead of a main-system mount. The installer therefore
does not need a permissive or SELinux-disabled compatibility path. After
switch-root, an installer-only early unit restores the expected labels on `/`,
`/etc`, and the four merged-`/usr` compatibility links created on the tmpfs
root. It runs before userdb, udev, module loading, sysusers, and early tmpfiles;
the relabel is deliberately non-recursive because PID 1 and tmpfiles own the
remaining runtime labels. The source ESP helper then consumes the completed
`systemd-udev-settle` dependency rather than attempting a second udev client
transition inside its `NoNewPrivileges` sandbox. Fedora's existing
`init_t`-to-`setfiles_t` domain transition retains the narrowly scoped
`nosuid_transition` permission needed by installer and service-image paths
which execute from explicitly nosuid mounts.

The installer profile masks `systemd-boot-random-seed.service` because its
source ESP can be attached read-only and is not persistent system state. The
mask applies only to the installer UKI profile; the installed profile retains
bootloader seed rotation. Installation requires the VPS hardware RNG or vRNG
already required by the runtime design.

Installer and service-image paths remain explicitly `nosuid`, so their
service-domain transitions require `process2:nosuid_transition` permissions.
ParticleOS grants only the named transitions required by shipped daemons,
homed's isolated homework process, console authentication, user sessions, and
SSH re-exec. PostgreSQL and Stalwart also receive their matching
`nnp_transition` permission because both services use `NoNewPrivileges=yes`.

The module-lockdown unit runs after the declared modules and nftables rules are
loaded. It removes the modprobe helper and sets
`kernel.modules_disabled=1`, which cannot be reversed until reboot. Required
storage, crypto, firewall, filesystem, and network drivers must therefore be
present in the UKI/initrd or declared in `modules-load.d`.

Yama scope 3 and SELinux's `deny_ptrace` boolean prohibit process attachment;
scope 3 is irreversible until reboot. Unprivileged BPF and io_uring are
disabled. Fedora 44 does not expose `kernel.unprivileged_userns_clone`, so
user-namespace creation is denied by SELinux to every shipped domain except
`kernel_t`, `init_t`, `systemd_importd_t`, and `systemd_homework_t`, plus a low
per-UID namespace ceiling. The latter two exceptions are confined helpers for
systemd-sysupdate and systemd-homed. No container runtime is installed.

Kexec, userfaultfd, implicit executable memfd behavior, kernel pointers and
logs, unsafe line-discipline autoload, SysRq, and foreign-binary-format
activation are disabled or restricted. Core dumps are blocked by kernel pipe
policy, system and user manager limits, PAM limits, coredump configuration,
and masked coredump units.

Secureblue-derived SELinux CIL policy denies non-kernel use of AF_ALG crypto,
IPsec key/XFRM, packet-radio, and unused legacy socket classes. Adding IPsec,
SCTP, CAN, Bluetooth, or container functionality requires an explicit policy
and threat-model change.

The VPS provider controls the physical CPU and its microcode. Guest microcode
packages are intentionally absent.

## Network and DNS Policy

nftables loads before networking or exposed services. Failure of the firewall
or irreversible module-lockdown unit prevents nginx, Certbot, PostgreSQL,
Stalwart, SSH, or chrony from becoming operational.

Shared ingress permits established/related traffic, required DHCP replies,
bounded ICMP/ICMPv6, and globally reachable TCP 22 with a per-source connection
rate. The webserver adds TCP 80 and TCP/UDP 443. The mailserver adds TCP 25,
443, 465, and 993. Forwarding, POP3, ManageSieve, plaintext client-mail ports,
PostgreSQL TCP, and the recovery UI are denied.

Outbound access is identity and protocol specific:

- systemd-networkd may create only DHCP client flows;
- chrony may use NTP/UDP 123 and NTS-KE/TCP 4460;
- Certbot may use rate-limited TCP 80 and 443;
- Stalwart may use rate-limited SMTP/TCP 25 and HTTPS/TCP 443, plus loopback
  DNS;
- systemd-resolved may reach only Cloudflare's configured IPv4 and IPv6
  endpoints over TCP 853;
- the realized systemd-sysupdate transfer cgroup receives bounded HTTPS;
- nginx, ordinary users, and generic root processes receive no new-connection
  allowance.

The sysupdate transfer uses the retained `systemd-pull` binary and
`libcurl-minimal`. Container, VM, machine manager, import daemon, NSS, D-Bus,
and activation interfaces from `systemd-container` are removed. GnuPG is
reduced to detached-signature verification against an immutable vendor keyring
containing only the ParticleOS OBS project key.

`systemd-resolved` installs the fixed Cloudflare endpoints as the global `~.`
route with `DNSOverTLS=yes` and `DNSSEC=yes`. DHCPv4, DHCPv6, and IPv6 Router
Advertisements cannot override them; LLMNR, mDNS, fallback resolvers, and
plaintext port-53 egress are disabled. A blocked DoT path or failed
certificate/DNSSEC validation fails closed.

Stalwart uses resolved's loopback-only `127.0.0.54:53` TCP proxy. DNS messages
still cross the authenticated Cloudflare DoT path, while Stalwart receives the
records needed for its own DANE validation. The mail boot gate validates the
local resolver contract without querying an Internet name, so a network or
Cloudflare outage cannot consume a healthy OS boot attempt.

## Administration

The installer profile contains no credential and boots directly into upstream
`systemd-sysinstall`. That interface selects and partitions the target, copies
the signed OS, links the UKI, installs systemd-boot, and reboots; it does not
create accounts. Before it starts, ParticleOS verifies the project signature
on the source ESP's systemd-boot binary using the OBS project certificate in
the dm-verity-protected `/usr`, then makes that exact read-only binary the
canonical bootctl source for the installer boot. Firmware enrolled only with
the ParticleOS project key can therefore authenticate both the installed
bootloader and its UKIs. On the installed system, `systemd-firstboot` replaces
the unprovisioned root-password sentinel only after a separate console prompt.

A second console-only service creates one systemd-homed administrator in
`wheel` and `systemd-journal`. It accepts only a syntactically valid raw
Ed25519 key, passes that public key to `homectl create`, explicitly selects a
password-encrypted LUKS/Btrfs user image, enforces password-quality policy, and
records completion atomically. The dedicated `/home` backing partition is
also TPM2 encrypted, capped at 4 GiB so an administrator home cannot consume
application storage, and the user image is mounted `nosuid,nodev`. The Btrfs
mount applies `user_home_dir_t` to its filesystem root with SELinux
`rootcontext`; this labels the mount atomically before PAM enters the home and
also applies to homes created by an earlier OS slot.

The key is stored in the signed homed identity rather than only inside the
locked home. sshd's packaged systemd-userdb `AuthorizedKeysCommand` can
therefore verify it before activation. After successful key authentication,
`systemd-home-fallback-shell` asks for the homed password, activates the LUKS
image, upgrades the initially incomplete session, and chain-loads the real
shell. This second prompt is not SSH password authentication:
`PasswordAuthentication` and keyboard-interactive authentication remain off,
and root SSH remains prohibited. A locked home must first be opened by an
interactive session before SFTP or a remote command can run unattended.

The homed password is accepted by console login and `run0`; the distinct root
password is reserved for console and recovery use. Polkit authorizes `run0`;
`sudo` is absent. Polkit's root, socket-activated PAM helper does not require a
set-ID executable. Console login's `pam_unix` stack uses the sole set-ID
exception, `unix_chkpwd`, to compare credentials without exposing shadow
hashes to the login process.

SSH is socket activated on every IPv4 and IPv6 source. Only the Ed25519 host
key generation instance is enabled. Every session receives Fedora's
`sshd@.service` capability, filesystem, namespace, syscall, and SELinux
restrictions. `NoNewPrivileges=yes` is omitted because OpenSSH re-exec must
transition from `sshd_t` to `sshd_session_t`.

Shared mutable operator data is limited to the signed homed identity and
`/home/<administrator>.home` on encrypted persistent storage. Role-specific
mutable paths are listed below.

## Webserver Role

The default nginx server permits GET and HEAD only for
`/.well-known/acme-challenge/` and returns 404 elsewhere. Unknown TLS and QUIC
names are rejected. The domain-specific template uses a fixed-host HTTPS
redirect, serves static content over HTTP/1.1, HTTP/2, and HTTP/3, and rejects
dotfiles, directory indexing, oversized bodies and headers, excessive ranges,
and high request rates.

The default security headers and CSP fit the static placeholder. Operators
must review CSP, cross-origin isolation, caching, HSTS, redirects, and request
limits when changing the served application.

Certbot runs as a dedicated non-login account, uses webroot HTTP-01, and
requires the `shortlived` ACME profile. It may write only the setgid challenge
leaf; nginx workers can read tokens but cannot write them. Private ACME state
and TLS keys remain under `/etc/letsencrypt`. Renewal cannot access the systemd
manager socket and requests only a fixed nginx syntax-check/reload operation
through a watched runtime file.

Webserver mutable paths are:

- `/var/www/html` for root-owned web content and the restricted challenge
  leaf;
- `/var/lib/particleos/nginx/conf.d` for root-owned virtual hosts;
- `/etc/letsencrypt` for Certbot-owned state and certificates.

Dynamic runtimes, uploads, reverse-proxy applications, and databases are not
installed. Adding one requires its own identity, egress, sandbox, SELinux
policy, health check, and update design.

## Mailserver Role

The Stalwart package enables only the PostgreSQL backend and excludes embedded
stores, alternative SQL, cloud storage, distributed coordination, and
enterprise backends. Its service image contains the executable,
`hardened_malloc`, `no_rlimit_as`, and the pinned WebUI. The host contains the
fixed UID/GID, systemd unit, configuration, SELinux policy, PostgreSQL
integration, image selector, and health gate.

The Stalwart unit uses a private runtime, device and mount isolation, read-only
system paths, `NoNewPrivileges=yes`, `CAP_NET_BIND_SERVICE` as its only
capability, native syscall filtering, restricted address families, and
executable-memory denial. The dedicated `stalwart_t` domain limits it to
labelled configuration, state, logs, runtime and temporary files, the
PostgreSQL Unix socket, the host resolver, and selected SMTP, IMAP, and HTTP
port types.

A fresh registry starts in recovery mode. Its random temporary administrator
is available only in the protected journal, and its HTTP listener is reachable
only through `localhost:8080`. Normal mode starts only after a non-expired,
password-bearing administrator exists. POP3 and ManageSieve are absent from
the registry, firewall, and health contract.

The WebUI is a checksum-pinned file inside the signed DDI. Stalwart accepts
only `file:///usr/share/stalwart/webui.zip` and reads it on every start instead
of using its mutable application cache. The executable and WebUI are therefore
atomic with the selected service image. Migration errors exit unsuccessfully,
so systemd restart and failed-unit handling remain active.

The mail health gate verifies peer-authenticated PostgreSQL, the post-migration
mode marker, the local resolver, and bounded application exchanges. Recovery
mode checks the local WebUI. Normal mode checks SMTP, SMTPS, IMAPS, and HTTPS
on both address families, TLS validity, browser security headers, and the exact
packaged WebUI digest. Exit classes distinguish listener, TLS, certificate,
protocol, datastore, and WebUI failures.

PostgreSQL 18 accepts only these peer-authenticated local identities:

```text
local  all       postgres  peer
local  stalwart  stalwart  peer
local  all       all       reject
```

Physical replication used by `pg_basebackup` is separately limited to the
`postgres` identity. The image validates every installed PostgreSQL binary,
the persistent cluster's `PG_VERSION`, and the live server major. A different
major requires an explicit database migration and rollback design.

The supported point-in-time recovery design uses verified base backups and a
continuous WAL archive on an independently mounted encrypted filesystem. Loss
of the archive mount causes archiving to fail and retains WAL locally. No
automatic retention deletes a WAL segment that a retained base backup may
need.

Only signed release metadata marked as a rollback-compatible patch, with an
unchanged schema and no migration, may activate automatically. Selection uses
atomic `current.raw` and `previous.raw` links on the encrypted persistent root.
Application health failure restores the previous image. OS A/B changes never
replace that selection.

Mailserver mutable paths are restricted to:

- `/etc/stalwart`, `/var/lib/stalwart`, and `/var/log/stalwart`;
- `/var/lib/particleos/stalwart` for root-managed signed DDIs and selection;
- `/var/lib/pgsql` for the local PostgreSQL cluster and explicitly mounted
  backup storage.

## Trust Boundaries and Exclusions

Release trust roots are the OBS project certificate and administrators, the
pinned source revision, Fedora and systemd package repositories and keys, the
reviewed configuration, UEFI firmware, and the VPS provider. Cloudflare and
the Web PKI are DNS confidentiality and availability dependencies; DNSSEC
validation remains local.

The following upstream infrastructure content is deliberately absent:

- Arch Linux package, initramfs, bootloader, and filesystem administration;
- deployment-specific addresses, mail domains, Matrix, monitoring,
  replication, and multi-datacenter routing;
- services, kernel modules, secrets, certificates, accounts, and host keys not
  required by these two appliances;
- website virtual hosts and application policy beyond the generic static
  webserver.

The host policy is not a substitute for provider firewalling, DDoS protection,
monitoring, incident response, or tested off-site backups.

## Release Verification

A role release is complete only after the exact OBS artifact has been:

1. built from an immutable reviewed commit;
2. verified against the OBS project-signed per-artifact SHA-256 files and
   inspected through both the role-delta and shared-base manifests;
3. installed through the installer profile and booted with Secure Boot, TPM2
   root/home/swap encryption, homed LUKS, dm-verity, IPE, and SELinux
   enforcement active;
4. tested for firewall fail-closed behavior, DoT-only DNS, DNSSEC success and
   failure, key-only SSH, and source-keyed admission limits;
5. inspected with `systemd-analyze security` for exposed services;
6. tested for separate root and homed password provisioning, locked-home
   userdb SSH authentication and fallback-shell activation, `run0`, health-gate
   success and failure, OS update and rollback, ptrace and user-namespace
   denial, zero coredump artifacts, and SELinux socket-class denial.

Webserver verification additionally covers nginx syntax and local responses,
HTTP/3, Certbot staging issuance, renewal, and the fixed reload boundary.

Mailserver verification additionally covers Stalwart and WebUI versions,
service-image signatures and dm-verity, signed compatibility metadata,
PostgreSQL 18 peer authentication, absence of secrets and unexpected
listeners, protocol/TLS/datastore/WebUI health classes, independent patch
activation and rollback, PITR restoration, and preservation of Stalwart image
selection across an OS A/B rollback.

Static repository checks cannot prove the behavior of an OBS worker, generated
UKI, firmware, TPM implementation, Fedora kernel, or target VPS.
