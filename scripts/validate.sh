#!/usr/bin/bash
# Validation needles intentionally match literal shell expressions.
# shellcheck disable=SC2016
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

roles=(webserver mailserver dnsserver)
declare -A role_image_ids=(
    [webserver]=ParticleOS-Webserver
    [mailserver]=ParticleOS-Mailserver
    [dnsserver]=ParticleOS-Dnsserver
)
declare -A role_packages=(
    [webserver]="certbot nginx-core"
)
base_config=mkosi.images/base/mkosi.conf
initrd_config=mkosi.images/initrd/mkosi.conf
role_policy=mkosi.role.conf
obs_config=mkosi.obs.conf
role_obs_config=mkosi.role.obs.conf
obs_postoutput=mkosi.scripts/particleos-obs-postoutput
obs_build=mkosi.scripts/particleos-obs-build
obs_recipe=.obs/fedora/x86-64/mkosi.conf
service_template=.obs/fedora/x86-64/_service.example
postinst=mkosi.scripts/particleos.postinst.chroot
finalize=mkosi.scripts/particleos.finalize
obs_recipes=("$obs_recipe")

require_fixed "Dependencies=webserver" mkosi.conf
reject_fixed "Dependencies=mailserver" mkosi.conf
reject_fixed "Dependencies=dnsserver" mkosi.conf
require_fixed "Format=none" mkosi.conf
require_fixed "Overlay=no" mkosi.conf
if grep -q '^Profiles=' mkosi.conf; then
    fail "mkosi.conf must not select a profile"
fi
require_fixed "Distribution=fedora" mkosi.conf
require_fixed "Release=44" mkosi.conf
require_fixed "Architecture=x86-64" mkosi.conf
require_fixed "Mirror=https://dl.fedoraproject.org/pub/fedora" mkosi.conf
require_fixed "ToolsTreeMirror=https://download.opensuse.org" mkosi.conf

require_fixed "Format=directory" "$base_config"
require_fixed "Output=base" "$base_config"
require_fixed "ImageId=ParticleOS-Base" "$base_config"
require_fixed "CleanPackageMetadata=no" "$base_config"
require_fixed "Bootable=no" "$base_config"
require_fixed "SELinuxRelabel=no" "$base_config"
require_fixed "ManifestFormat=json" "$base_config"
require_fixed "/boot/*" "$base_config"
require_fixed "Profiles=" "$base_config"
for forbidden_base_setting in \
        "BaseTrees=" \
        "PostInstallationScripts=%D/mkosi.scripts/particleos.postinst.chroot" \
        "FinalizeScripts=%D/mkosi.scripts/particleos.finalize" \
        "Initrds=%O/initrd"; do
    reject_fixed "$forbidden_base_setting" "$base_config"
done

for role in "${roles[@]}"; do
    image_config="mkosi.images/$role/mkosi.conf"
    emergency_uki="mkosi.images/$role/emergency-uki.conf"
    require_fixed "Include=%D/mkosi.role.conf" "$image_config"
    require_fixed "Dependencies=base,initrd" "$image_config"
    require_fixed "BaseTrees=%O/base" "$image_config"
    require_fixed "CleanPackageMetadata=yes" "$image_config"
    require_fixed "Initrds=%O/initrd" "$image_config"
    require_fixed "ImageId=${role_image_ids[$role]}" "$image_config"
    require_fixed "Hostname=particle-" "$image_config"
    require_fixed "UnifiedKernelImageProfiles=%D/$emergency_uki" "$image_config"
    require_fixed "systemd.image_filter=usr=${role_image_ids[$role]}_*" "$image_config"
    require_fixed "systemd.image_filter=usr=${role_image_ids[$role]}_*" "$emergency_uki"
    require_fixed "SignExpectedPcr=no" "$emergency_uki"
done

for dormant_role in mailserver dnsserver; do
    image_config="mkosi.images/$dormant_role/mkosi.conf"
    if [[ -n "$(extract_stanza Packages "$image_config")" ]]; then
        fail "$image_config must not select packages while the role is dormant"
    fi
done
require_fixed "project-provided Stalwart package" mkosi.images/mailserver/mkosi.conf
require_fixed "Empty placeholder" mkosi.images/dnsserver/mkosi.conf
if rg -n '^[[:space:]]*(dovecot|dovecot-pigeonhole|postfix|postfix-pcre|dnsdist|unbound)[[:space:]]*$' \
        mkosi.conf mkosi.role.conf mkosi.images mkosi.profiles .obs/fedora/x86-64; then
    fail "dormant mail and DNS daemon packages must not be selected"
fi

require_fixed "Format=disk" "$role_policy"
require_fixed "SplitArtifacts=uki,partitions,roothash,os-release,repart-definitions" "$role_policy"
reject_fixed "SplitArtifacts=pcrs" "$role_policy"
require_fixed "RepartDirectories=%D/mkosi.repart" "$role_policy"
require_fixed "Bootable=yes" "$role_policy"
require_fixed "CleanScripts=%D/mkosi.scripts/particleos.clean" "$role_policy"
require_fixed "SELinuxRelabel=yes" "$role_policy"
require_fixed "WithDocs=no" "$role_policy"
require_fixed "WithRecommends=no" "$role_policy"
require_fixed "ExtraTrees=%D/mkosi.extra" "$role_policy"
require_fixed "%D/mkosi.resources:/usr/lib/particleos/sysupdate-key-source" "$role_policy"
require_fixed "SecureBoot=yes" "$role_policy"
require_fixed "SignExpectedPcr=no" "$role_policy"
require_fixed "PostInstallationScripts=%D/$postinst" "$role_policy"
require_fixed "FinalizeScripts=%D/$finalize" "$role_policy"
require_fixed "KernelInitrdModules=default,-binfmt_misc" "$role_policy"
require_fixed "PostOutputScripts=%D/mkosi.scripts/remove-first-pass-checksum" "$role_policy"

