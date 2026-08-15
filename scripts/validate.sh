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
built_roles=(webserver mailserver)
declare -A role_image_ids=(
    [webserver]=ParticleOS-Webserver
    [mailserver]=ParticleOS-Mailserver
    [dnsserver]=ParticleOS-Dnsserver
)
declare -A role_packages=(
    [webserver]="certbot nginx-core"
    [mailserver]="openssl postgresql-contrib postgresql-server stalwart"
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

require_fixed "Dependencies=webserver,mailserver" mkosi.conf
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

if [[ -n "$(extract_stanza Packages mkosi.images/dnsserver/mkosi.conf)" ]]; then
    fail "mkosi.images/dnsserver/mkosi.conf must not select packages while the role is dormant"
fi
require_fixed "local Unix-socket-only PostgreSQL instance" mkosi.images/mailserver/mkosi.conf
require_fixed "Empty placeholder" mkosi.images/dnsserver/mkosi.conf
if rg -n '^[[:space:]]*(dovecot|dovecot-pigeonhole|postfix|postfix-pcre|dnsdist|unbound)[[:space:]]*$' \
        mkosi.conf mkosi.role.conf mkosi.images mkosi.profiles .obs/fedora/x86-64; then
    fail "unselected alternative mail and DNS daemon packages must not be selected"
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
require_fixed 'obs_sources_dir=/usr/src/packages/SOURCES' "$obs_build"
require_fixed 'release_sources_dir=$obs_sources_dir' "$obs_build"
require_fixed 'source_entries=("$obs_sources_dir"/*)' "$obs_build"
require_fixed 'ln -s -- "$source" "$staged_sources_dir/${source##*/}"' "$obs_build"
require_fixed "s#^cp -r /usr/src/packages/SOURCES/#cp -rL /usr/src/packages/SOURCES/#" "$obs_build"
require_fixed 's#/usr/src/packages/SOURCES#$staged_sources_dir#g' "$obs_build"
require_fixed 'grep -qF "cp -rL $staged_sources_dir/"' "$obs_build"
require_fixed 'release_sources_dir=$staged_sources_dir' "$obs_build"
require_fixed 'copy_release_metadata "$release_sources_dir/base.manifest.gz"' "$obs_build"
require_fixed 'role_roothashes=("$obs_sources_dir"/ParticleOS-*.roothash)' "$obs_build"
require_fixed 'role_prefix=${roothash%.roothash}' "$obs_build"
require_fixed 'role_basename=${role_prefix##*/}' "$obs_build"
require_fixed 'materialize_repart_label "${roothash%.roothash}" "$staged_sources_dir"' "$obs_build"
require_fixed 'label="${image_id}_${image_version}_vsig"' "$obs_build"
require_fixed 'if ((${#label} > 36))' "$obs_build"
require_fixed "hashes.cpio.rsasign.sig" "$obs_build"
require_fixed 'rm -- "$staged_repart_tar"' "$obs_build"
reject_fixed 'mv -- "$rewritten_tar" "$repart_tar"' "$obs_build"
for role_metadata_suffix in manifest.gz osrelease repart.tar; do
    require_fixed 'copy_release_metadata "$release_sources_dir/$role_basename.'"$role_metadata_suffix"'"' "$obs_build"
done
require_fixed "No ParticleOS role roothashes were supplied to the signing pass" "$obs_build"

for verity_sig_repart in \
        mkosi.repart/10-usr-verity-sig.conf \
        mkosi.extra/usr/lib/repart.d/10-usr-verity-sig.conf; do
    require_fixed "Label=%M_%A_vsig" "$verity_sig_repart"
    reject_fixed "Label=%M_%A_verity_sig" "$verity_sig_repart"
done
for verity_sig_transfer in \
        mkosi.sysupdate/10-usr-verity-sig.transfer \
        mkosi.obs.extra/usr/lib/sysupdate.d/20-particleos-verity-sig.transfer; do
    require_fixed "MatchPattern=%M_@v_vsig" "$verity_sig_transfer"
    require_fixed "MatchPattern=%M_@v_verity_sig" "$verity_sig_transfer"
done

require_fixed "# needssslcertforbuild" "$obs_recipe"
require_fixed "Dependencies=webserver,mailserver" "$obs_recipe"
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
            extract_stanza Packages mkosi.images/mailserver/mkosi.conf
        } | sed '/^$/d' | sort -u) \
        <(extract_stanza BuildPackages "$obs_recipe" | sort -u); then
    fail "$obs_recipe BuildPackages= does not equal the selected graph package closure"
