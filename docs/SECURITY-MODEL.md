# Security model

This document describes the shared security properties of the ParticleOS
server images and the webserver and mailserver roles. It is a deployment model, not
a claim that these Fedora-derived images are GrapheneOS or provide Android's
security architecture. The mailserver contains the project-provided,
PostgreSQL-only Stalwart RPM plus a local Unix-socket-only PostgreSQL server;
both are enabled with peer authentication and no database secret. The public
DNS-server role is an empty configuration placeholder and is not a current OBS
image-build target.

Reference revisions are pinned in [../NOTICE](../NOTICE).

## Security objectives

The shared base is designed to preserve:

- authenticity and integrity of the boot chain and immutable operating-system
  payload;
- confidentiality of writable system state when the machine is powered off;
- integrity of root-owned web content and nginx policy in the webserver role;
- restricted remote administration with no password or root SSH;
- containment of OpenSSH, chrony, firewall, and web-role nginx/Certbot compromise;
- a small, reviewable mutable configuration surface.

Availability against volumetric denial of service, malicious firmware,
compromised OBS administrators, compromised Fedora signing infrastructure, a
live attacker with root, and vulnerabilities in served applications are outside
what the image alone can guarantee.

## Trust chain

1. The UEFI firmware validates the OBS-signed bootloader and UKI through Secure
   Boot.
2. The signed UKI contains the kernel, command line, and initrd. The command line
   enables lockdown confidentiality mode, IPE enforcement, auditing, SELinux,
   signed dm-verity discovery, and `nosuid,nodev` writable-root mounting.
3. The signed verity metadata authenticates the immutable usr partition.
4. TPM2 PCR 7 policies unlock encrypted root and swap only while UEFI Secure
   Boot uses the enrolled OBS project certificate.
5. systemd-sysupdate writes complete A/B usr, verity, signature, and UKI
   artifacts; boot counting retains a fallback instance.

The shared base removes every package-created loose boot artifact before it is
copied into a role. Only the role build may populate the ESP, and it does so
with OBS-signed UKIs.

The shared base enables the update and conditional-reboot timers. New UKIs
receive three attempts. During a counted boot,
`systemd-boot-check-no-failures.service` blocks `boot-complete.target` if a
unit failed; the webserver also requires a valid nginx configuration and a
local HTTP response. The mailserver requires a peer-authenticated PostgreSQL
query, working strict DNS resolution, Stalwart, and a successful response from
its packaged WebUI. A failed gate triggers a reboot without blessing that slot,
so systemd-boot eventually selects the previous blessed UKI and A/B usr set.
Both forced-reboot actions require the `LoaderBootCountPath` EFI variable; they
cannot turn a normal, already blessed boot into a permanent reboot loop.
This availability rollback does not provide cryptographic anti-rollback.

The OBS project certificate and membership, source revision, Fedora package
repositories and keys, systemd repository, firmware trust store, and reviewed
configuration are all release trust roots. Cloudflare's resolver service and
the Web PKI are DNS confidentiality and availability trust roots; DNSSEC
validation remains local. OBS keeps its project private key outside this
repository.

The UEFI database intentionally contains only the current OBS project
certificate. Microsoft and generic distribution certificates are excluded so
code signed by a broader authority cannot reproduce the PCR 7 trust state and
obtain the disk key. PCR 7 provides update-stable binding to this project's
Secure Boot authority, but it does not by itself prevent rollback to an older
UKI signed by the same project key. OBS source pinning, signed dm-verity, update
policy, and release operations remain responsible for rollback control.

The official systemd IPE policy source is rebuilt in the ParticleOS OBS
project, where OBS signs it with this same certificate. The systemd-project
build is excluded from package resolution. This lets the kernel authenticate
and enforce IPE without enrolling the broader systemd project certificate in
UEFI.

This image targets VPS guests only. It does not install CPU microcode payloads,
because the physical host's microcode is controlled by the VPS provider. The
provider's hypervisor, host kernel, CPU microcode, and virtual firmware are
therefore explicit lower-layer trust dependencies.