require_fixed "PathExists=/usr/src/packages/SOURCES/_projectcert.crt" "$obs_config"
require_fixed "Include=mkosi-obs" "$obs_config"
require_fixed "Include=%D/mkosi.obs.conf" mkosi.conf
require_fixed "PostOutputScripts=" mkosi.conf
require_fixed "PathExists=/usr/src/packages/SOURCES/_projectcert.crt" "$role_obs_config"
require_fixed "CompressOutput=zstd" "$role_obs_config"
require_fixed "SecureBoot=no" "$role_obs_config"
require_fixed "SignExpectedPcr=no" "$role_obs_config"
require_fixed "Verity=defer" "$role_obs_config"
require_fixed "Checksum=yes" "$role_obs_config"
require_fixed "ExtraTrees=%D/mkosi.obs.extra" "$role_obs_config"
require_fixed "PostOutputScripts=%D/$obs_postoutput" "$role_obs_config"
require_fixed "Include=%D/mkosi.role.obs.conf" "$role_policy"
reject_fixed "Include=mkosi-obs" "$role_policy"
test -x "$obs_postoutput" || fail "$obs_postoutput must be executable"
test -x "$obs_build" || fail "$obs_build must be executable"
require_fixed "import mkosi.resources" "$obs_postoutput"
require_fixed '"$mkosi_obs_postoutput" "$@"' "$obs_postoutput"
require_fixed 'obs_build_wrapper=/usr/src/packages/SOURCES/custom-particleos/mkosi.scripts/particleos-obs-build' "$obs_postoutput"
require_fixed 'cp --reflink=auto -- "$obs_build_wrapper" "$OUTPUTDIR/particleos-obs-build"' "$obs_postoutput"
require_fixed "'[Content]'" "$obs_postoutput"
reject_fixed "'[Build]'" "$obs_postoutput"
require_fixed "BuildScripts=/usr/src/packages/SOURCES/particleos-obs-build" "$obs_postoutput"
require_fixed "import mkosi.resources" "$obs_build"
require_fixed '"$mkosi_obs_build" "$@"' "$obs_build"
require_fixed "base.manifest.gz" "$obs_build"
require_fixed 'cp --reflink=auto -- "$base_manifest" "$obs_output_dir/"' "$obs_build"

require_fixed "# needssslcertforbuild" "$obs_recipe"
require_fixed "Dependencies=webserver" "$obs_recipe"
xmllint --noout "$service_template"
require_fixed "https://github.com/thefutureisprivate/custom-particleos.git" "$service_template"
require_fixed "REPLACE_WITH_REVIEWED_COMMIT" "$service_template"
require_fixed ".obs/fedora/x86-64/mkosi.conf" "$service_template"
require_fixed "package: custom-particleos" .obs/workflows.example.yml
reject_fixed "package: custom-particleos-webserver" .obs/workflows.example.yml

if ! diff -u \
        <({
            extract_stanza Packages "$base_config"
            extract_stanza VolatilePackages "$base_config"
            extract_stanza Packages "$initrd_config"
            extract_stanza VolatilePackages "$initrd_config"
            extract_stanza Packages mkosi.images/webserver/mkosi.conf
        } | sed '/^$/d' | sort -u) \
        <(extract_stanza BuildPackages "$obs_recipe" | sort -u); then
    fail "$obs_recipe BuildPackages= does not equal the selected graph package closure"
fi

for required_role_package in ${role_packages[webserver]}; do
    require_fixed "$required_role_package" mkosi.images/webserver/mkosi.conf
    require_fixed "$required_role_package" "$obs_recipe"
done
for recipe in "$base_config" mkosi.images/webserver/mkosi.conf "$obs_recipe"; do
    if grep -Eq '^[[:space:]]*sudo[[:space:]]*$' "$recipe"; then
        fail "$recipe installs sudo; ParticleOS uses run0"
    fi
    if grep -Eq '^[[:space:]]*nginx[[:space:]]*$' "$recipe"; then
        fail "$recipe installs the nginx metapackage instead of nginx-core"
    fi
done

composed_packages=$(
    extract_stanza Packages "$base_config"
    extract_stanza VolatilePackages "$base_config"
)
for removed_package in hostname iproute iputils p11-kit passwd systemd-ukify; do
    if grep -Fxq "$removed_package" <<<"$composed_packages"; then
        fail "$removed_package is forbidden in the target package set"
    fi
done
for required_dependency in authselect findutils gnupg2 libcurl-minimal policycoreutils sed systemd-container; do
    if ! grep -Fxq "$required_dependency" <<<"$composed_packages"; then
        fail "$required_dependency is missing from the shared base package set"
    fi
done
for required_base_package in hardened_malloc no_rlimit_as polkit authselect; do
    require_fixed "$required_base_package" "$base_config"
    require_fixed "$required_base_package" "$obs_recipe"
done

if extract_stanza Packages "$initrd_config" | grep -Fxq selinux-policy-targeted; then
    fail "$initrd_config must not load enforcing policy from an unlabeled cpio initrd"
