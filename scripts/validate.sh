#!/usr/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
    printf 'validation error: %s\n' "$*" >&2
    exit 1
}

require_fixed() {
    local needle=$1
    local file=$2
    grep -Fq -- "$needle" "$file" ||
        fail "$file does not contain required setting: $needle"
}

reject_fixed() {
    local needle=$1
    local file=$2
    if grep -Fq -- "$needle" "$file"; then
        fail "$file contains forbidden setting: $needle"
    fi
}

extract_stanza() {
    local stanza=$1
    local file=$2
    awk -v stanza="$stanza" '
        $0 == stanza "=" { active = 1; next }
        active && !NF { exit }
        active { sub(/^[[:space:]]+/, ""); print }
    ' "$file"
}

if find . -path ./.git -prune -o -type f \( -iname 'Containerfile*' -o -iname 'Dockerfile*' \) -print |
        grep -q .; then
    fail "container recipes are forbidden; this is a native mkosi image"
fi

require_fixed "Distribution=fedora" mkosi.conf
require_fixed "Release=44" mkosi.conf
require_fixed "Architecture=x86-64" mkosi.conf
require_fixed "Mirror=https://dl.fedoraproject.org/pub/fedora" mkosi.conf
require_fixed "ToolsTreeMirror=https://download.opensuse.org" mkosi.conf
require_fixed "SELinuxRelabel=yes" mkosi.conf
require_fixed "WithDocs=no" mkosi.conf
require_fixed "WithRecommends=no" mkosi.conf
require_fixed "SecureBoot=yes" mkosi.conf
require_fixed "SignExpectedPcr=no" mkosi.conf
require_fixed "SignExpectedPcr=no" mkosi.uki-profiles/95-emergency.conf
require_fixed "TPM2PCRs=7" mkosi.extra/usr/lib/repart.d/30-swap.conf
require_fixed "TPM2PCRs=7" mkosi.extra/usr/lib/repart.d/40-root.conf
require_fixed "CopyFiles=/usr/share/factory/root:/" mkosi.extra/usr/lib/repart.d/40-root.conf
reject_fixed "MakeDirectories=" mkosi.extra/usr/lib/repart.d/40-root.conf
reject_fixed "MakeSymlinks=" mkosi.extra/usr/lib/repart.d/40-root.conf
require_fixed "root_skeleton=\"\$BUILDROOT/usr/share/factory/root\"" mkosi.finalize
require_fixed "ln -sfn /usr/share/factory/etc/selinux" mkosi.finalize
require_fixed "chroot \"\$BUILDROOT\" /usr/sbin/setfiles -F" mkosi.finalize
require_fixed "-r /usr/share/factory/root" mkosi.finalize
for initrd_config in mkosi.conf.d/fedora/mkosi.conf .obs/fedora/x86-64/webserver/mkosi.conf; do
    if extract_stanza "InitrdPackages" "$initrd_config" | grep -Fxq selinux-policy-targeted; then
        fail "$initrd_config must not load enforcing policy from an unlabeled cpio initrd"
    fi
done
selinux_relabel_unit=mkosi.extra/usr/lib/systemd/system/particleos-selinux-runtime-relabel.service
selinux_udev_service_dropin=mkosi.extra/usr/lib/systemd/system/systemd-udevd.service.d/10-selinux-runtime-relabel.conf
selinux_udev_kernel_dropin=mkosi.extra/usr/lib/systemd/system/systemd-udevd-kernel.socket.d/10-selinux-runtime-relabel.conf
selinux_udev_varlink_dropin=mkosi.extra/usr/lib/systemd/system/systemd-udevd-varlink.socket.d/10-selinux-runtime-relabel.conf
require_fixed "DefaultDependencies=no" "$selinux_relabel_unit"
require_fixed "ConditionSecurity=selinux" "$selinux_relabel_unit"
require_fixed "ExecStart=/usr/sbin/restorecon -RF /dev /run/udev" "$selinux_relabel_unit"
require_fixed "RemainAfterExit=yes" "$selinux_relabel_unit"
require_fixed "Before=systemd-udevd.service systemd-udevd-kernel.socket systemd-udevd-varlink.socket" "$selinux_relabel_unit"
for selinux_udev_dropin in "$selinux_udev_service_dropin" "$selinux_udev_kernel_dropin" "$selinux_udev_varlink_dropin"; do
    require_fixed "Requires=particleos-selinux-runtime-relabel.service" "$selinux_udev_dropin"
    require_fixed "After=particleos-selinux-runtime-relabel.service" "$selinux_udev_dropin"