## Hardening coverage

| Area | Default | Primary source |
|---|---|---|
| Image layout | Project-key-only Secure Boot, signed UKI, A/B usr, dm-verity, PCR 7-bound TPM2 root and swap, `nosuid,nodev` writable root | systemd/particleos |
| Kernel command line | audit, SELinux enforcing, IPE, lockdown, signed modules, allocation/free initialization, stack/allocator randomization, no initrd shell, vsyscall, or IA-32 emulation | particleOS plus GrapheneOS and secureblue policy |
| Kernel runtime | SELinux plus irreversible Yama ptrace denial, targeted user-namespace denial, irreversible unprivileged BPF and io_uring denial, restricted perf, kexec, kernel logs, core dumps, and module loading | GrapheneOS infrastructure and secureblue |
| Memory allocator | signed secureblue `hardened_malloc` package globally preloaded with `no_rlimit_as` for managed services | secureblue |
| Network | default-deny nftables input/forward/output, role-specific pre-conntrack filtering, source-keyed web admission, dual-stack FIB RPF, strong host model, identity/protocol/rate-limited service egress | GrapheneOS infrastructure |
| DNS | systemd-resolved, authenticated Cloudflare DoT only, local DNSSEC validation, no DHCP/RA DNS or plaintext fallback | systemd and secureblue guidance |
| SELinux sockets | userspace denial for AF_ALG, IPsec control, packet-radio, and unused legacy socket classes | secureblue |
| Time | multiple authenticated NTS sources with source agreement | GrapheneOS infrastructure |
| SSH | Ed25519 keys only, ML-KEM hybrid key exchange, no passwords/root/forwarding, source allowlist and rate limit | GrapheneOS infrastructure |
| nginx (webserver) | sandboxed service, bounded journal logging, HTTP/3, request/admission bounds, modern TLS, strict headers, no tokens or autoindex | GrapheneOS infrastructure and grapheneos.org |
| Certificates (webserver) | non-root Certbot webroot HTTP-01, required short-lived ACME profile, private state, fixed validation/reload boundary | GrapheneOS infrastructure plus Certbot |
| Stalwart (mailserver) | PostgreSQL-only feature set, OBS-packaged WebUI, dedicated SELinux domain and account, restrictive systemd sandbox, bounded ingress and egress | Stalwart upstream plus GrapheneOS infrastructure principles |
| PostgreSQL (mailserver) | Local Unix socket only, checksummed cluster, peer identity, no database secret, least-privileged role, restrictive systemd sandbox | Fedora PostgreSQL plus ParticleOS policy |
| Services | capability bounds, namespaces, read-only filesystem, syscall/address-family restrictions, OOM policy | GrapheneOS infrastructure |
| Privilege elevation | systemd run0, isolated transient service, polkit authentication, no setuid sudo/mount/umount | systemd |

“GrapheneOS-derived” means an applicable server setting was adapted to Fedora
44 and this image's component set. It does not mean every file from the
GrapheneOS infrastructure repository is copied.

## Deliberate exclusions

The following GrapheneOS infrastructure content is not applicable and is not
shipped:

- Arch Linux package, initramfs, bootloader, and filesystem administration;
- host-specific addresses, DNS, mail, Matrix, attestation, monitoring, backup,
  replication, and multi-datacenter routing;
- services and kernel modules absent from this image;
- secrets, certificates, account records, host keys, and deployment inventory;
- website virtual hosts and application policy not needed by a generic static
  webserver.

These exclusions avoid unused attack surface and prevent importing
deployment-specific assumptions. The relevant upstream commit identifiers make
future review and reconciliation explicit.

## Boot and kernel policy