fi
initrd_packages=$(extract_stanza Packages "$initrd_config")
for required_initrd_package in ipe-policy libfdisk; do
    grep -Fxq "$required_initrd_package" <<<"$initrd_packages" ||
        fail "$required_initrd_package is missing from the custom initrd"
done
initrd_volatile_packages=$(extract_stanza VolatilePackages "$initrd_config")
for required_initrd_volatile_package in systemd udev; do
    grep -Fxq "$required_initrd_volatile_package" <<<"$initrd_volatile_packages" ||
        fail "$required_initrd_volatile_package must remain volatile in the custom initrd"
done
require_fixed "/usr/lib/nvpcr" "$initrd_config"
require_fixed "Include=mkosi-initrd" "$initrd_config"
require_fixed "Output=initrd" "$initrd_config"
reject_fixed "InitrdPackages=" mkosi.conf

pcrproduct_dropin=mkosi.extra/usr/lib/systemd/system/systemd-pcrproduct.service.d/40-particleos-nvpcr.conf
pcrlogin_dropin=mkosi.extra/usr/lib/systemd/system/systemd-pcrlogin@.service.d/40-particleos-nvpcr.conf
require_fixed "ConditionPathExists=/run/systemd/nvpcr/hardware.auth" "$pcrproduct_dropin"
require_fixed "ConditionPathExists=/run/systemd/nvpcr/login.auth" "$pcrlogin_dropin"
if rg -n 'particleos-selinux-runtime-relabel|particleos-selinux-runtime.conf' mkosi.extra; then
    fail "systemd already relabels /dev and /run after loading the host SELinux policy"
fi
initrd_udev_kernel_dropin=mkosi.images/initrd/mkosi.extra/usr/lib/systemd/system/systemd-udevd-kernel.socket.d/10-particleos-switch-root.conf
initrd_udev_service_dropin=mkosi.images/initrd/mkosi.extra/usr/lib/systemd/system/systemd-udevd.service.d/10-particleos-switch-root.conf
require_fixed "IgnoreOnIsolate=no" "$initrd_udev_kernel_dropin"
reject_fixed "Requires=" "$initrd_udev_kernel_dropin"
reject_fixed "After=" "$initrd_udev_kernel_dropin"
require_fixed "FileDescriptorStorePreserve=restart" "$initrd_udev_service_dropin"
reject_fixed "FileDescriptorStorePreserve=yes" "$initrd_udev_service_dropin"

if rg -n '^SignExpectedPcr=(yes|true|1)$' "$role_policy" mkosi.images/*/emergency-uki.conf; then
    fail "expected-PCR signing is incompatible with the OBS RSA-4096 project key"
fi
if find mkosi.uefi.db mkosi.uefi.KEK -type f -print 2>/dev/null | grep -q .; then
    fail "only the mkosi-obs project certificate may be enrolled in UEFI"
fi
require_fixed "ipe.enforce=1" "$role_policy"
require_fixed "lockdown=confidentiality" "$role_policy"
for kernel_argument in \
        audit_backlog_limit=8192 \
        rootflags=nosuid,nodev \
        init_on_alloc=1 \
        init_on_free=1 \
        page_alloc.shuffle=1 \
        randomize_kstack_offset=on \
        module.sig_enforce=1 \
        rd.shell=0 \
        rd.emergency=halt; do
    require_fixed "$kernel_argument" "$role_policy"
    for role in "${roles[@]}"; do
        require_fixed "$kernel_argument" "mkosi.images/$role/emergency-uki.conf"
    done
done
if rg -n "preempt=none" "$role_policy" mkosi.images/*/emergency-uki.conf; then
    fail "the current Fedora kernel rejects preempt=none"
fi

require_fixed "TPM2PCRs=7" mkosi.extra/usr/lib/repart.d/30-swap.conf
require_fixed "TPM2PCRs=7" mkosi.extra/usr/lib/repart.d/40-root.conf
require_fixed "CopyFiles=/usr/share/factory/root:/" mkosi.extra/usr/lib/repart.d/40-root.conf
reject_fixed "MakeDirectories=" mkosi.extra/usr/lib/repart.d/40-root.conf
reject_fixed "MakeSymlinks=" mkosi.extra/usr/lib/repart.d/40-root.conf
require_fixed "root_skeleton=\"\$BUILDROOT/usr/share/factory/root\"" "$finalize"
require_fixed 'ln -sfn usr/bin "$root_skeleton/bin"' "$finalize"
require_fixed 'ln -sfn usr/lib "$root_skeleton/lib"' "$finalize"
require_fixed 'ln -sfn usr/lib64 "$root_skeleton/lib64"' "$finalize"
require_fixed 'ln -sfn usr/sbin "$root_skeleton/sbin"' "$finalize"
require_fixed "ln -sfn /usr/share/factory/etc/selinux" "$finalize"
require_fixed "chroot \"\$BUILDROOT\" /usr/sbin/setfiles -F" "$finalize"
require_fixed "-r /usr/share/factory/root" "$finalize"
require_fixed "chroot \"\$BUILDROOT\" /usr/bin/chcon -h system_u:object_r:etc_t:s0" "$finalize"
require_fixed "L? /etc/protocols" mkosi.extra/usr/lib/tmpfiles.d/etc.conf