fi

for built_role in "${built_roles[@]}"; do
    for required_role_package in ${role_packages[$built_role]}; do
        require_fixed "$required_role_package" "mkosi.images/$built_role/mkosi.conf"
        require_fixed "$required_role_package" "$obs_recipe"
    done
done
for recipe in "$base_config" mkosi.images/webserver/mkosi.conf mkosi.images/mailserver/mkosi.conf "$obs_recipe"; do
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

host_udev_service_dropin=mkosi.extra/usr/lib/systemd/system/systemd-udevd.service.d/40-particleos-selinux.conf
require_fixed "ExecStart=" "$host_udev_service_dropin"
require_fixed "ExecStart=@/usr/bin/udevadm systemd-udevd" "$host_udev_service_dropin"
reject_fixed "SELinuxContext=" "$host_udev_service_dropin"

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
xmllint --noout .obs/hardened_malloc-meta.example.xml
xmllint --noout .obs/no_rlimit_as-meta.example.xml
require_fixed "project: home:thefutureisprivate" .obs/workflows.example.yml
require_fixed '<path project="Fedora:44" repository="update"/>' .obs/project-meta.example.xml
require_fixed '<path project="system:systemd" repository="Fedora_44"/>' .obs/project-meta.example.xml
require_fixed '<repository name="particleos_base_Fedora_44">' .obs/project-meta.example.xml
require_fixed '<path project="home:thefutureisprivate" repository="particleos_base_Fedora_44"/>' \
    .obs/project-meta.example.xml
require_fixed '<path project="home:thefutureisprivate" repository="Fedora_44"/>' \
    .obs/project-meta.example.xml
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
require_fixed "includepkgs=stalwart" mkosi.resources/particleos-obs.repo
require_fixed "skip_if_unavailable=False" mkosi.resources/particleos-obs.repo
require_fixed "repo_gpgcheck=1" mkosi.resources/particleos-obs.repo
require_fixed "baseurl=https://download.opensuse.org/repositories/home:/thefutureisprivate/particleos_base_Fedora_44/" \
    mkosi.resources/particleos-base-obs.repo
require_fixed "priority=1" mkosi.resources/particleos-base-obs.repo
require_fixed "includepkgs=hardened_malloc,ipe-policy,no_rlimit_as" \
    mkosi.resources/particleos-base-obs.repo
require_fixed "skip_if_unavailable=False" mkosi.resources/particleos-base-obs.repo
require_fixed "repo_gpgcheck=1" mkosi.resources/particleos-base-obs.repo
require_fixed "mkosi.resources/particleos-base-obs.repo:/etc/yum.repos.d/particleos-base-obs.repo" \
    mkosi.conf.d/particleos-obs-repo.conf
require_fixed "mkosi.resources/particleos-obs.repo:/etc/yum.repos.d/particleos-obs.repo" \
    mkosi.conf.d/particleos-obs-repo.conf
if find mkosi.images -path '*/mkosi.conf.d/*' -type f -print | grep -q .; then
    fail "role images cannot configure top-level SandboxTrees repository mounts"
fi
require_fixed "excludepkgs=ipe-policy" mkosi.profiles/obs-repos/mkosi.conf.d/fedora/mkosi.conf.d/44.repo
for base_package_meta in \
        .obs/hardened_malloc-meta.example.xml \
        .obs/ipe-policy-meta.example.xml \
        .obs/no_rlimit_as-meta.example.xml; do
    require_fixed '<enable repository="particleos_base_Fedora_44" arch="x86_64"/>' \
        "$base_package_meta"
    if rg -n '<enable repository="Fedora_44"' "$base_package_meta"; then
        fail "$base_package_meta must not rebuild ParticleOS base packages in the Stalwart repository"
    fi