The usr slots are immutable and authenticated. Root and swap are writable only
after TPM2-backed decryption bound to PCR 7 and the exclusive OBS project
Secure Boot authority. The root containing `/etc`, `/home`, and `/var` is
mounted `nosuid,nodev`. Expected-PCR signing is deliberately disabled because
the OBS RSA-4096 signing key cannot be loaded as an external policy key by
common TPM2 implementations. The mkosi-obs PCR split artifact is explicitly
reset as well; otherwise mkosi would still embed that public key and
systemd-repart would automatically add an unusable signed PCR 11 policy to the
direct PCR 7 policy. The non-PCR split metadata required for OBS's two-pass
dm-verity signing is retained. SELinux relabeling occurs at image build time
and the installed policy is targeted/enforcing.
Current systemd NvPCR initialization also requires that signed PCR policy and
its public key. The custom initrd therefore omits the vendor NvPCR definitions,
and product/login measurement units run only when a corresponding initialized
NvPCR authorization record exists. This avoids failed TPM units without
weakening the direct PCR 7 binding used for root and swap.
The encrypted root is populated from a minimal factory skeleton whose root,
`/etc`, `/home`, `/var`, journal directory, merged-/usr compatibility symlinks,
and immutable `/etc/selinux` symlink are labeled against their future paths at
build time. Creating `/bin`, `/sbin`, `/lib`, and `/lib64` in that skeleton is
required: creating them during first boot would leave those root-filesystem
objects unlabeled before enforcing policy is available. `systemd-repart`
preserves the build-time SELinux extended attributes, so PID 1 can load the
immutable policy before switch-root without leaving the fresh writable
filesystem unlabeled. Because the cpio initrd cannot preserve SELinux xattrs,
PID 1 relabels `/dev`, `/dev/shm`, and `/run` immediately after loading the host
policy and before starting main-system units. A second recursive relabel
service is deliberately not used: it is redundant with this systemd transition
and can block udev if it fails. The udev kernel netlink socket is not preserved
across switch-root: unlike a filesystem object, the pre-policy socket itself
cannot be repaired by the PID 1 relabel pass, so the main manager recreates it
with SELinux active before coldplugging devices. A dedicated mkosi initrd
subimage installs only the preservation override in the initrd. The main image
consumes this cpio explicitly, avoiding reliance on target-root files that
mkosi does not consult while constructing its default initrd. The initrd udev
service preserves its file-descriptor store only across restarts, not its
deliberate switch-root stop. This clears the queued-event AF_NETLINK storage
descriptor before SELinux activates; the main manager then coldplugs devices
through newly created, policy-labeled sockets.

The authenticated `/usr` mount is also `nosuid`. SELinux therefore requires a
separate `process2:nosuid_transition` permission before a program on `/usr` may
enter its daemon domain. Fedora grants this to some systemd services but not to
every daemon shipped here. ParticleOS grants only the missing `init_t`
transitions to `udev_t`, `system_dbusd_t`, `ldconfig_t`, `iptables_t`,
`sshd_keygen_t`, `chronyd_t`, `postgresql_t` and `stalwart_t` in the mailserver
role, and the policy-selected login user domain. PostgreSQL and Stalwart also
receive the matching `nnp_transition`, because both dedicated services
intentionally retain `NoNewPrivileges=yes`; no runtime-file access is granted
to `init_t`.
The same narrowly scoped policy preserves Fedora's chained transitions for
device sysctls and LVM probing, Ed25519 host-key generation and relabeling,
homed account creation, console authentication, the per-user manager and
login shell, and OpenSSH's current session re-exec. Each source and target is
named explicitly; no unrelated domain receives `nosuid_transition` and the
related `nnp_transition` permission is limited to the PostgreSQL and Stalwart
daemon transitions described above.
Fedora also labels systemd's udev compatibility launcher symlink `lib_t`
instead of `udev_exec_t`. The host unit therefore executes its correctly
labelled `/usr/bin/udevadm` target directly while retaining the
`systemd-udevd` invocation name.

OBS forces mkosi to produce an aggregate checksum before attaching the final
Secure Boot and verity signatures. A post-output hook removes exactly that
stale aggregate before publication. Every published final artifact is instead
verified against its OBS-generated, project-signed SHA-256 file.