checksum_hook=mkosi.scripts/remove-first-pass-checksum
test -x "$checksum_hook" || fail "$checksum_hook must be executable"
require_fixed "Refusing unsafe checksum path" "$checksum_hook"
require_fixed "rm -f --" "$checksum_hook"
xmllint --noout .obs/ipe-policy-meta.example.xml
xmllint --noout .obs/project-meta.example.xml
require_fixed "project: home:thefutureisprivate" .obs/workflows.example.yml
require_fixed '<path project="Fedora:44" repository="update"/>' .obs/project-meta.example.xml
require_fixed '<path project="system:systemd" repository="Fedora_44"/>' .obs/project-meta.example.xml
require_fixed "baseurl=https://download.opensuse.org/repositories/system:/systemd/Fedora_44/" mkosi.profiles/obs-repos/mkosi.conf.d/fedora/mkosi.conf.d/44.repo
if rg -n '<path project="Fedora:44" repository="standard"/>' .obs/project-meta.example.xml; then
    fail "OBS must use Fedora 44 updates rather than the frozen release repository"
fi

for removed_runtime_path in /usr/bin/pam_timestamp_check /usr/bin/systemd-nspawn /usr/bin/systemd-vmspawn /usr/lib/systemd/systemd-importd /usr/bin/dirmngr /usr/bin/gpg-agent /usr/libexec/keyboxd /usr/lib/systemd/user/gpg-agent.socket; do
    require_fixed "$removed_runtime_path" "$role_policy"
done
if rg -n '^[[:space:]]*/usr/lib/systemd/systemd-pull[[:space:]]*$' "$role_policy"; then
    fail "systemd-pull must be retained for systemd-sysupdate"
fi
require_fixed "/usr/lib/particleos/sysupdate-key-source/particleos-obs-pubkey.gpg" \
    mkosi.scripts/particleos.postinst.chroot
require_fixed "/usr/lib/systemd/import-pubring.pgp" mkosi.scripts/particleos.postinst.chroot
require_fixed "gpg --batch --yes --dearmor" mkosi.scripts/particleos.postinst.chroot
require_fixed "chmod 0644 /usr/lib/systemd/import-pubring.pgp" mkosi.scripts/particleos.postinst.chroot
for disabled_container_unit in \
        machines.target \
        systemd-importd.socket \
        systemd-machined.socket \
        systemd-mountfsd.socket \
        systemd-nsresourced.socket; do
    require_fixed "disable $disabled_container_unit" \
        mkosi.extra/usr/lib/systemd/system-preset/10-particleos.preset
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

if rg -n 'amd-ucode-firmware|microcode_ctl' mkosi.conf mkosi.role.conf mkosi.images mkosi.profiles "${obs_recipes[@]}"; then
    fail "guest microcode packages are forbidden for the VPS image"
fi

require_fixed "--member-of=wheel,systemd-journal"     mkosi.extra/usr/lib/systemd/system/systemd-homed-firstboot.service.d/40-particleos-admin.conf
require_fixed "DefaultStorage=directory" \
    mkosi.extra/usr/lib/systemd/homed.conf.d/40-particleos.conf
require_fixed "pam_systemd_home\\.so" mkosi.scripts/particleos.postinst.chroot
require_fixed "pam_unix\\.so/i auth" mkosi.scripts/particleos.postinst.chroot
require_fixed "PermitRootLogin no"     mkosi.extra/etc/ssh/sshd_config.d/40-particleos-hardening.conf
require_fixed "PasswordAuthentication no"     mkosi.extra/etc/ssh/sshd_config.d/40-particleos-hardening.conf
require_fixed "HostKey /etc/ssh/ssh_host_ed25519_key"     mkosi.extra/etc/ssh/sshd_config.d/40-particleos-hardening.conf
require_fixed "PermitListen none"     mkosi.extra/etc/ssh/sshd_config.d/40-particleos-hardening.conf
require_fixed "PermitOpen none"     mkosi.extra/etc/ssh/sshd_config.d/40-particleos-hardening.conf
sshd_template_dropin=mkosi.extra/usr/lib/systemd/system/sshd@.service.d/40-particleos-hardening.conf
require_fixed "Requires=nftables.service particleos-module-lockdown.service" "$sshd_template_dropin"
require_fixed "NoNewPrivileges=no" "$sshd_template_dropin"
reject_fixed "NoNewPrivileges=yes" "$sshd_template_dropin"
require_fixed "CapabilityBoundingSet=" "$sshd_template_dropin"
require_fixed "ProtectSystem=strict" "$sshd_template_dropin"
require_fixed "RestrictNamespaces=yes" "$sshd_template_dropin"
sshd_socket_dropin=mkosi.extra/usr/lib/systemd/system/sshd.socket.d/40-particleos-firewall.conf
require_fixed "DefaultDependencies=no" "$sshd_socket_dropin"
require_fixed "Requires=nftables.service particleos-module-lockdown.service" "$sshd_socket_dropin"
require_fixed "After=nftables.service particleos-module-lockdown.service" "$sshd_socket_dropin"
require_fixed "Requires=sshd-keygen@ed25519.service" "$sshd_socket_dropin"
require_fixed "After=sshd-keygen@ed25519.service" "$sshd_socket_dropin"
require_fixed "Before=shutdown.target" "$sshd_socket_dropin"
require_fixed "Conflicts=shutdown.target" "$sshd_socket_dropin"
require_fixed "ListenStream=0.0.0.0:22" "$sshd_socket_dropin"
require_fixed "ListenStream=[::]:22" "$sshd_socket_dropin"
reject_fixed "enable sshd-keygen.target" \
    mkosi.extra/usr/lib/systemd/system-preset/10-particleos.preset