done
require_fixed "systemd-udevd-kernel.socket systemd-udevd-varlink.socket" "$selinux_udev_service_dropin"
require_fixed "IgnoreOnIsolate=no" "$selinux_udev_kernel_dropin"
for split_config in mkosi.conf .obs/fedora/x86-64/webserver/mkosi.conf; do
    if ! awk '
            $0 == "SplitArtifacts=" { reset = 1; next }
            reset && $0 == "SplitArtifacts=uki,partitions,roothash,os-release,repart-definitions" { found = 1 }
            END { exit !found }
        ' "$split_config"; then
        fail "$split_config must preserve OBS verity inputs while excluding PCR artifacts"
    fi
    if grep -Eq '^SplitArtifacts=(.*,)?pcrs(,|$)' "$split_config"; then
        fail "$split_config embeds the OBS RSA-4096 key as an unusable TPM policy key"
    fi
done
if rg -n '^SignExpectedPcr=(yes|true|1)$' mkosi.conf mkosi.uki-profiles; then
    fail "expected-PCR signing is incompatible with the OBS RSA-4096 project key"
fi
if find mkosi.uefi.db mkosi.uefi.KEK -type f -print 2>/dev/null | grep -q .; then
    fail "only the mkosi-obs project certificate may be enrolled in UEFI"
fi
require_fixed "ipe.enforce=1" mkosi.conf
require_fixed "lockdown=confidentiality" mkosi.conf
for kernel_argument in \
        audit_backlog_limit=8192 \
        init_on_alloc=1 \
        init_on_free=1 \
        page_alloc.shuffle=1 \
        randomize_kstack_offset=on \
        module.sig_enforce=1 \
        rd.shell=0 \
        rd.emergency=halt; do
    require_fixed "$kernel_argument" mkosi.conf
    require_fixed "$kernel_argument" mkosi.uki-profiles/95-emergency.conf
done
if rg -n "preempt=none" mkosi.conf mkosi.uki-profiles; then
    fail "the current Fedora kernel rejects preempt=none"
fi

obs_recipe=.obs/fedora/x86-64/webserver/mkosi.conf
require_fixed "# needssslcertforbuild" "$obs_recipe"
require_fixed "Include=mkosi-obs" "$obs_recipe"
require_fixed "Release=44" "$obs_recipe"
require_fixed "Mirror=https://dl.fedoraproject.org/pub/fedora" "$obs_recipe"
require_fixed "ToolsTreeMirror=https://download.opensuse.org" "$obs_recipe"
require_fixed "Profiles=obs-sysupdate" "$obs_recipe"
require_fixed "WithRecommends=no" "$obs_recipe"
checksum_hook=mkosi.postoutput.d/90-remove-first-pass-checksum
test -x "$checksum_hook" || fail "$checksum_hook must be executable"
require_fixed "Refusing unsafe checksum path" "$checksum_hook"
require_fixed "rm -f --" "$checksum_hook"
xmllint --noout .obs/_service.example
xmllint --noout .obs/ipe-policy-meta.example.xml
xmllint --noout .obs/project-meta.example.xml
require_fixed "https://github.com/thefutureisprivate/particleos-webserver.git" .obs/_service.example
require_fixed "REPLACE_WITH_REVIEWED_COMMIT" .obs/_service.example
require_fixed "project: home:thefutureisprivate" .obs/workflows.example.yml
require_fixed '<path project="Fedora:44" repository="update"/>' .obs/project-meta.example.xml
if rg -n '<path project="Fedora:44" repository="standard"/>' .obs/project-meta.example.xml; then
    fail "OBS must use Fedora 44 updates rather than the frozen release repository"
fi

if ! diff -u \
        <({ extract_stanza Packages mkosi.conf; extract_stanza Packages mkosi.conf.d/fedora/mkosi.conf; } | sort -u) \
        <(extract_stanza Packages "$obs_recipe" | sort -u); then
    fail "OBS Packages= must equal the main and Fedora package union"
fi

if ! diff -u \
        <(extract_stanza InitrdPackages mkosi.conf.d/fedora/mkosi.conf | sort -u) \
        <(extract_stanza InitrdPackages "$obs_recipe" | sort -u); then
    fail "OBS InitrdPackages= must equal the Fedora initrd package set"