done
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
mail_extra=mkosi.images/mailserver/mkosi.extra
mail_firewall="$mail_extra/usr/lib/particleos/nftables-role.nft"
mail_preset="$mail_extra/usr/lib/systemd/system-preset/20-particleos-mailserver.preset"
mail_dropin="$mail_extra/usr/lib/systemd/system/stalwart.service.d/40-particleos-hardening.conf"
mail_readme="$mail_extra/usr/share/doc/particleos/stalwart/README"
postgres_dropin="$mail_extra/usr/lib/systemd/system/postgresql.service.d/40-particleos-hardening.conf"
postgres_setup_unit="$mail_extra/usr/lib/systemd/system/particleos-postgresql-setup.service"
postgres_setup="$mail_extra/usr/lib/particleos/postgresql/initialize"
postgres_conf="$mail_extra/usr/lib/particleos/postgresql/particleos.conf"
postgres_hba="$mail_extra/usr/lib/particleos/postgresql/pg_hba.conf"
postgres_archive="$mail_extra/usr/lib/particleos/postgresql/archive-wal"
postgres_restore="$mail_extra/usr/lib/particleos/postgresql/restore-wal"
postgres_enable_pitr="$mail_extra/usr/lib/particleos/postgresql/enable-pitr"
postgres_basebackup="$mail_extra/usr/lib/particleos/postgresql/basebackup"
postgres_prepare_recovery="$mail_extra/usr/lib/particleos/postgresql/prepare-recovery"
postgres_pitr_unit="$mail_extra/usr/lib/systemd/system/particleos-postgresql-pitr-enable.service"
postgres_basebackup_unit="$mail_extra/usr/lib/systemd/system/particleos-postgresql-basebackup.service"
postgres_basebackup_timer="$mail_extra/usr/lib/systemd/system/particleos-postgresql-basebackup.timer"
postgres_tmpfiles="$mail_extra/usr/lib/tmpfiles.d/particleos-postgresql.conf"
postgres_backup_readme="$mail_extra/usr/share/doc/particleos/stalwart/BACKUP-RECOVERY.md"
stalwart_db_unit="$mail_extra/usr/lib/systemd/system/particleos-stalwart-database.service"
stalwart_db_setup="$mail_extra/usr/lib/particleos/postgresql/provision-stalwart"
mail_health_unit="$mail_extra/usr/lib/systemd/system/particleos-mailserver-health.service"
mail_health_check="$mail_extra/usr/lib/particleos/health/mailserver"
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
require_fixed "tcp dport { 25, 443, 465, 993 } ct state new accept" "$mail_firewall"
reject_fixed "995" "$mail_firewall"
reject_fixed "4190" "$mail_firewall"
require_fixed "add @mail_tcp_conn4 { ip saddr ct count over 64 }" "$mail_firewall"
require_fixed "ct count over 2048" "$mail_firewall"
require_fixed "meter mail_tcp4" "$mail_firewall"
require_fixed "meta skuid stalwart tcp dport 25 ct state new limit rate 64/second burst 128 packets accept" "$mail_firewall"
require_fixed "meta skuid stalwart tcp dport 443 ct state new limit rate 8/second burst 16 packets accept" "$mail_firewall"
reject_fixed "dport 8080" "$mail_firewall"
reject_fixed "dport { 110, 143, 587" "$mail_firewall"
require_fixed "enable postgresql.service" "$mail_preset"
require_fixed "enable particleos-stalwart-database.service" "$mail_preset"
require_fixed "enable stalwart.service" "$mail_preset"
require_fixed "enable particleos-mailserver-health.service" "$mail_preset"
require_fixed "Requires=nftables.service particleos-module-lockdown.service postgresql.service particleos-stalwart-database.service systemd-resolved.service" "$mail_dropin"
require_fixed "After=nftables.service particleos-module-lockdown.service postgresql.service particleos-stalwart-database.service systemd-resolved.service" "$mail_dropin"
require_fixed "StartLimitIntervalSec=5min" "$mail_dropin"
require_fixed "InaccessiblePaths=/sys/fs/cgroup" "$mail_dropin"
require_fixed "Environment=STALWART_RECOVERY_MODE=1" "$mail_dropin"
require_fixed "Environment=PARTICLEOS_AUTO_RECOVERY_MODE=1" "$mail_dropin"
require_fixed "Environment=PARTICLEOS_RUNTIME_MODE_FILE=/run/stalwart/particleos-mode" "$mail_dropin"
require_fixed "PostgreSQL" "$mail_readme"
require_fixed "localhost:8080" "$mail_readme"
require_fixed "127.0.0.54:53" "$mail_readme"
require_fixed "There is no database password or environment file." "$mail_readme"
require_fixed "systemd-resolved" "$mail_readme"
reject_fixed "STALWART_DB_PASSWORD" "$mail_readme"
require_fixed "Requires=particleos-postgresql-setup.service" "$postgres_dropin"
require_fixed "RestrictAddressFamilies=AF_UNIX" "$postgres_dropin"
require_fixed "IPAddressDeny=any" "$postgres_dropin"
require_fixed "MemoryDenyWriteExecute=yes" "$postgres_dropin"
require_fixed "SystemCallFilter=@chown" "$postgres_dropin"
require_fixed "User=postgres" "$postgres_setup_unit"
reject_fixed "ConditionPathExists=!/var/lib/pgsql/data/.particleos-initialized" "$postgres_setup_unit"
require_fixed "for postgresql_entrypoint in" mkosi.scripts/particleos.postinst.chroot
require_fixed "postgresql_exec_t:s0" mkosi.scripts/particleos.postinst.chroot
require_fixed "/usr/bin/initdb" "$postgres_setup"
require_fixed "--data-checksums" "$postgres_setup"
require_fixed "--auth-local=peer" "$postgres_setup"
require_fixed "--auth-host=reject" "$postgres_setup"
reject_fixed "/usr/bin/postgresql-setup" "$postgres_setup"
reject_fixed "install -" "$postgres_setup"
require_fixed "include_dir = 'conf.d'" "$postgres_setup"
require_fixed "listen_addresses = ''" "$postgres_conf"
require_fixed "unix_socket_directories = '/run/postgresql'" "$postgres_conf"
require_fixed "unix_socket_group = 'stalwart'" "$postgres_conf"
require_fixed "unix_socket_permissions = 0770" "$postgres_conf"
require_fixed "logging_collector = off" "$postgres_conf"
require_fixed "log_destination = 'stderr'" "$postgres_conf"
require_fixed "wal_level = 'replica'" "$postgres_conf"
require_fixed "archive_mode = on" "$postgres_conf"
require_fixed "archive_command = '/usr/lib/particleos/postgresql/archive-wal" "$postgres_conf"
require_fixed "SupplementaryGroups=stalwart" "$postgres_dropin"
require_fixed "Environment=SYSTEMD_BYPASS_USERDB=1" "$postgres_dropin"
require_fixed "local   all       postgres       peer" "$postgres_hba"
require_fixed "local   replication postgres     peer" "$postgres_hba"
require_fixed "local   stalwart  stalwart       peer" "$postgres_hba"
require_fixed "local   all       all            reject" "$postgres_hba"
reject_fixed "local   all       all            peer" "$postgres_hba"
reject_fixed "host " "$postgres_hba"
for postgresql_script in \
    "$postgres_archive" \
    "$postgres_restore" \
    "$postgres_enable_pitr" \
    "$postgres_basebackup" \
    "$postgres_prepare_recovery"; do
    test -x "$postgresql_script" || fail "$postgresql_script must be executable"