require_fixed 'ln -sfn /dev/null "$BUILDROOT/usr/lib/systemd/system/sshd-keygen.target"' \
    mkosi.scripts/particleos.finalize
require_fixed "system_u:object_r:bootloader_exec_t:s0" mkosi.scripts/particleos.finalize
require_fixed "/usr/lib/systemd/systemd-bless-boot" mkosi.scripts/particleos.finalize
sshd_keygen_dropin=mkosi.extra/usr/lib/systemd/system/sshd-keygen@.service.d/40-particleos-hardening.conf
require_fixed "CapabilityBoundingSet=" "$sshd_keygen_dropin"
require_fixed "ExecStartPost=/usr/bin/test -s /etc/ssh/ssh_host_ed25519_key" \
    "$sshd_keygen_dropin"
require_fixed "NoNewPrivileges=no" "$sshd_keygen_dropin"
require_fixed "ProtectSystem=strict" "$sshd_keygen_dropin"
require_fixed "ReadWritePaths=/etc/ssh" "$sshd_keygen_dropin"
require_fixed "RestrictAddressFamilies=AF_UNIX" "$sshd_keygen_dropin"
require_fixed "SystemCallFilter=@system-service" "$sshd_keygen_dropin"
if [[ -e mkosi.extra/usr/lib/systemd/system/sshd.service.d/40-particleos-hardening.conf ]]; then
    fail "the disabled monolithic sshd.service must not carry the socket-template hardening"
fi
web_extra=mkosi.images/webserver/mkosi.extra
web_preset="$web_extra/usr/lib/systemd/system-preset/20-particleos-webserver.preset"
web_tmpfiles="$web_extra/usr/lib/tmpfiles.d/particleos-webserver.conf"
base_firewall=mkosi.extra/usr/lib/particleos/nftables.conf
web_firewall="$web_extra/usr/lib/particleos/nftables-role.nft"
require_fixed "authenticator = webroot" $web_extra/usr/lib/particleos/certbot/cli.ini
require_fixed "webroot-path = /var/www/html" $web_extra/usr/lib/particleos/certbot/cli.ini
require_fixed "required-profile = shortlived" $web_extra/usr/lib/particleos/certbot/cli.ini
require_fixed "deploy-hook = /usr/bin/touch /run/particleos-certbot/reload-request"     $web_extra/usr/lib/particleos/certbot/cli.ini
require_fixed "enable certbot-renew.timer" "$web_preset"
require_fixed "enable particleos-nginx-reload.path" "$web_preset"
require_fixed "Requires=nftables.service nginx.service particleos-module-lockdown.service particleos-nginx-reload.path"     $web_extra/usr/lib/systemd/system/certbot-renew.service.d/40-particleos-hardening.conf
require_fixed "EnvironmentFile=" \
    $web_extra/usr/lib/systemd/system/certbot-renew.service.d/40-particleos-hardening.conf
require_fixed "User=certbot" $web_extra/usr/lib/systemd/system/certbot-renew.service.d/40-particleos-hardening.conf
require_fixed "RestrictAddressFamilies=AF_INET AF_INET6"     $web_extra/usr/lib/systemd/system/certbot-renew.service.d/40-particleos-hardening.conf
reject_fixed "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX"     $web_extra/usr/lib/systemd/system/certbot-renew.service.d/40-particleos-hardening.conf
require_fixed "UMask=0027" $web_extra/usr/lib/systemd/system/certbot-renew.service.d/40-particleos-hardening.conf
require_fixed "d /var/www/html/.well-known/acme-challenge 2750 certbot nginx -" \
    "$web_tmpfiles"
certbot_reload_path=$web_extra/usr/lib/systemd/system/particleos-nginx-reload.path
certbot_reload_service=$web_extra/usr/lib/systemd/system/particleos-nginx-reload.service
require_fixed "PathExists=/run/particleos-certbot/reload-request" "$certbot_reload_path"
reject_fixed "Requires=nginx.service" "$certbot_reload_path"
reject_fixed "After=nginx.service" "$certbot_reload_path"
require_fixed "Requires=nginx.service" "$certbot_reload_service"
require_fixed "After=nginx.service" "$certbot_reload_service"
require_fixed "ExecStartPre=/usr/bin/nginx -e stderr -t -q" "$certbot_reload_service"
require_fixed "CapabilityBoundingSet=CAP_DAC_OVERRIDE CAP_NET_BIND_SERVICE" \
    "$certbot_reload_service"
require_fixed "LimitNOFILE=32768" "$certbot_reload_service"
require_fixed "policy drop" "$base_firewall"
require_fixed "meter web_tcp4" "$web_firewall"
require_fixed "add @web_tcp_conn4 { ip saddr ct count over 64 }" "$web_firewall"
require_fixed "ct count over 2048" "$web_firewall"
require_fixed "meter ssh4" "$base_firewall"
require_fixed "udp dport 443 ct state new" "$web_firewall"
require_fixed "net.netfilter.nf_conntrack_max = 32768" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "meta skuid certbot tcp dport { 80, 443 } ct state new limit rate 8/second burst 16 packets accept" "$web_firewall"
require_fixed "meta skuid systemd-resolve ip daddr { 1.1.1.1, 1.0.0.1 } tcp dport 853 accept" "$base_firewall"
require_fixed "meta skuid systemd-resolve ip6 daddr { 2606:4700:4700::1111, 2606:4700:4700::1001 } tcp dport 853 accept" "$base_firewall"
require_fixed "meta skuid chrony tcp dport 4460 accept" "$base_firewall"
require_fixed "socket cgroupv2 level 2 @sysupdate_cgroups tcp dport 443 ct state new limit rate 16/second burst 32 packets accept"     mkosi.extra/usr/lib/particleos/nftables.conf
require_fixed "NFTSet=cgroup:inet:particleos_filter:sysupdate_cgroups"     mkosi.extra/usr/lib/systemd/system/systemd-sysupdate-update.service.d/40-particleos-egress.conf
require_fixed "enable systemd-sysupdate-update.timer"     mkosi.extra/usr/lib/systemd/system-preset/10-particleos.preset
base_preset=mkosi.extra/usr/lib/systemd/system-preset/10-particleos.preset
rollback_dropin=mkosi.extra/usr/lib/systemd/system/systemd-boot-check-no-failures.service.d/40-particleos-rollback.conf
web_health_unit="$web_extra/usr/lib/systemd/system/particleos-webserver-health.service"
web_health_check="$web_extra/usr/lib/particleos/health/webserver"

