# Security model

This document describes the default security properties of ParticleOS
Webserver. It is a deployment model, not a claim that this Fedora-derived image
is GrapheneOS or provides Android's security architecture.

Reference revisions are pinned in [../NOTICE](../NOTICE).

## Security objectives

The image is designed to preserve:

- authenticity and integrity of the boot chain and immutable operating-system
  payload;
- confidentiality of writable system state when the machine is powered off;
- integrity of root-owned web content and nginx policy;
- restricted remote administration with no password or root SSH;
- containment of nginx, Certbot, OpenSSH, chrony, and firewall compromise;
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
   and signed dm-verity discovery.
3. The signed verity metadata authenticates the immutable usr partition.
4. TPM2 PCR 7 policies unlock encrypted root and swap only while UEFI Secure
   Boot uses the enrolled OBS project certificate.
5. systemd-sysupdate writes complete A/B usr, verity, signature, and UKI
   artifacts; boot counting retains a fallback instance.

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
| Image layout | Project-key-only Secure Boot, signed UKI, A/B usr, dm-verity, PCR 7-bound TPM2 root and swap | systemd/particleos |
| Kernel command line | audit, SELinux enforcing, IPE, lockdown, signed modules, allocation/free initialization, stack/allocator randomization, no initrd shell, vsyscall, or IA-32 emulation | particleOS plus GrapheneOS and secureblue policy |
| Kernel runtime | SELinux plus irreversible Yama ptrace denial, disabled user namespaces, irreversible unprivileged BPF and io_uring denial, restricted perf, kexec, kernel logs, core dumps, and module loading | GrapheneOS infrastructure and secureblue |
| Memory allocator | signed secureblue `hardened_malloc` package globally preloaded with `no_rlimit_as` for managed services | secureblue |
| Network | default-deny nftables input/forward/output, pre-conntrack service filtering, source-keyed admission, dual-stack FIB RPF, strong host model, stateful service egress | GrapheneOS infrastructure |
| DNS | systemd-resolved, authenticated Cloudflare DoT only, local DNSSEC validation, no DHCP/RA DNS or plaintext fallback | systemd and secureblue guidance |
| SELinux sockets | userspace denial for AF_ALG, IPsec control, packet-radio, and unused legacy socket classes | secureblue |
| Time | multiple authenticated NTS sources with source agreement | GrapheneOS infrastructure |
| SSH | Ed25519 keys only, ML-KEM hybrid key exchange, no passwords/root/forwarding, source allowlist and rate limit | GrapheneOS infrastructure |
| nginx | sandboxed service, bounded journal logging, HTTP/3, request/admission bounds, modern TLS, strict headers, no tokens or autoindex | GrapheneOS infrastructure and grapheneos.org |
| Certificates | non-root Certbot webroot HTTP-01, required short-lived ACME profile, private state, fixed validation/reload boundary | GrapheneOS infrastructure plus Certbot |
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
Secure Boot authority. Expected-PCR signing is deliberately disabled because
the OBS RSA-4096 signing key cannot be loaded as an external policy key by
common TPM2 implementations. The mkosi-obs PCR split artifact is explicitly
reset as well; otherwise mkosi would still embed that public key and
systemd-repart would automatically add an unusable signed PCR 11 policy to the
direct PCR 7 policy. The non-PCR split metadata required for OBS's two-pass
dm-verity signing is retained. SELinux relabeling occurs at image build time
and the installed policy is targeted/enforcing.
The encrypted root is populated from a minimal factory skeleton whose root,
`/etc`, `/home`, `/var`, journal directory, and immutable `/etc/selinux`
symlink are labeled against their future paths at build time. `systemd-repart`
preserves those SELinux extended attributes, so PID 1 can load the immutable
policy before switch-root without leaving the fresh writable filesystem
unlabeled.

OBS forces mkosi to produce an aggregate checksum before attaching the final
Secure Boot and verity signatures. A post-output hook removes exactly that
stale aggregate before publication. Every published final artifact is instead
verified against its OBS-generated, project-signed SHA-256 file.

The module-lockdown service starts only after the declared modules and nftables
policy load. It clears the modprobe helper path and sets
`kernel.modules_disabled=1`, which cannot be reversed until reboot. This
reduces post-boot kernel attack surface but means required hardware, storage,
crypto, and network drivers must be available in the UKI/initrd or declared in
`modules-load.d` before release.

Yama scope 3 and the SELinux `deny_ptrace` boolean prohibit process attachment;
scope 3 cannot be relaxed without rebooting. Unprivileged BPF, io_uring, and
all user namespaces are disabled for the boot. No enabled service or installed
container runtime requires a user namespace; Fedora's `chrony-wait.service` is
explicitly disabled. Kexec, userfaultfd,
executable memfd fallback, kernel pointers/logs, SysRq, unsafe line-discipline
autoload, and core dumps are disabled or restricted. Core dumping is denied by
the kernel pipe target, system and user manager limits, PAM limits, the
systemd-coredump configuration, and the disabled coredump socket.

At SELinux priority 300, secureblue-derived CIL policy prevents non-kernel
domains from creating or using AF_ALG kernel crypto sockets, IPsec key and XFRM
sockets, packet-radio families, and legacy families not needed by a VPS web
server. The AF_ALG policy retains secureblue's `bluetooth_t` exception, but
this image does not ship Bluetooth userspace. Adding IPsec, SCTP, CAN,
Bluetooth, or container functionality requires a new policy and threat-model
review.