done
require_fixed '[[ -e $enabled_marker ]] || exit 0' "$postgres_archive"
require_fixed 'mountpoint --quiet "$backup_root"' "$postgres_archive"
require_fixed 'cmp --silent -- "$source_path" "$destination"' "$postgres_archive"
require_fixed 'pg_switch_wal()' "$postgres_basebackup"
require_fixed "/usr/bin/pg_basebackup" "$postgres_basebackup"
require_fixed "/usr/bin/pg_verifybackup" "$postgres_basebackup"
require_fixed "RequiresMountsFor=/var/lib/pgsql/backup" "$postgres_pitr_unit"
require_fixed "ExecStart=/usr/lib/particleos/postgresql/enable-pitr" "$postgres_pitr_unit"
require_fixed "ExecStart=/usr/lib/particleos/postgresql/basebackup" "$postgres_pitr_unit"
require_fixed "ExecStart=/usr/lib/particleos/postgresql/basebackup" "$postgres_basebackup_unit"
require_fixed "OnCalendar=weekly" "$postgres_basebackup_timer"
require_fixed "d /var/lib/pgsql/backup 0700 postgres postgres -" "$postgres_tmpfiles"
require_fixed "postgresql-contrib" mkosi.images/mailserver/mkosi.conf
require_fixed "postgresql-contrib" "$obs_recipe"
require_fixed "never removes backups or WAL" "$postgres_backup_readme"
require_fixed "data.pre-pitr" "$postgres_backup_readme"
require_fixed "Requires=postgresql.service" "$stalwart_db_unit"
require_fixed "User=postgres" "$stalwart_db_unit"
require_fixed "CREATE ROLE stalwart LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE" "$stalwart_db_setup"
require_fixed "REVOKE ALL ON DATABASE stalwart FROM PUBLIC" "$stalwart_db_setup"
reject_fixed "PASSWORD" "$stalwart_db_setup"
require_fixed "/usr/share/selinux/packages/particleos_stalwart.pp" mkosi.scripts/particleos.postinst.chroot
if rg -n 'STALWART_DB_PASSWORD|authSecret.*EnvironmentVariable' "$mail_extra"; then
    fail "mailserver must not carry a database secret in the environment"