The module-lockdown service starts only after the declared modules and nftables
policy load. It clears the modprobe helper path and sets
`kernel.modules_disabled=1`, which cannot be reversed until reboot. This
reduces post-boot kernel attack surface but means required hardware, storage,
crypto, and network drivers must be available in the UKI/initrd or declared in
`modules-load.d` before release. This includes `vfat`, which is needed to mount
the EFI System Partition after switch-root, and the `nft_connlimit` and
`nft_socket` expressions required by the firewall's connection ceilings and
systemd-sysupdate cgroup matching.

Yama scope 3 and the SELinux `deny_ptrace` boolean prohibit process attachment;
scope 3 cannot be relaxed without rebooting. Unprivileged BPF and io_uring are
disabled. User namespaces have a low per-UID ceiling and secureblue-derived
SELinux policy denies their creation to every domain except `kernel_t`,
`init_t`, `systemd_importd_t`, and `systemd_homework_t`. The latter two are
Fedora's confined helper domains for systemd-sysupdate and systemd-homed.
Login users, `run0` shells, and all other shipped service domains remain
denied. Fedora's current kernel no longer exposes the obsolete
`kernel.unprivileged_userns_clone` sysctl, so the image relies on the tested
SELinux rule while retaining a low global namespace ceiling for those helpers.
No container runtime is installed. Fedora's `chrony-wait.service` is
explicitly disabled. Kexec,
userfaultfd,
executable memfd fallback, kernel pointers/logs, SysRq, unsafe line-discipline
autoload, and core dumps are disabled or restricted. Core dumping is denied by
the kernel pipe target, system and user manager limits, PAM limits, the
systemd-coredump configuration, and masked coredump activation units. The
foreign-binary-format service and procfs activation units are also masked;
this server image has no binfmt use case and therefore never needs to load
`binfmt_misc`. The coredump
socket is pulled in statically by `sockets.target`, so a preset alone cannot
disable it; both the socket and its service are vendor-masked in immutable
`/usr`.

At SELinux priority 300, secureblue-derived CIL policy prevents non-kernel
domains from creating or using AF_ALG kernel crypto sockets, IPsec key and XFRM
sockets, packet-radio families, and legacy families not needed by a VPS web
server. Policy compilation uses `handle-unknown=deny`, so a permission added by
a newer kernel but absent from the installed policy is denied instead of
implicitly allowed. The AF_ALG policy retains secureblue's `bluetooth_t`
exception, but this image does not ship Bluetooth userspace. Adding IPsec,
SCTP, CAN, Bluetooth, or container functionality requires a new policy and
threat-model review.

The writable-root skeleton carries SELinux labels before switch-root. Its
`/etc/selinux` factory symlink is labelled `etc_t` so early systemd generators
can traverse it, while the immutable target policy files keep their
policy-specific labels. An exact symlink-only local file-context entry keeps
systemd-tmpfiles from replacing that label with `selinux_config_t`; it does not
change any label below the immutable policy directory. PID 1 may create the
udev compatibility control symlink and homed may read that link, but neither
receives access to the underlying Varlink endpoint from this policy.

## Network policy

The nftables service loads the complete shared and selected-role policy before
the network is configured. The SSH socket and chrony require the firewall and
module-lockdown services; the webserver adds the same requirements to nginx and
Certbot renewal, and the mailserver adds them to Stalwart, so failure is
closed.
The nftables loader and chronyd enter Fedora's dedicated `iptables_t` and
`chronyd_t` SELinux domains. `NoNewPrivileges=yes` is therefore deliberately
not applied to those units because it prevents these security-domain
transitions before their executables start. Their narrow capability bounds,
filesystem protections, namespace restrictions, and syscall filters remain in
force.

Legacy `memfd_create()` callers receive sealed, non-executable memory by
default through `vm.memfd_noexec=1`. Enforcement level 2 is not used because
it rejects callers that have not yet added `MFD_NOEXEC_SEAL`, including
Fedora's system D-Bus broker, while level 1 still closes the implicit
executable-memfd behavior.

Shared inbound policy permits:

- established and related traffic;
- DHCP client replies and necessary rate-limited ICMP/ICMPv6;
- in the webserver role only, new TCP connections to ports 80 and 443 and QUIC
  on UDP 443 with global and source-keyed admission limits, plus per-source and
  global concurrent TCP connection ceilings below nginx's worker capacity;
- in the mailserver role only, new TCP connections to SMTP 25, HTTPS 443,
  implicit-TLS submission 465, and implicit-TLS IMAP 993 with the same layered
  admission and concurrency bounds; POP3, ManageSieve, bootstrap HTTP 8080,
  PostgreSQL, and legacy plaintext mail ports remain closed;
- new TCP connections to port 22 only from the mutable IPv4 or IPv6
  administrator sets, with a much lower rate limit.

The dormant DNS placeholder adds no public ingress and selects no service
packages. Forwarding is denied. Strict FIB checks implement
reverse-path filtering for both address families and reject weak-host traffic.

Outbound policy first permits established replies and loopback traffic. systemd-network can create
only DHCP client flows, chrony only NTP/UDP 123 and NTS-KE/TCP 4460 flows,
web-role Certbot only rate-limited TCP/80 and TCP/443 flows, and mail-role
Stalwart only rate-limited SMTP/TCP 25 and HTTPS/TCP 443 flows; its DNS client
can reach only the systemd-resolved loopback stub. systemd-resolved
can connect only to Cloudflare's two IPv4 and two IPv6 anycast endpoints on
TCP/853; UDP/TCP port 53 egress is absent. nginx and generic root processes
cannot initiate a connection. systemd's dynamic nftables integration grants
rate-limited HTTPS only to the realized
`systemd-sysupdate-update.service` cgroup; ordinary login users cannot create
outbound connections. After an administrator replaces the nftables ruleset,
the documented `systemctl daemon-reload` step repopulates the active unit's
dynamic cgroup membership.

Sysupdate delegates HTTPS transfer to the retained `systemd-pull` binary. All
other container, VM, machine-manager, import-daemon, NSS, D-Bus, and activation
surface from its `systemd-container` package is removed. GnuPG validates the
detached signature over the OBS-generated `SHA256SUMS` against an immutable
vendor keyring containing only the pinned ParticleOS OBS project key.
`libcurl-minimal` provides the dynamically loaded HTTPS transport without
installing the curl command-line client. GnuPG is reduced to the `gpg`/`gpg2`
verifier and its runtime libraries; agent, keyserver, keybox, TPM, user-unit,
and auxiliary verification surfaces are removed after package installation.

This host policy is not a substitute for an upstream provider firewall, DDoS
protection, TLS termination strategy, or network monitoring.

The resolver ignores DHCPv4, DHCPv6, and IPv6 RA DNS data and installs a global
`~.` route to its fixed authenticated upstreams. `DNSOverTLS=yes` and
`DNSSEC=yes` are strict rather than opportunistic. A blocked DoT path or failed
certificate/DNSSEC validation therefore causes resolution failure; the system
does not downgrade to plaintext or an unvalidated provider resolver. Stalwart
declares `systemd-resolved.service` as a hard unit dependency, has no external
port-53 firewall path, and the counted-boot mail health gate fails if a signed
name cannot be resolved through this path.

## Administration

There are no embedded user credentials. On first boot, systemd-homed prompts on
the VPS console and creates a directory-backed user in `wheel` and
`systemd-journal` inside the TPM2/LUKS-encrypted writable root. Directory
storage is deliberate: ordinary directory creation receives
`user_home_dir_t`, whereas Btrfs subvolume roots are created without an SELinux
label. Polkit authorizes run0; sudo is absent. Polkit's private socket activates
its PAM helper as a root service, so authentication does not require a SUID
executable. If that socket is unavailable, direct helper fallback fails closed
after finalization removes the set-ID bit.

Fedora's `mount` and `umount` binaries remain available at mode 0755, so
administrators and recovery units can use them through an already privileged
`run0` context without exposing their package-default SUID transition.