require_fixed "enable systemd-sysupdate-reboot.timer" "$base_preset"
require_fixed "enable systemd-boot-check-no-failures.service" "$base_preset"
require_fixed "FailureAction=reboot" "$rollback_dropin"
require_fixed "ConditionPathExists=/sys/firmware/efi/efivars/LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f" "$rollback_dropin"
require_fixed "Requires=nginx.service" "$web_health_unit"
require_fixed "Before=boot-complete.target" "$web_health_unit"
require_fixed "FailureAction=reboot" "$web_health_unit"
require_fixed "ConditionPathExists=/sys/firmware/efi/efivars/LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f" "$web_health_unit"
require_fixed "RequiredBy=boot-complete.target" "$web_health_unit"
require_fixed "enable particleos-webserver-health.service" "$web_preset"
require_fixed "nginx -e stderr -t -q" "$web_health_check"
require_fixed "/dev/tcp/127.0.0.1/80" "$web_health_check"
require_fixed "HTTP/*" "$web_health_check"

for closed_role in mailserver dnsserver; do
    closed_firewall="mkosi.images/$closed_role/mkosi.extra/usr/lib/particleos/nftables-role.nft"
    require_fixed "all role ingress and egress remains closed." "$closed_firewall"
    reject_fixed " accept" "$closed_firewall"
done
if grep -Fq 'meta l4proto { tcp, udp } accept' "$base_firewall" "$web_firewall"; then
    fail "raw prerouting must not admit every TCP and UDP tuple"
fi
if grep -Eq 'meta skuid.*nginx' "$base_firewall" "$web_firewall"; then
    fail "nginx must not be authorized to create new outbound connections"
fi
if grep -Eq 'meta skuid[[:space:]]+root' "$base_firewall" "$web_firewall"; then
    fail "generic root processes must not be authorized to create new outbound connections"
fi
if grep -Eq 'systemd-resolve.*(udp|tcp)[[:space:]]+dport[[:space:]]+53' "$base_firewall"; then
    fail "systemd-resolved must not have plaintext DNS egress"
fi
require_fixed "Requires=nftables.service particleos-module-lockdown.service"     $web_extra/usr/lib/systemd/system/nginx.service
require_fixed "ExecStart=/usr/bin/nginx -e stderr" $web_extra/usr/lib/systemd/system/nginx.service
require_fixed "Type=exec" $web_extra/usr/lib/systemd/system/nginx.service
require_fixed "UMask=0077" $web_extra/usr/lib/systemd/system/nginx.service
require_fixed "LimitNOFILE=32768" $web_extra/usr/lib/systemd/system/nginx.service
if rg -n 'worker_rlimit_nofile' $web_extra/usr/lib/particleos/nginx; then
    fail "nginx file-descriptor limits must be set by systemd before capabilities are dropped"
fi
require_fixed "install --directory --mode=0700 /run/nginx" mkosi.scripts/particleos.postinst.chroot
require_fixed "rm --force /run/nginx/nginx.pid" mkosi.scripts/particleos.postinst.chroot
require_fixed "rmdir /run/nginx" mkosi.scripts/particleos.postinst.chroot
require_fixed "access_log syslog:server=unix:/run/systemd/journal/dev-log,facility=daemon,tag=nginx,nohostname main" \
    $web_extra/usr/lib/particleos/nginx/nginx.conf
if rg -n 'access_log[[:space:]]+/dev/(stdout|stderr)' $web_extra/usr/lib/particleos/nginx; then
    fail "nginx access logs must use the journald syslog socket, not a stream descriptor path"
fi
require_fixed "error_log stderr" $web_extra/usr/lib/particleos/nginx/nginx.conf
require_fixed "return 404;" $web_extra/usr/lib/particleos/nginx/conf.d/particleos.conf
require_fixed "return 308 https://example.invalid\$request_uri"     $web_extra/usr/share/doc/particleos/nginx/https.conf.example
if rg -n 'return 30[1278] https://\$(host|http_host)' $web_extra/usr/lib/particleos/nginx; then
    fail "the default virtual host must not produce attacker-controlled redirects"
fi
require_fixed "ssl_reject_handshake on"     $web_extra/usr/lib/particleos/nginx/conf.d/particleos.conf
require_fixed "listen 443 quic"     $web_extra/usr/share/doc/particleos/nginx/https.conf.example
require_fixed "add_header Alt-Svc"     $web_extra/usr/share/doc/particleos/nginx/https.conf.example
if rg -n '^[[:space:]]*(max_headers|ssl_certificate_compression)[[:space:]]' \
        $web_extra/usr/lib/particleos/nginx; then
    fail "nginx config uses directives unavailable in Fedora 44 nginx 1.28"