fi

for recipe in mkosi.conf "$obs_recipe"; do
    if grep -Eq '^[[:space:]]*sudo[[:space:]]*$' "$recipe"; then
        fail "$recipe installs sudo; ParticleOS Webserver uses run0"
    fi
    if grep -Eq '^[[:space:]]*nginx[[:space:]]*$' "$recipe"; then
        fail "$recipe installs the nginx metapackage instead of nginx-core"
    fi
    require_fixed "certbot" "$recipe"
    require_fixed "hardened_malloc" "$recipe"
    require_fixed "nginx-core" "$recipe"
    require_fixed "no_rlimit_as" "$recipe"
    require_fixed "polkit" "$recipe"
done

require_fixed "authselect" mkosi.conf.d/fedora/mkosi.conf
require_fixed "authselect" "$obs_recipe"
require_fixed "/usr/bin/pam_timestamp_check" mkosi.conf
require_fixed "/usr/bin/pam_timestamp_check" "$obs_recipe"

composed_packages=$(
    extract_stanza Packages mkosi.conf
    extract_stanza Packages mkosi.conf.d/fedora/mkosi.conf
)

for removed_package in hostname iproute iputils p11-kit passwd systemd-ukify; do
    if grep -Fxq "$removed_package" <<<"$composed_packages"; then
        fail "$removed_package is forbidden in the target package set"
    fi
done

for required_dependency in authselect findutils policycoreutils sed; do
    if ! grep -Fxq "$required_dependency" <<<"$composed_packages"; then
        fail "$required_dependency is missing from the composed target package set"
    fi
done

require_fixed "baseurl=https://download.opensuse.org/repositories/home:/thefutureisprivate/Fedora_44/" mkosi.resources/particleos-obs.repo
require_fixed "priority=1" mkosi.resources/particleos-obs.repo
require_fixed "includepkgs=hardened_malloc,ipe-policy,no_rlimit_as" mkosi.resources/particleos-obs.repo
require_fixed "skip_if_unavailable=False" mkosi.resources/particleos-obs.repo
require_fixed "repo_gpgcheck=1" mkosi.resources/particleos-obs.repo
require_fixed "excludepkgs=ipe-policy" mkosi.profiles/obs-repos/mkosi.conf.d/fedora/mkosi.conf.d/44.repo
require_fixed '<enable repository="Fedora_44" arch="x86_64"/>' .obs/ipe-policy-meta.example.xml
printf '%s  %s\n' \
    5fe4715ba5d0fb9abf18915ea38213c45240fe828a7aa52c574634a13484814c \
    mkosi.resources/particleos-obs-pubkey.gpg | sha256sum --check --status - ||
    fail "the pinned ParticleOS OBS public key changed"

if rg -n 'amd-ucode-firmware|microcode_ctl' mkosi.conf mkosi.conf.d "$obs_recipe"; then
    fail "guest microcode packages are forbidden for the VPS image"
fi