The finalizer strips set-user-ID and set-group-ID bits from every executable
under the shipped `/usr`, `/etc`, `/opt`, and `/var` trees and fails the
build if any remain. This includes `unix_chkpwd` and
`polkit-agent-helper-1`. The `hardened_malloc` and `no_rlimit_as` shared
objects retain secureblue's non-executable mode 4644: their set-user-ID bit is
loader metadata, not a privilege-transition entry point, and allows glibc to
preload them in secure-execution mode.

SSH is socket activated but unreachable until an administrator populates
`/etc/particleos/ssh-allowlist.nft`. SSH accepts only public-key authentication
and Ed25519 host/user keys. Starting the socket requires Fedora's exact
Ed25519 key-generation instance to succeed; the static multi-algorithm keygen
target is masked so per-connection activation cannot create unused RSA or
ECDSA private keys. The key generator has no capabilities or network access
and can write only `/etc/ssh`; it permits the SELinux transition into
`ssh_keygen_t` and must verify a non-empty private key before the socket can
start. The connection sandbox is attached to Fedora's
`sshd@.service` template, so every socket-activated session receives the
capability, filesystem, namespace, and syscall restrictions; the disabled
monolithic `sshd.service` is not used.
`NoNewPrivileges=yes` is excluded because OpenSSH 10.2 re-execs its session
helper and SELinux must transition it from `sshd_t` to `sshd_session_t`.
Initial public-key installation and firewall changes therefore require console
or trusted out-of-band access.

Shared mutable operator-controlled paths are intentionally limited to:

- `/home/*.homedir` and explicitly adopted systemd-homed directories;
- `/etc/particleos/ssh-allowlist.nft`.

The webserver role additionally permits:

- `/var/www/html` (labelled for read-only nginx content; Certbot can write only
  `.well-known/acme-challenge`);
- `/var/lib/particleos/nginx/conf.d`;
- `/etc/letsencrypt` (dedicated Certbot ownership with Fedora certificate labels).

The mailserver role additionally permits Stalwart's package-managed mutable
configuration in `/etc/stalwart`, state in `/var/lib/stalwart`, and bounded
journal/file logging state in `/var/log/stalwart`. PostgreSQL state is confined
to `/var/lib/pgsql`; the mode-0770 `stalwart`-group socket is the only listener
under `/run/postgresql`, where peer authentication maps the non-login
`stalwart` OS account to the same least-privileged database role. No database
password or Stalwart environment file is shipped. A remote database is outside
this appliance profile and would require a new signed image policy, strict TLS,
credentials, health checks, SELinux rules, and a destination-specific firewall
rule.

Configuration under `/usr/lib/particleos` changes only through a new signed
image. Certbot state and TLS private keys are owned by the non-login `certbot`
account. nginx's root master reads certificates during start/reload; workers do
not receive write access. The challenge leaf is setgid `certbot:nginx` mode
2750 and renewal uses umask 0027, so newly created HTTP-01 tokens are
`certbot:nginx` mode 0640. This read-only group bridge applies only to the
public challenge leaf; private Certbot directories remain inaccessible to
nginx workers. Renewal cannot access the systemd manager socket and can only
request the fixed validator/reloader by creating a watched runtime file.
Certbot can create only IPv4 and IPv6 sockets; AF_UNIX is excluded, making the
systemd and D-Bus manager sockets unreachable without hiding
`/run/systemd/resolve`, which `/etc/resolv.conf` needs for ACME DNS lookups.

## Webserver role scope

The default HTTP virtual host permits GET and HEAD only for the ACME challenge
path and returns 404 for all other requests, avoiding a Host-header-controlled
open redirect. Unknown TLS/QUIC names are rejected. The domain-specific
template uses a fixed-host HTTPS redirect. Provisioned virtual hosts serve
static files over HTTP/1.1, HTTP/2, and HTTP/3. Dotfiles, directory indexing,
oversized request bodies/headers, excessive ranges, and high per-source
request/connection rates are rejected. The default headers use a restrictive
CSP suitable for the shipped static placeholder. Access logs are sent directly
to journald's local syslog socket; nginx does not reopen `/dev/stdout`, which is
not a reopenable file when systemd connects standard output to the journal.