fi
require_fixed "meta skuid systemd-resolve ip daddr { 1.1.1.1, 1.0.0.1 } tcp dport 853 accept" "$base_firewall"
require_fixed "meta skuid systemd-resolve ip6 daddr { 2606:4700:4700::1111, 2606:4700:4700::1001 } tcp dport 853 accept" "$base_firewall"
require_fixed "meta skuid chrony tcp dport 4460 accept" "$base_firewall"
require_fixed "socket cgroupv2 level 2 @sysupdate_cgroups tcp dport 443 ct state new limit rate 16/second burst 32 packets accept"     mkosi.extra/usr/lib/particleos/nftables.conf
require_fixed "NFTSet=cgroup:inet:particleos_filter:sysupdate_cgroups"     mkosi.extra/usr/lib/systemd/system/systemd-sysupdate-update.service.d/40-particleos-egress.conf
require_fixed "enable systemd-sysupdate-update.timer"     mkosi.extra/usr/lib/systemd/system-preset/10-particleos.preset
base_preset=mkosi.extra/usr/lib/systemd/system-preset/10-particleos.preset
rollback_dropin=mkosi.extra/usr/lib/systemd/system/systemd-boot-check-no-failures.service.d/40-particleos-rollback.conf
bless_rollback_dropin=mkosi.extra/usr/lib/systemd/system/systemd-bless-boot.service.d/40-particleos-rollback.conf
web_health_unit="$web_extra/usr/lib/systemd/system/particleos-webserver-health.service"
web_health_check="$web_extra/usr/lib/particleos/health/webserver"

require_fixed "enable systemd-sysupdate-reboot.timer" "$base_preset"
require_fixed "enable systemd-boot-check-no-failures.service" "$base_preset"
require_fixed "FailureAction=reboot" "$rollback_dropin"
require_fixed "ConditionPathExists=/sys/firmware/efi/efivars/LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f" "$rollback_dropin"
require_fixed "FailureAction=reboot" "$bless_rollback_dropin"
require_fixed "ConditionPathExists=/sys/firmware/efi/efivars/LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f" \
    "$bless_rollback_dropin"