require_fixed "--member-of=wheel,systemd-journal"     mkosi.extra/usr/lib/systemd/system/systemd-homed-firstboot.service.d/40-particleos-admin.conf
require_fixed "PermitRootLogin no"     mkosi.extra/etc/ssh/sshd_config.d/40-particleos-hardening.conf
require_fixed "PasswordAuthentication no"     mkosi.extra/etc/ssh/sshd_config.d/40-particleos-hardening.conf
require_fixed "authenticator = webroot" mkosi.extra/usr/lib/particleos/certbot/cli.ini
require_fixed "webroot-path = /var/www/html" mkosi.extra/usr/lib/particleos/certbot/cli.ini
require_fixed "required-profile = shortlived" mkosi.extra/usr/lib/particleos/certbot/cli.ini
require_fixed "deploy-hook = /usr/bin/touch /run/particleos-certbot/reload-request"     mkosi.extra/usr/lib/particleos/certbot/cli.ini
require_fixed "enable certbot-renew.timer"     mkosi.extra/usr/lib/systemd/system-preset/10-particleos.preset
require_fixed "enable particleos-nginx-reload.path"     mkosi.extra/usr/lib/systemd/system-preset/10-particleos.preset
require_fixed "Requires=nftables.service nginx.service particleos-module-lockdown.service particleos-nginx-reload.path"     mkosi.extra/usr/lib/systemd/system/certbot-renew.service.d/40-particleos-hardening.conf
require_fixed "User=certbot" mkosi.extra/usr/lib/systemd/system/certbot-renew.service.d/40-particleos-hardening.conf
require_fixed "InaccessiblePaths=/run/systemd/private /run/dbus/system_bus_socket"     mkosi.extra/usr/lib/systemd/system/certbot-renew.service.d/40-particleos-hardening.conf
require_fixed "UMask=0077" mkosi.extra/usr/lib/systemd/system/certbot-renew.service.d/40-particleos-hardening.conf
require_fixed "PathExists=/run/particleos-certbot/reload-request"     mkosi.extra/usr/lib/systemd/system/particleos-nginx-reload.path
require_fixed "ExecStartPre=/usr/bin/nginx -e stderr -t -q"     mkosi.extra/usr/lib/systemd/system/particleos-nginx-reload.service
require_fixed "policy drop" mkosi.extra/usr/lib/particleos/nftables.conf
require_fixed "meter web_tcp4" mkosi.extra/usr/lib/particleos/nftables.conf
require_fixed "add @web_tcp_conn4 { ip saddr ct count over 64 }" mkosi.extra/usr/lib/particleos/nftables.conf
require_fixed "ct count over 2048" mkosi.extra/usr/lib/particleos/nftables.conf
require_fixed "meter ssh4" mkosi.extra/usr/lib/particleos/nftables.conf
require_fixed "udp dport 443 ct state new" mkosi.extra/usr/lib/particleos/nftables.conf
require_fixed "net.netfilter.nf_conntrack_max = 32768" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "meta skuid certbot tcp dport { 80, 443 } accept"     mkosi.extra/usr/lib/particleos/nftables.conf
require_fixed "meta skuid systemd-resolve ip daddr { 1.1.1.1, 1.0.0.1 } tcp dport 853 accept"     mkosi.extra/usr/lib/particleos/nftables.conf
require_fixed "meta skuid systemd-resolve ip6 daddr { 2606:4700:4700::1111, 2606:4700:4700::1001 } tcp dport 853 accept"     mkosi.extra/usr/lib/particleos/nftables.conf
require_fixed "meta skuid chrony tcp dport 4460 accept"     mkosi.extra/usr/lib/particleos/nftables.conf
require_fixed "socket cgroupv2 level 2 @sysupdate_cgroups tcp dport 443 accept"     mkosi.extra/usr/lib/particleos/nftables.conf
require_fixed "NFTSet=cgroup:inet:particleos_filter:sysupdate_cgroups"     mkosi.extra/usr/lib/systemd/system/systemd-sysupdate.service.d/40-particleos-egress.conf
require_fixed "enable systemd-sysupdate.timer"     mkosi.extra/usr/lib/systemd/system-preset/10-particleos.preset
if grep -Fq 'meta l4proto { tcp, udp } accept' mkosi.extra/usr/lib/particleos/nftables.conf; then
    fail "raw prerouting must not admit every TCP and UDP tuple"
fi
if grep -Eq 'meta skuid.*nginx' mkosi.extra/usr/lib/particleos/nftables.conf; then
    fail "nginx must not be authorized to create new outbound connections"
fi
if grep -Eq 'meta skuid[[:space:]]+root' mkosi.extra/usr/lib/particleos/nftables.conf; then
    fail "generic root processes must not be authorized to create new outbound connections"
fi
if grep -Eq 'systemd-resolve.*(udp|tcp)[[:space:]]+dport[[:space:]]+53' mkosi.extra/usr/lib/particleos/nftables.conf; then
    fail "systemd-resolved must not have plaintext DNS egress"
fi
require_fixed "Requires=nftables.service particleos-module-lockdown.service"     mkosi.extra/usr/lib/systemd/system/nginx.service
require_fixed "ExecStart=/usr/bin/nginx -e stderr" mkosi.extra/usr/lib/systemd/system/nginx.service
require_fixed "Type=exec" mkosi.extra/usr/lib/systemd/system/nginx.service
require_fixed "UMask=0077" mkosi.extra/usr/lib/systemd/system/nginx.service
require_fixed "install --directory --mode=0700 /run/nginx" mkosi.postinst.chroot
require_fixed "rm --force /run/nginx/nginx.pid" mkosi.postinst.chroot
require_fixed "rmdir /run/nginx" mkosi.postinst.chroot
require_fixed "access_log /dev/stdout" mkosi.extra/usr/lib/particleos/nginx/nginx.conf
require_fixed "error_log stderr" mkosi.extra/usr/lib/particleos/nginx/nginx.conf
require_fixed "return 404;" mkosi.extra/usr/lib/particleos/nginx/conf.d/particleos.conf
require_fixed "return 308 https://example.invalid\$request_uri"     mkosi.extra/usr/share/doc/particleos/nginx/https.conf.example
if rg -n 'return 30[1278] https://\$(host|http_host)' mkosi.extra/usr/lib/particleos/nginx; then
    fail "the default virtual host must not produce attacker-controlled redirects"