## Network policy

The nftables service loads the complete immutable policy before the network is
configured. nginx, Certbot renewal, the SSH socket, and chrony require both the
firewall and module-lockdown services, so failure is closed.

Inbound policy permits:

- established and related traffic;
- DHCP client replies and necessary rate-limited ICMP/ICMPv6;
- new TCP connections to ports 80 and 443 and QUIC on UDP 443 with global and
  source-keyed admission limits, plus per-source and global concurrent TCP
  connection ceilings below nginx's worker capacity;
- new TCP connections to port 22 only from the mutable IPv4 or IPv6
  administrator sets, with a much lower rate limit.

Forwarding is denied. Strict FIB checks implement reverse-path filtering for
both address families and reject weak-host traffic.

Outbound policy first permits established replies. systemd-network, chrony
(NTP/UDP 123 and NTS-KE/TCP 4460), and Certbot can create only their
protocol-specific flows. systemd-resolved can connect only to Cloudflare's two
IPv4 and two IPv6 anycast endpoints on TCP/853; UDP/TCP port 53 egress is
absent. nginx and generic root processes cannot initiate a connection.
systemd's dynamic nftables integration grants HTTPS only to the realized
`systemd-sysupdate.service` cgroup; ordinary login users cannot create
outbound connections. After an administrator replaces the nftables ruleset,
the documented `systemctl daemon-reload` step repopulates the active unit's
dynamic cgroup membership.

This host policy is not a substitute for an upstream provider firewall, DDoS
protection, TLS termination strategy, or network monitoring.

The resolver ignores DHCPv4, DHCPv6, and IPv6 RA DNS data and installs a global
`~.` route to its fixed authenticated upstreams. `DNSOverTLS=yes` and
`DNSSEC=yes` are strict rather than opportunistic. A blocked DoT path or failed
certificate/DNSSEC validation therefore causes resolution failure; the system
does not downgrade to plaintext or an unvalidated provider resolver.

## Administration

There are no embedded user credentials. On first boot, systemd-homed prompts on
the VPS console and creates a LUKS-backed user in `wheel` and
`systemd-journal`. Polkit authorizes run0; sudo is absent.
Fedora's `mount` and `umount` binaries remain available at mode 0755, so
administrators and recovery units can use them through an already privileged
`run0` context without exposing their package-default SUID transition.
The unused `pam_timestamp_check` helper is deleted. `unix_chkpwd` and
`polkit-agent-helper-1` retain their Fedora modes because they are part of the
PAM/polkit authentication path; their removal requires a booted console and
`run0` authentication test.

SSH is socket activated but unreachable until an administrator populates
`/etc/particleos/ssh-allowlist.nft`. SSH accepts only public-key
authentication and Ed25519 host/user keys. Initial public-key installation and
firewall changes therefore require console or trusted out-of-band access.

Mutable operator-controlled paths are intentionally limited:

- `/etc/particleos/ssh-allowlist.nft`;
- `/var/www/html` (labelled for read-only nginx content; Certbot can write only
  `.well-known/acme-challenge`);
- `/var/lib/particleos/nginx/conf.d`;
- `/etc/letsencrypt` (dedicated Certbot ownership with Fedora certificate labels).

Configuration under `/usr/lib/particleos` changes only through a new signed
image. Certbot state and TLS private keys are owned by the non-login `certbot`
account. nginx's root master reads certificates during start/reload; workers do
not receive write access. Renewal cannot access the systemd manager socket and
can only request the fixed validator/reloader by creating a watched runtime
file.

## nginx scope

The default HTTP virtual host permits GET and HEAD only for the ACME challenge
path and returns 404 for all other requests, avoiding a Host-header-controlled
open redirect. Unknown TLS/QUIC names are rejected. The domain-specific
template uses a fixed-host HTTPS redirect. Provisioned virtual hosts serve
static files over HTTP/1.1, HTTP/2, and HTTP/3. Dotfiles, directory indexing,
oversized request bodies/headers, excessive ranges, and high per-source
request/connection rates are rejected. The default headers use a restrictive
CSP suitable for the shipped static placeholder.

Operators must review CSP, cross-origin isolation, caching, HSTS, HTTP-to-HTTPS
redirects, and request size when adding an application. Certbot is included
only with the webroot HTTP-01 authenticator; DNS plugins and the nginx
configuration-rewriting plugin are absent. Dynamic runtimes, reverse proxies,
uploads, databases, and application frameworks are not present. Adding one
changes the threat model and requires its own service account, egress rule,
systemd sandbox, SELinux policy, and update plan.

## Release verification

A release is not complete until the exact OBS artifact has been:

1. built from an immutable reviewed commit;
2. checked against every OBS project-signed per-artifact SHA-256 file and
   inspected for successful image manifest generation;
3. installed and booted with Secure Boot, TPM2 encryption, dm-verity, IPE, and
   SELinux enforcement active;
4. tested for firewall fail-closed behavior, DoT-only resolver egress, local
   DNSSEC success/failure cases, and empty SSH allowlists;
5. checked with `systemd-analyze security` for the exposed services;
6. tested for nginx configuration, HTTP behavior, update, rollback, first-boot
   provisioning, recovery access, Certbot staging issuance, renewal deploy
   reload, ptrace/user-namespace denial, zero core-dump artifacts, and enforced
   SELinux socket denials.

Static repository validation cannot prove the behavior of a Fedora kernel,
firmware, OBS worker, generated UKI, TPM implementation, or target hardware.