require_fixed "Requires=nginx.service" "$web_health_unit"
require_fixed "Before=boot-complete.target" "$web_health_unit"
require_fixed "FailureAction=reboot" "$web_health_unit"
require_fixed "ConditionPathExists=/sys/firmware/efi/efivars/LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f" "$web_health_unit"
require_fixed "RequiredBy=boot-complete.target" "$web_health_unit"
require_fixed "CapabilityBoundingSet=" "$web_health_unit"
require_fixed "IPAddressAllow=localhost" "$web_health_unit"
require_fixed "IPAddressDeny=any" "$web_health_unit"
require_fixed "enable particleos-webserver-health.service" "$web_preset"
reject_fixed "nginx -e stderr -t -q" "$web_health_check"
require_fixed "/dev/tcp/127.0.0.1/80" "$web_health_check"
require_fixed "HTTP/*" "$web_health_check"
web_health_policy="$web_extra/usr/lib/particleos/selinux/particleos_web_health.cil"
require_fixed "/usr/lib/particleos/selinux/particleos_web_health.cil" \
    mkosi.scripts/particleos.postinst.chroot
require_fixed 'if [[ $IMAGE_ID == ParticleOS-Webserver ]]' \
    mkosi.scripts/particleos.postinst.chroot
require_fixed ".init_t .http_port_t (tcp_socket (name_connect))" \
    "$web_health_policy"
require_fixed "Requires=systemd-resolved.service postgresql.service particleos-stalwart-database.service stalwart.service" "$mail_health_unit"
require_fixed "Before=boot-complete.target" "$mail_health_unit"
require_fixed "FailureAction=reboot" "$mail_health_unit"
require_fixed "ConditionPathExists=/sys/firmware/efi/efivars/LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f" "$mail_health_unit"
require_fixed "RequiredBy=boot-complete.target" "$mail_health_unit"
require_fixed "User=stalwart" "$mail_health_unit"
require_fixed "IPAddressAllow=localhost" "$mail_health_unit"
require_fixed "IPAddressDeny=any" "$mail_health_unit"
require_fixed "--host=/run/postgresql --username=stalwart --dbname=stalwart" "$mail_health_check"
reject_fixed "query cloudflare.com" "$mail_health_check"
require_fixed "query localhost" "$mail_health_check"
require_fixed "readonly LISTENER_ABSENT=10" "$mail_health_check"
require_fixed "readonly TLS_FAILURE=20" "$mail_health_check"
require_fixed "readonly CERTIFICATE_FAILURE=30" "$mail_health_check"
require_fixed "readonly PROTOCOL_FAILURE=40" "$mail_health_check"
require_fixed "readonly DATASTORE_FAILURE=50" "$mail_health_check"
require_fixed "readonly WEBUI_MISMATCH=60" "$mail_health_check"
require_fixed "/usr/bin/openssl s_client" "$mail_health_check"
require_fixed "/usr/bin/openssl x509" "$mail_health_check"
require_fixed "EHLO health.particleos.invalid" "$mail_health_check"
require_fixed "a1 CAPABILITY" "$mail_health_check"
require_fixed "/usr/share/stalwart/webui-admin.sha256" "$mail_health_check"
require_fixed "/usr/share/stalwart/webui-account.sha256" "$mail_health_check"
require_fixed "/run/stalwart/particleos-mode" "$mail_health_check"
require_fixed 'exec 3<>"/dev/tcp/$address/$port" || return 1' "$mail_health_check"
require_fixed "for address in 127.0.0.1 ::1" "$mail_health_check"
require_fixed "for port in 110 143 587 995 4190" "$mail_health_check"
require_fixed 'oifname "lo" accept' "$base_firewall"

closed_firewall=mkosi.images/dnsserver/mkosi.extra/usr/lib/particleos/nftables-role.nft
require_fixed "all role ingress and egress remains closed." "$closed_firewall"
reject_fixed " accept" "$closed_firewall"
if grep -Fq 'meta l4proto { tcp, udp } accept' "$base_firewall" "$web_firewall" "$mail_firewall"; then
    fail "raw prerouting must not admit every TCP and UDP tuple"
fi
if grep -Eq 'meta skuid.*nginx' "$base_firewall" "$web_firewall" "$mail_firewall"; then
    fail "nginx must not be authorized to create new outbound connections"