fi
if rg -n '/var/log/nginx' $web_extra/usr/lib/particleos/nginx $web_extra/usr/lib/systemd/system/nginx.service; then
    fail "nginx logs must use the bounded journal"
fi
require_fixed "kernel.modules_disabled=1"     mkosi.extra/usr/lib/systemd/system/particleos-module-lockdown.service
require_fixed "SELINUX=enforcing" mkosi.extra/etc/selinux/config
require_fixed "Z /var/www/html - - - -" "$web_tmpfiles"
require_fixed "Z /etc/letsencrypt - certbot certbot -" "$web_tmpfiles"
require_fixed "u certbot" "$web_extra/usr/lib/sysusers.d/particleos-webserver.conf"
require_fixed "kernel.io_uring_disabled = 2" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "kernel.unprivileged_bpf_disabled = 2" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "kernel.yama.ptrace_scope = 3" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "vm.memfd_noexec = 1" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "user.max_user_namespaces = 64" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "disable chrony-wait.service"     mkosi.extra/usr/lib/systemd/system-preset/10-particleos.preset
require_fixed "kernel.core_pattern = |/bin/false" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "kernel.oops_limit = 100" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "kernel.warn_limit = 100" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "kernel.printk = 3 3 3 3" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "setsebool -P deny_ptrace=on" mkosi.scripts/particleos.postinst.chroot
require_fixed "handle-unknown=deny" mkosi.scripts/particleos.postinst.chroot
reject_fixed "container_allow_ptrace" mkosi.scripts/particleos.postinst.chroot
reject_fixed "vm.mmap_rnd_compat_bits" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "trap restore_preload EXIT" mkosi.scripts/particleos.postinst.chroot
require_fixed "restore_preload" mkosi.scripts/particleos.postinst.chroot
require_fixed "semodule -X 300 -i" mkosi.scripts/particleos.postinst.chroot
require_fixed "/usr/lib/particleos/selinux/secureblue_harden_userns.cil" mkosi.scripts/particleos.postinst.chroot
require_fixed "(deny userns_restricted_domain self (user_namespace (create))))" \
    mkosi.extra/usr/lib/particleos/selinux/secureblue_harden_userns.cil
require_fixed "(.init_t .kernel_t .systemd_homework_t .systemd_importd_t))" \
    mkosi.extra/usr/lib/particleos/selinux/secureblue_harden_userns.cil
require_fixed "libhardened_malloc.so" mkosi.extra/etc/ld.so.preload
require_fixed "L /etc/ld.so.preload" mkosi.extra/usr/lib/tmpfiles.d/etc.conf
require_fixed 'DefaultEnvironment="LD_PRELOAD=libhardened_malloc.so libno_rlimit_as.so"'     mkosi.extra/usr/lib/systemd/system.conf.d/40-particleos-hardening.conf
require_fixed "DumpCore=no" mkosi.extra/usr/lib/systemd/system.conf.d/40-particleos-hardening.conf
require_fixed "DefaultLimitCORE=0" mkosi.extra/usr/lib/systemd/system.conf.d/40-particleos-hardening.conf
require_fixed "DumpCore=no" mkosi.extra/usr/lib/systemd/user.conf.d/40-particleos-hardening.conf
require_fixed "* hard core 0" mkosi.extra/usr/lib/security/limits.d/60-particleos-no-coredump.conf
require_fixed "Storage=none" mkosi.extra/usr/lib/systemd/coredump.conf.d/40-particleos.conf
require_fixed 'ln -sfn /dev/null "$BUILDROOT/usr/lib/systemd/system/systemd-coredump.socket"' mkosi.scripts/particleos.finalize
require_fixed 'ln -sfn /dev/null "$BUILDROOT/usr/lib/systemd/system/systemd-coredump@.service"' mkosi.scripts/particleos.finalize
for masked_binfmt_unit in \
        systemd-binfmt.service \
        proc-sys-fs-binfmt_misc.automount \
        proc-sys-fs-binfmt_misc.mount; do
    require_fixed "ln -sfn /dev/null \"\$BUILDROOT/usr/lib/systemd/system/$masked_binfmt_unit\"" \
        mkosi.scripts/particleos.finalize
done
reject_fixed "fs.binfmt_misc.status" mkosi.extra/usr/lib/sysctl.d/70-particleos-hardening.conf
require_fixed "disable authselect-apply-changes.service"     mkosi.extra/usr/lib/systemd/system-preset/10-particleos.preset
require_fixed "enable polkit-agent-helper.socket" \
    mkosi.extra/usr/lib/systemd/system-preset/10-particleos.preset
require_fixed 'homectl --help | grep -F "adopt PATH" >/dev/null' mkosi.scripts/particleos.postinst.chroot
require_fixed 'polkit-agent-helper.socket' mkosi.scripts/particleos.postinst.chroot
require_fixed 'polkit-agent-helper@.service' mkosi.scripts/particleos.postinst.chroot
for required_current_systemd_unit in \
        systemd-sysupdate-update.service \
        systemd-sysupdate-update.timer \
        systemd-sysupdate-reboot.service \
        systemd-sysupdate-reboot.timer; do
    require_fixed "$required_current_systemd_unit" mkosi.scripts/particleos.postinst.chroot
