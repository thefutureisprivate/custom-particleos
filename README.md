# ParticleOS Webserver

ParticleOS Webserver is a minimal, immutable Fedora 44 x86-64 appliance for
serving static web content with nginx on VPSs. It is built natively by the Open
Build Service (OBS) with mkosi and systemd's particleOS layout.

There is intentionally no `Containerfile`, OCI image, bootc layer, or
container build. The native build description is [`mkosi.conf`](./mkosi.conf);
the OBS entry point is
[`.obs/fedora/x86-64/webserver/mkosi.conf`](./.obs/fedora/x86-64/webserver/mkosi.conf).

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

The default image has:

- OBS-signed Unified Kernel Images, expected-PCR policy signing, Secure Boot,
  IPE enforcement, and signed dm-verity for the immutable `/usr` slots;
- TPM2-encrypted writable root and swap partitions;
- Fedora SELinux in enforcing targeted mode;
- GrapheneOS- and secureblue-derived kernel, allocator, TCP, nftables, chrony,
  OpenSSH, nginx, and systemd service hardening;
- authenticated DNS over TLS to Cloudflare with fail-closed local DNSSEC
  validation, no DHCP/RA resolver override, and no plaintext DNS egress;
- complete ptrace attachment denial, disabled user namespaces, secureblue
  userspace socket-class restrictions, and layered core-dump prevention;
- `mount` and `umount` retained for `run0` and recovery without their Fedora
  SUID-root mode, with the unused SUID `pam_timestamp_check` helper removed;
- secureblue's signed `hardened_malloc` package preloaded for system and user
  processes, with the compatibility shim used by its systemd service baseline;
- irreversible kernel-module loading disablement after the early boot modules
  and firewall are loaded;
- an nftables default-deny policy, pre-conntrack service filtering, strict
  dual-stack reverse-path filtering, source-keyed admission limits, an empty
  SSH source allowlist, and stateful service-specific egress;
- key-only Ed25519 SSH with root login, passwords, forwarding, tunnels, and
  unused authentication methods disabled;
- a sandboxed nginx-core serving HTTPS over HTTP/1.1, HTTP/2, and HTTP/3, with
  bounded journal logging, strict request limits, modern TLS defaults, security
  headers, rate limits, and no version disclosure;
- non-root Certbot HTTP-01 issuance using the ACME `shortlived` profile, with a
  fixed file-triggered nginx validation/reload boundary;
- no crash dumps, no suspend/hibernation, no desktop stack, no default password,
  no weak-dependency recommendations, no packaged documentation, and no
  embedded private key;
- HTTPS-only Fedora, openSUSE build-tools, ParticleOS OBS, OBS systemd, and
  system-update transports;
- systemd `run0` plus polkit for administration. `sudo` is not installed.

See [docs/SECURITY-MODEL.md](./docs/SECURITY-MODEL.md) for trust boundaries,
GrapheneOS hardening coverage, and deliberate exclusions.

## Build in OBS

OBS is the authoritative production build environment. This follows the native
particleOS OBS mechanism documented in the
[OBS image package format guide](https://www.open-build-service.org/help/manuals/obs-user-guide/cha-obs-package-formats)
and its
[SCM build-recipe extraction guide](https://openbuildservice.org/help/manuals/obs-user-guide/cha-obs-concepts).

1. Create the `particleos-fedora-webserver` image package in the
   [`home:thefutureisprivate`](https://build.opensuse.org/repositories/home:thefutureisprivate)
   OBS project.

2. Add these lines to the OBS project configuration:

   ```text
   Type: mkosi
   Repotype: checksumsfile:rawsig staticlinks
   ```

3. Copy [`.obs/_service.example`](./.obs/_service.example) into the OBS package
   as `_service`. Replace `REPLACE_WITH_REVIEWED_COMMIT` with the full immutable
   commit ID selected for the release. The
   `obs_scm` service exports the nested webserver mkosi recipe as the package
   build description.

4. Ensure the OBS package builds against the Fedora 44 repositories and the
   `system:systemd` Fedora 44 repository selected by
   [`mkosi.profiles/obs-repos`](./mkosi.profiles/obs-repos).

5. Run the source service and build:

   ```sh
   osc service run
   osc commit
   osc results
   ```

The recipe includes `mkosi-obs` and carries `# needssslcertforbuild`. OBS
therefore supplies the project certificate to sign the bootloader, UKIs,
expected PCR policy, and dm-verity metadata without exposing the project private
key to this repository.

For automatic source-service triggers, copy
[`.obs/workflows.example.yml`](./.obs/workflows.example.yml) to the SCM
workflow configuration. The service remains pinned until its reviewed commit
is explicitly advanced.

## Validate a change

Run the repository checks before updating the OBS package:

```sh
./scripts/validate.sh
```

The checks reject container recipes, Fedora releases other than 44, desktop
packages, `sudo`, known-password credentials, private-key files, and missing
security invariants. A successful static check does not replace an OBS build
and boot test.

For a release, pin the source service to the reviewed commit, build it in OBS,
inspect the manifest, boot the image with Secure Boot and TPM2 in a disposable
machine, and verify the effective unit sandboxes with
`systemd-analyze security`.

The release test must also confirm that `resolvectl status` reports DNS over
TLS enabled and DNSSEC supported/enabled, a valid signed name resolves, a
deliberately broken DNSSEC name fails, and the firewall exposes no resolver
flow on port 53.

## Install

The virtual machine must expose UEFI Secure Boot and a TPM2-compatible vTPM.
Guest microcode packages are intentionally omitted: CPU microcode is the VPS
hypervisor/provider's responsibility. Put Secure Boot into setup mode before
the first boot so the OBS project certificate and included
Microsoft UEFI certificates can be enrolled. Protect the firmware settings
with an administrator password afterward.

Import or write the OBS raw disk image directly to the VPS boot volume. The
production UKI intentionally contains no interactive or destructive installer
profile. On first boot, the console wizard creates a LUKS-backed systemd-homed
administrator. The account is added to `wheel` and `systemd-journal`; no fixed
account or password is built into the image.

Use `run0` for privileged operations:

```sh
run0 systemctl status nginx.service
run0 journalctl -u nginx.service
```

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
site. Its state is owned by the dedicated `certbot` account under
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
the dynamic cgroup set if `systemd-sysupdate.service` is active while the
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

The retained Fedora particleOS `systemd-sysupdate` transfer definitions update
the A/B `/usr`, verity metadata, and UKI artifacts produced by OBS. Their
artifact match patterns derive from the `%M` image ID, so they resolve to
`ParticleOS-Webserver` on this image.

The enabled timer runs updates inside `systemd-sysupdate.service`. PID 1
publishes that unit's dynamic cgroup ID into nftables, granting only the
updater—not generic root processes—new HTTPS egress. Trigger a manual check
through the unit rather than executing the binary directly:

```sh
run0 systemctl start systemd-sysupdate.service
```

The update source is fixed to the `home:thefutureisprivate` OBS project's
`*_images` repository. The separate `system:systemd` repository remains only a
build-time source for current systemd packages. Fedora packages use the
HTTPS-only Fedora primary mirror rather than mirror-manager responses that may
contain plaintext transports. Treat OBS project membership,
the project certificate, the pinned source-service revision, the vendored
ParticleOS OBS repository key, and Fedora/systemd repositories as
release-critical trust roots.

Configuration under `/usr/lib/particleos` is immutable and changes through a
new signed image. Per-machine SSH policy, Certbot state, nginx virtual hosts,
and web content are the only intended mutable administration surfaces. Add
required virtual hardware drivers to the early module list before building:
module loading is permanently disabled for the rest of each boot.