fi
if grep -Eq 'meta skuid[[:space:]]+root' "$base_firewall" "$web_firewall" "$mail_firewall"; then
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
require_fixed "worker_rlimit_nofile 32768;" \
    $web_extra/usr/lib/particleos/nginx/nginx.conf
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
modules_load=mkosi.extra/usr/lib/modules-load.d/particleos.conf
for module in nft_connlimit nft_socket vfat; do
    grep -Fxq "$module" "$modules_load" ||
        fail "$module must be preloaded before module lockdown"
done
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
require_fixed "/usr/lib/particleos/selinux/particleos_nosuid_daemon_transitions.cil" \
    mkosi.scripts/particleos.postinst.chroot
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
nosuid_transition_policy=mkosi.extra/usr/lib/particleos/selinux/particleos_nosuid_daemon_transitions.cil
require_fixed ".init_t .udev_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".init_t .system_dbusd_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".init_t .ldconfig_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".init_t .iptables_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".init_t .sshd_keygen_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".init_t .chronyd_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".init_t .postgresql_t (process2 (nnp_transition nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".init_t .bootloader_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".udev_t .systemd_sysctl_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".udev_t .lvm_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".sshd_keygen_t .ssh_keygen_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".sshd_keygen_t .setfiles_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".systemd_homed_t .systemd_homework_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".getty_t .local_login_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".init_t .unconfined_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".local_login_t .unconfined_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".sshd_t .sshd_session_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".sshd_session_t .sshd_auth_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".sshd_session_t .unconfined_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".unconfined_t .chronyc_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".policykit_auth_t .chkpwd_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".init_t .chkpwd_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
if [[ $(rg -c "nnp_transition" "$nosuid_transition_policy") -ne 1 ]]; then
    fail "only the PostgreSQL daemon transition may receive nnp_transition in the shared policy"
fi
runtime_symlink_policy=mkosi.extra/usr/lib/particleos/selinux/particleos_runtime_symlinks.cil
require_fixed "/usr/lib/particleos/selinux/particleos_runtime_symlinks.cil" \
    mkosi.scripts/particleos.postinst.chroot
require_fixed ".init_t .udev_var_run_t (lnk_file (create))" "$runtime_symlink_policy"
require_fixed ".systemd_homed_t .udev_var_run_t (lnk_file (read))" "$runtime_symlink_policy"
require_fixed "selinux_factory_link_context='/etc/selinux -l system_u:object_r:etc_t:s0'" \
    mkosi.scripts/particleos.postinst.chroot
require_fixed ".local_login_t .systemd_userdbd_runtime_t" \
    mkosi.extra/usr/lib/particleos/selinux/particleos_homed_login.cil
require_fixed ".chkpwd_t .systemd_userdbd_runtime_t" \
    mkosi.extra/usr/lib/particleos/selinux/particleos_homed_login.cil
require_fixed ".policykit_t .systemd_userdbd_runtime_t" \
    mkosi.extra/usr/lib/particleos/selinux/particleos_homed_login.cil
require_fixed ".policykit_auth_t .systemd_userdbd_runtime_t" \
    mkosi.extra/usr/lib/particleos/selinux/particleos_homed_login.cil
require_fixed ".sshd_session_t .systemd_userdbd_runtime_t" \
    mkosi.extra/usr/lib/particleos/selinux/particleos_homed_login.cil
require_fixed ".policykit_auth_t .systemd_homed_t (dbus (send_msg))" \
    mkosi.extra/usr/lib/particleos/selinux/particleos_homed_login.cil
require_fixed ".systemd_homed_t .policykit_auth_t (dbus (send_msg))" \
    mkosi.extra/usr/lib/particleos/selinux/particleos_homed_login.cil
require_fixed ".policykit_auth_t .systemd_homed_runtime_pipe_t (fifo_file (write))" \
    mkosi.extra/usr/lib/particleos/selinux/particleos_homed_login.cil
pcr_measurement_policy=mkosi.extra/usr/lib/particleos/selinux/particleos_pcr_measurement.cil
require_fixed "/usr/lib/particleos/selinux/particleos_pcr_measurement.cil" \
    mkosi.scripts/particleos.postinst.chroot
require_fixed ".systemd_pcrextend_t .udev_var_run_t (file (getattr open read))" \
    "$pcr_measurement_policy"
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