fi
require_fixed "ssl_reject_handshake on"     mkosi.extra/usr/lib/particleos/nginx/conf.d/particleos.conf
require_fixed "listen 443 quic"     mkosi.extra/usr/share/doc/particleos/nginx/https.conf.example
require_fixed "add_header Alt-Svc"     mkosi.extra/usr/share/doc/particleos/nginx/https.conf.example
if rg -n '^[[:space:]]*(max_headers|ssl_certificate_compression)[[:space:]]' \
        mkosi.extra/usr/lib/particleos/nginx; then
    fail "nginx config uses directives unavailable in Fedora 44 nginx 1.28"
fi
if rg -n '/var/log/nginx' mkosi.extra/usr/lib/particleos/nginx mkosi.extra/usr/lib/systemd/system/nginx.service; then
    fail "nginx logs must use the bounded journal"
fi
require_fixed "kernel.modules_disabled=1"     mkosi.extra/usr/lib/systemd/system/particleos-module-lockdown.service
require_fixed "SELINUX=enforcing" mkosi.extra/etc/selinux/config
require_fixed "Z /var/www/html - - - -" mkosi.extra/usr/lib/tmpfiles.d/etc.conf
require_fixed "Z /etc/letsencrypt - certbot certbot -" mkosi.extra/usr/lib/tmpfiles.d/etc.conf
require_fixed "u certbot" mkosi.extra/usr/lib/sysusers.d/particleos-webserver.conf
require_fixed "kernel.io_uring_disabled = 2" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "kernel.unprivileged_bpf_disabled = 2" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "kernel.yama.ptrace_scope = 3" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "kernel.unprivileged_userns_clone = 0" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "user.max_user_namespaces = 0" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "disable chrony-wait.service"     mkosi.extra/usr/lib/systemd/system-preset/10-particleos.preset
require_fixed "kernel.core_pattern = |/bin/false" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "kernel.oops_limit = 100" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "kernel.warn_limit = 100" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "kernel.printk = 3 3 3 3" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "setsebool -P deny_ptrace=on" mkosi.postinst.chroot
require_fixed "if getsebool container_allow_ptrace" mkosi.postinst.chroot
require_fixed "setsebool -P container_allow_ptrace=off" mkosi.postinst.chroot
require_fixed "trap restore_preload EXIT" mkosi.postinst.chroot
require_fixed "restore_preload" mkosi.postinst.chroot
require_fixed "semodule -X 300 -i" mkosi.postinst.chroot
require_fixed "chmod 0755 /usr/bin/mount /usr/bin/umount" mkosi.postinst.chroot
require_fixed "libhardened_malloc.so" mkosi.extra/etc/ld.so.preload
require_fixed 'DefaultEnvironment="LD_PRELOAD=libhardened_malloc.so libno_rlimit_as.so"'     mkosi.extra/usr/lib/systemd/system.conf.d/40-particleos-hardening.conf
require_fixed "DumpCore=no" mkosi.extra/usr/lib/systemd/system.conf.d/40-particleos-hardening.conf
require_fixed "DefaultLimitCORE=0" mkosi.extra/usr/lib/systemd/system.conf.d/40-particleos-hardening.conf
require_fixed "DumpCore=no" mkosi.extra/usr/lib/systemd/user.conf.d/40-particleos-hardening.conf
require_fixed "* hard core 0" mkosi.extra/usr/lib/security/limits.d/60-particleos-no-coredump.conf
require_fixed "Storage=none" mkosi.extra/usr/lib/systemd/coredump.conf.d/40-particleos.conf
require_fixed "disable systemd-coredump.socket"     mkosi.extra/usr/lib/systemd/system-preset/10-particleos.preset