Operators must review CSP, cross-origin isolation, caching, HSTS, HTTP-to-HTTPS
redirects, and request size when adding an application. Certbot is included
only with the webroot HTTP-01 authenticator; DNS plugins and the nginx
configuration-rewriting plugin are absent. Dynamic runtimes, reverse proxies,
uploads, databases, and application frameworks are not present. Adding one
changes the threat model and requires its own service account, egress rule,
systemd sandbox, SELinux policy, and update plan.

The renewal drop-in clears Fedora's inherited `/etc/sysconfig/certbot`
environment file and replaces the vendor command, leaving the immutable
`cli.ini` plus per-certificate renewal state as the only Certbot inputs.

## Mailserver role scope

The Stalwart build excludes embedded, alternative SQL, cloud-storage,
distributed-coordination, and enterprise backends and retains only PostgreSQL.
Its systemd unit applies a private runtime, device and mount isolation,
read-only system paths, no-new-privileges, a `CAP_NET_BIND_SERVICE`-only
capability bound, native system-call filtering, address-family restrictions,
and executable-memory denial. ParticleOS additionally orders it after the
firewall and irreversible module lockdown.

Stalwart's bootstrap/recovery HTTP listener on port 8080 is intentionally
reachable only through localhost. Operators provision it through the console
or an SSH tunnel, use Ed25519 DKIM keys, and configure the production hostname,
TLS, domains, and abuse policy before accepting production mail. The image
bundles PostgreSQL because it is an enforced local dependency, but disables its
network listeners and uses Unix peer authentication with no database secret.

The Stalwart WebUI is a checksum-pinned release asset inside the signed RPM and
dm-verity-protected `/usr` payload. The patched server accepts only its exact
`file:///usr/share/stalwart/webui.zip` URL, so registry updates cannot recreate
the upstream first-boot HTTPS downloader. POP3 and ManageSieve listeners are
absent from the initial registry and their ports are absent from nftables. The
mail boot-health gate also rejects unexpected POP3, plaintext IMAP/submission,
or ManageSieve listeners. Fedora assigns IMAPS TCP 993 to its historical
`pop_port_t`, so the dedicated `stalwart_t` domain necessarily has that SELinux
port-type permission; the registry, health gate, and firewall prevent it from
becoming a POP service. The domain can otherwise read only labelled
configuration/WebUI content, manage labelled state, log, runtime, and
private-temporary trees, connect to PostgreSQL only by its Unix socket, resolve
through the host DNS path, and use only the selected SMTP, IMAP, and HTTP port
types.

## Release verification

A role release is not complete until the exact OBS artifact has been:

1. built from an immutable reviewed commit;
2. checked against every OBS project-signed per-artifact SHA-256 file and
   inspected for successful role-delta and full shared-base manifest
   generation;
3. installed and booted with Secure Boot, TPM2 encryption, dm-verity, IPE, and
   SELinux enforcement active;
4. tested for firewall fail-closed behavior, DoT-only resolver egress, local
   DNSSEC success/failure cases, and empty SSH allowlists;
5. checked with `systemd-analyze security` for the exposed services;
6. tested for nginx configuration, HTTP behavior, update, rollback, first-boot
   provisioning, recovery access, Certbot staging issuance, renewal deploy
   reload, ptrace/user-namespace denial, zero core-dump artifacts, and enforced
   SELinux socket denials.

For a mailserver release, verification additionally checks the exact Stalwart
package version and signature, packaged WebUI digest, active dedicated SELinux
domain, PostgreSQL Unix-only and peer-authenticated state, absence of database
secrets, active mail boot-health gate, systemd sandboxes, closed POP3,
ManageSieve, bootstrap, plaintext, and PostgreSQL ports, and the four permitted
public TCP ports. The exact generic image must bootstrap Stalwart against its
own local database without deployment credentials.

Static repository validation cannot prove the behavior of a Fedora kernel,
firmware, OBS worker, generated UKI, TPM implementation, or target hardware.