done
require_fixed 'HOME_URL="https://github.com/thefutureisprivate/custom-particleos/"' \
    mkosi.scripts/particleos.postinst.chroot
old_repository_url='github.com/thefutureisprivate/'particleos-webserver
if rg -n -F "$old_repository_url" \
        README.md NOTICE docs mkosi.conf mkosi.role.conf mkosi.obs.conf mkosi.role.obs.conf mkosi.resources mkosi.images mkosi.profiles "$postinst" .obs; then
    fail "the old GitHub repository name must not remain in project metadata"
fi

require_fixed 'grep -Fqx "IMAGE_ID=\"$IMAGE_ID\""' mkosi.scripts/particleos.finalize
require_fixed 'find "$image_tree" -xdev -type f -perm /6000 -perm /0111' mkosi.scripts/particleos.finalize
require_fixed '-exec chmod a-s -- {} +' mkosi.scripts/particleos.finalize
require_fixed '-print -quit' mkosi.scripts/particleos.finalize
reject_fixed 'PROFILES' "$postinst"
for role_image_id in "${role_image_ids[@]}"; do
    require_fixed "$role_image_id" "$postinst"
done
require_fixed 'set-ID executable remains after finalization' mkosi.scripts/particleos.finalize

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
reject_fixed "NoNewPrivileges=yes"     mkosi.extra/usr/lib/systemd/system/nftables.service.d/40-particleos-policy.conf
require_fixed "NoNewPrivileges=no" \
    mkosi.extra/usr/lib/systemd/system/chronyd.service.d/40-particleos-hardening.conf
reject_fixed "NoNewPrivileges=yes" \
    mkosi.extra/usr/lib/systemd/system/chronyd.service.d/40-particleos-hardening.conf

for socket_policy in \
        secureblue_socket_utils.cil \
        secureblue_deny_alg_sockets.cil \
        secureblue_deny_ipsec_sockets.cil \
        secureblue_deny_obscure_sockets.cil \
        secureblue_deny_packet_radio_sockets.cil; do
    require_fixed "/usr/lib/particleos/selinux/$socket_policy" mkosi.scripts/particleos.postinst.chroot
    [[ -f "mkosi.extra/usr/lib/particleos/selinux/$socket_policy" ]] ||
        fail "missing SELinux socket policy: $socket_policy"
done
require_fixed "/usr/lib/particleos/selinux/particleos_homed_login.cil" mkosi.scripts/particleos.postinst.chroot
require_fixed ".local_login_t .systemd_userdbd_runtime_t" \
    mkosi.extra/usr/lib/particleos/selinux/particleos_homed_login.cil
require_fixed ".chkpwd_t .systemd_userdbd_runtime_t" \
    mkosi.extra/usr/lib/particleos/selinux/particleos_homed_login.cil
require_fixed "alg_socket" mkosi.extra/usr/lib/particleos/selinux/secureblue_deny_alg_sockets.cil
require_fixed "key_socket" mkosi.extra/usr/lib/particleos/selinux/secureblue_deny_ipsec_sockets.cil
require_fixed "netlink_xfrm_socket" mkosi.extra/usr/lib/particleos/selinux/secureblue_deny_ipsec_sockets.cil

if rg -n '(^|[=:])http://' \
        mkosi.conf mkosi.role.conf mkosi.obs.conf mkosi.role.obs.conf mkosi.resources mkosi.obs.extra mkosi.images mkosi.profiles "${obs_recipes[@]}"; then
    fail "RPM and system-update repository transports must use HTTPS"
fi

if rg -n 'ID=install|system-install.target' mkosi.images/*/emergency-uki.conf; then
    fail "production UKIs must not contain the destructive installer profile"
fi

for transfer in mkosi.obs.extra/usr/lib/sysupdate.d/*.transfer; do
    require_fixed "Path=https://download.opensuse.org/repositories/home:/thefutureisprivate/%o_%w_images/" "$transfer"
done
if rg -n 'repositories/system:/systemd'     mkosi.obs.extra/usr/lib/sysupdate.d; then
    fail "production sysupdate must use home:thefutureisprivate"
fi

if rg -n -i '^[[:space:]]*(gnome|gdm|kde|plasma|sddm|sway|xorg|wayland|firefox)([[:space:]]|$)' \
        mkosi.conf mkosi.role.conf mkosi.images mkosi.profiles "${obs_recipes[@]}"; then
    fail "desktop packages are forbidden"
fi

if rg -n -i '(mkosi\.rootpw|home\.create\.|hashedPassword|password[[:space:]]*[:=][[:space:]]*["'\''"]?particleos)' \
        mkosi.conf mkosi.role.conf mkosi.obs.conf mkosi.role.obs.conf mkosi.credentials mkosi.extra mkosi.obs.extra mkosi.images mkosi.profiles .obs 2>/dev/null; then
    fail "known-password material is forbidden"
fi

if [[ -n "$(find . -path ./.git -prune -o -type f \( -iname '*.key' -o -iname '*.p12' -o -iname '*.pfx' -o -iname 'id_rsa' -o -iname 'id_ed25519' \) -print)" ]]; then
    fail "private-key files are forbidden"
fi

if rg -n '[[:blank:]]+$' --glob '!.git/**' --glob '!AGENTS.md' .; then
    fail "trailing whitespace is forbidden"
fi

for script in mkosi.bump mkosi.scripts/* scripts/*.sh; do
    /usr/bin/bash -n "$script"
done

git diff --check

printf '%s\n' "ParticleOS server image static validation passed."