resolved_conf=mkosi.extra/usr/lib/systemd/resolved.conf.d/40-particleos-dns.conf
require_fixed "DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com 2606:4700:4700::1111#cloudflare-dns.com 2606:4700:4700::1001#cloudflare-dns.com" "$resolved_conf"
require_fixed "FallbackDNS=" "$resolved_conf"
require_fixed "Domains=~." "$resolved_conf"
require_fixed "DNSSEC=yes" "$resolved_conf"
require_fixed "DNSOverTLS=yes" "$resolved_conf"
require_fixed "LLMNR=no" "$resolved_conf"
require_fixed "MulticastDNS=no" "$resolved_conf"
require_fixed "UseDNS=no"     mkosi.extra/usr/lib/systemd/network/89-ethernet.network.d/40-particleos-dns.conf
require_fixed "L+ /etc/resolv.conf - - - - ../run/systemd/resolve/stub-resolv.conf"     mkosi.extra/usr/lib/tmpfiles.d/etc.conf
require_fixed "Before=network-pre.target"     mkosi.extra/usr/lib/systemd/system/nftables.service.d/40-particleos-policy.conf

for socket_policy in \
        secureblue_socket_utils.cil \
        secureblue_deny_alg_sockets.cil \
        secureblue_deny_ipsec_sockets.cil \
        secureblue_deny_obscure_sockets.cil \
        secureblue_deny_packet_radio_sockets.cil; do
    require_fixed "/usr/lib/particleos/selinux/$socket_policy" mkosi.postinst.chroot
    [[ -f "mkosi.extra/usr/lib/particleos/selinux/$socket_policy" ]] ||
        fail "missing SELinux socket policy: $socket_policy"
done
require_fixed "alg_socket" mkosi.extra/usr/lib/particleos/selinux/secureblue_deny_alg_sockets.cil
require_fixed "key_socket" mkosi.extra/usr/lib/particleos/selinux/secureblue_deny_ipsec_sockets.cil
require_fixed "netlink_xfrm_socket" mkosi.extra/usr/lib/particleos/selinux/secureblue_deny_ipsec_sockets.cil

if rg -n '(^|[=:])http://' \
        mkosi.conf "$obs_recipe" mkosi.resources mkosi.profiles/obs-repos \
        mkosi.profiles/obs-sysupdate; then
    fail "RPM and system-update repository transports must use HTTPS"
fi

if [[ -e mkosi.uki-profiles/20-install.conf ]] ||
        rg -n 'ID=install|system-install.target' mkosi.uki-profiles; then
    fail "production UKIs must not contain the destructive installer profile"
fi

for transfer in mkosi.profiles/obs-sysupdate/mkosi.extra/usr/lib/sysupdate.d/*.transfer; do
    require_fixed "Path=https://download.opensuse.org/repositories/home:/thefutureisprivate/%o_%w_images/" "$transfer"
done
if rg -n 'repositories/system:/systemd'     mkosi.profiles/obs-sysupdate/mkosi.extra/usr/lib/sysupdate.d; then
    fail "production sysupdate must use home:thefutureisprivate"
fi

if rg -n -i     '^[[:space:]]*(gnome|gdm|kde|plasma|sddm|sway|xorg|wayland|firefox)([[:space:]]|$)'     mkosi.conf mkosi.conf.d "$obs_recipe"; then
    fail "desktop packages are forbidden"
fi

if rg -n -i     '(mkosi\.rootpw|home\.create\.|hashedPassword|password[[:space:]]*[:=][[:space:]]*["'\''"]?particleos)'     mkosi.conf mkosi.conf.d mkosi.credentials mkosi.extra .obs 2>/dev/null; then
    fail "known-password material is forbidden"
fi

if [[ -n "$(find . -path ./.git -prune -o -type f \( -iname '*.key' -o -iname '*.p12' -o -iname '*.pfx' -o -iname 'id_rsa' -o -iname 'id_ed25519' \) -print)" ]]; then
    fail "private-key files are forbidden"
fi

if rg -n '[[:blank:]]+$' --glob '!.git/**' --glob '!AGENTS.md' .; then
    fail "trailing whitespace is forbidden"
fi

for script in mkosi.bump mkosi.clean mkosi.finalize mkosi.postinst.chroot scripts/*.sh; do
    /usr/bin/bash -n "$script"
done

git diff --check

printf '%s\n' "ParticleOS Webserver static validation passed."
