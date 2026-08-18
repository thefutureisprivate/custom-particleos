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

if find . \
        \( -path ./.git -o -path ./mkosi.output -o -path ./mkosi.cache -o -path ./mkosi.tools \) -prune \
        -o -type f \( -iname 'Containerfile*' -o -iname 'Dockerfile*' \) -print |
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
    [mailserver]="openssl postgresql-contrib postgresql-server stalwart-particleos-host"
)
base_config=mkosi.images/base/mkosi.conf
initrd_config=mkosi.images/initrd/mkosi.conf
stalwart_common_config=mkosi.images/stalwart-common.conf
stalwart_service_config=mkosi.images/stalwart-service/mkosi.conf
stalwart_service_release=mkosi.images/stalwart-service/mkosi.extra/usr/lib/particleos/stalwart/release
stalwart_built_seed_config=mkosi.images/stalwart-seed/mkosi.conf
stalwart_built_seed_release=mkosi.images/stalwart-seed/mkosi.extra/usr/lib/particleos/stalwart/release
stalwart_seed_release=mkosi.resources/stalwart-seed/release
stalwart_seed_installer=mkosi.scripts/particleos.install-stalwart-seed
role_policy=mkosi.role.conf
obs_config=mkosi.obs.conf
role_obs_config=mkosi.role.obs.conf
service_obs_config=mkosi.service.obs.conf
obs_postoutput=mkosi.scripts/particleos-obs-postoutput
obs_build=mkosi.scripts/particleos-obs-build
obs_recipe=.obs/fedora/x86-64/mkosi.conf
stalwart_obs_recipe=.obs/stalwart-image/x86-64/mkosi.conf
stalwart_seed_obs_recipe=.obs/stalwart-seed/x86-64/mkosi.conf
service_template=.obs/fedora/x86-64/_service.example
stalwart_service_template=.obs/stalwart-image/x86-64/_service.example
stalwart_seed_template=.obs/stalwart-seed/x86-64/_service.example
project_cert_installer=mkosi.scripts/particleos.install-project-cert
postinst=mkosi.scripts/particleos.postinst.chroot
finalize=mkosi.scripts/particleos.finalize
hostname_apply=mkosi.extra/usr/lib/particleos/apply-hostname
hostname_unit=mkosi.extra/usr/lib/systemd/system/particleos-hostname.service
admin_firstboot=mkosi.extra/usr/lib/particleos/admin-firstboot
admin_firstboot_unit=mkosi.extra/usr/lib/systemd/system/particleos-admin-firstboot.service
firstboot_dropin=mkosi.extra/usr/lib/systemd/system/systemd-firstboot.service.d/40-particleos.conf
installer_mount=mkosi.extra/usr/lib/particleos/installer-mount-source-esp
installer_mount_unit=mkosi.extra/usr/lib/systemd/system/particleos-installer-source-esp.service
installer_selinux_label_unit=mkosi.extra/usr/lib/systemd/system/particleos-installer-selinux-label.service
installer_selinux_label_ordering=mkosi.extra/usr/lib/systemd/system/systemd-tmpfiles-setup-dev-early.service.d/40-particleos-installer-selinux.conf
sysinstall_dropin=mkosi.extra/usr/lib/systemd/system/systemd-sysinstall.service.d/40-particleos-source-esp.conf
installer_tmpfiles=mkosi.extra/usr/lib/tmpfiles.d/particleos-installer.conf
homed_config=mkosi.extra/usr/lib/systemd/homed.conf.d/40-particleos.conf
homed_login_policy=mkosi.extra/usr/lib/particleos/selinux/particleos_homed_login.cil
home_repart=mkosi.extra/usr/lib/repart.d/50-home.conf
base_preset=mkosi.extra/usr/lib/systemd/system-preset/10-particleos.preset
obs_recipes=("$obs_recipe" "$stalwart_obs_recipe" "$stalwart_seed_obs_recipe")

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
stalwart_selector=mkosi.conf.d/90-stalwart-image.conf
require_fixed "PathExists=/usr/src/packages/SOURCES/stalwart-image.build" "$stalwart_selector"
require_fixed "Dependencies=" "$stalwart_selector"
require_fixed "Dependencies=stalwart-service" "$stalwart_selector"
stalwart_seed_selector=mkosi.conf.d/91-stalwart-seed.conf
require_fixed "PathExists=/usr/src/packages/SOURCES/stalwart-seed.build" \
    "$stalwart_seed_selector"
require_fixed "Dependencies=" "$stalwart_seed_selector"
require_fixed "Dependencies=stalwart-seed" "$stalwart_seed_selector"

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

[[ -x $installer_mount ]] || fail "$installer_mount must be executable"
require_fixed 'StubDevicePartUUID-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f' "$installer_mount"
require_fixed "tail --bytes=+5" "$installer_mount"
require_fixed "tr -d '\\000'" "$installer_mount"
reject_fixed 'udevadm settle' "$installer_mount"
require_fixed 'systemd-mount' "$installer_mount"
require_fixed '--options=ro,nosuid,nodev,noexec' "$installer_mount"
require_fixed 'readonly source_bootloader=/efi/EFI/systemd/systemd-bootx64.efi' "$installer_mount"
require_fixed 'readonly installed_bootloader=/usr/lib/systemd/boot/efi/systemd-bootx64.efi' "$installer_mount"
require_fixed 'readonly project_certificate=/usr/lib/verity.d/particleos-obs-project.crt' "$installer_mount"
require_fixed 'sbverify --cert "$project_certificate" "$source_bootloader"' "$installer_mount"
require_fixed '--options=bind,ro,nosuid,nodev,noexec' "$installer_mount"
require_fixed 'Requires=particleos-installer-source-esp.service' "$sysinstall_dropin"
require_fixed 'After=particleos-installer-source-esp.service' "$sysinstall_dropin"
require_fixed 'Before=systemd-sysinstall.service' "$installer_mount_unit"
require_fixed 'After=systemd-tmpfiles-setup.service systemd-udev-settle.service' "$installer_mount_unit"
require_fixed 'CapabilityBoundingSet=' "$installer_mount_unit"
require_fixed 'ConditionKernelCommandLine=root=tmpfs' "$installer_selinux_label_unit"
require_fixed 'ConditionSecurity=selinux' "$installer_selinux_label_unit"
require_fixed 'ExecStart=/usr/sbin/restorecon / /bin /lib /lib64 /sbin /etc' "$installer_selinux_label_unit"
reject_fixed 'restorecon[[:space:]]+(-[^[:space:]]*[RF]|--recursive)' "$installer_selinux_label_unit"
for installer_label_before in \
        systemd-modules-load.service \
        systemd-sysusers.service \
        systemd-tmpfiles-setup-dev-early.service \
        systemd-udevd.service \
        systemd-userdbd.service; do
    require_fixed "Before=$installer_label_before" "$installer_selinux_label_unit"
done
require_fixed 'Requires=particleos-installer-selinux-label.service' "$installer_selinux_label_ordering"
require_fixed 'After=particleos-installer-selinux-label.service' "$installer_selinux_label_ordering"
require_fixed 'd /efi 0755 root root -' "$installer_tmpfiles"

for role in "${roles[@]}"; do
    image_config="mkosi.images/$role/mkosi.conf"
    emergency_uki="mkosi.images/$role/emergency-uki.conf"
    installer_uki="mkosi.images/$role/install-uki.conf"
    require_fixed "Include=%D/mkosi.role.conf" "$image_config"
    require_fixed "Dependencies=base,initrd" "$image_config"
    require_fixed "BaseTrees=%O/base" "$image_config"
    require_fixed "CleanPackageMetadata=yes" "$image_config"
    require_fixed "Initrds=%O/initrd" "$image_config"
    require_fixed "ImageId=${role_image_ids[$role]}" "$image_config"
    require_fixed "Hostname=particle-" "$image_config"
    require_fixed "%D/$emergency_uki" "$image_config"
    require_fixed "%D/$installer_uki" "$image_config"
    require_fixed "systemd.image_filter=usr=${role_image_ids[$role]}_*" "$image_config"
    require_fixed "home=${role_image_ids[$role]}-*" "$image_config"
    require_fixed "systemd.image_filter=usr=${role_image_ids[$role]}_*" "$emergency_uki"
    require_fixed "home=${role_image_ids[$role]}-*" "$emergency_uki"
    require_fixed "home=encrypted+absent" "$emergency_uki"
    require_fixed "SignExpectedPcr=no" "$emergency_uki"
    reject_fixed "passwd.plaintext-password.root" "$installer_uki"
    require_fixed "ID=install" "$installer_uki"
    require_fixed "systemd.unit=system-install.target" "$installer_uki"
    require_fixed "systemd.mask=systemd-firstboot.service" "$installer_uki"
    require_fixed "systemd.mask=systemd-boot-random-seed.service" "$installer_uki"
    require_fixed "rd.systemd.mask=systemd-repart.service" "$installer_uki"
    require_fixed "systemd.mount-extra=/usr/share/factory/etc/selinux:/etc/selinux:none:bind,ro,nosuid,nodev,noexec,x-initrd.mount" "$installer_uki"
    require_fixed "systemd.image_policy=esp=unprotected" "$installer_uki"
    require_fixed "systemd.image_filter=usr=${role_image_ids[$role]}_*" "$installer_uki"
done

if [[ -n "$(extract_stanza Packages mkosi.images/dnsserver/mkosi.conf)" ]]; then
    fail "mkosi.images/dnsserver/mkosi.conf must not select packages while the role is dormant"
fi
require_fixed "local Unix-socket-only PostgreSQL instance" mkosi.images/mailserver/mkosi.conf
mail_packages=$(extract_stanza Packages mkosi.images/mailserver/mkosi.conf)
for postgresql_pin in postgresql-contrib-18.* postgresql-server-18.*; do
    grep -Fxq "$postgresql_pin" <<<"$mail_packages" ||
        fail "mailserver package set does not pin $postgresql_pin"
done
for unpinned_postgresql_package in postgresql-contrib postgresql-server; do
    if grep -Fxq "$unpinned_postgresql_package" <<<"$mail_packages"; then
        fail "mailserver package set contains unpinned $unpinned_postgresql_package"
    fi
done
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
require_fixed "PostInstallationScripts=%D/$project_cert_installer" "$role_policy"
require_fixed "FinalizeScripts=%D/$finalize" "$role_policy"
require_fixed "KernelInitrdModules=default,-binfmt_misc" "$role_policy"
require_fixed "PostOutputScripts=%D/mkosi.scripts/remove-first-pass-checksum" "$role_policy"
require_fixed "home=encrypted+absent" "$role_policy"

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
reject_fixed "PostInstallationScripts=%D/$project_cert_installer" "$role_obs_config"
require_fixed "Include=%D/mkosi.role.obs.conf" "$role_policy"
reject_fixed "Include=mkosi-obs" "$role_policy"
test -x "$project_cert_installer" || fail "$project_cert_installer must be executable"
require_fixed '[[ -f $certificate ]] || exit 0' "$project_cert_installer"
require_fixed 'openssl x509 -in "$certificate" -noout' "$project_cert_installer"
require_fixed 'particleos-obs-project.crt' "$project_cert_installer"
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
require_fixed 'image_roothashes=("$obs_sources_dir"/ParticleOS-*.roothash)' "$obs_build"
require_fixed 'image_prefix=${roothash%.roothash}' "$obs_build"
require_fixed 'image_basename=${image_prefix##*/}' "$obs_build"
require_fixed 'materialize_repart_label "${roothash%.roothash}" "$staged_sources_dir"' "$obs_build"
require_fixed 'label="${image_id}_${image_version}_vsig"' "$obs_build"
require_fixed 'if ((${#label} > 36))' "$obs_build"
require_fixed "hashes.cpio.rsasign.sig" "$obs_build"
require_fixed 'rm -- "$staged_repart_tar"' "$obs_build"
reject_fixed 'mv -- "$rewritten_tar" "$repart_tar"' "$obs_build"
for image_metadata_suffix in manifest.gz osrelease repart.tar; do
    require_fixed 'copy_release_metadata "$release_sources_dir/$image_basename.'"$image_metadata_suffix"'"' "$obs_build"
done
require_fixed "No ParticleOS image roothashes were supplied to the signing pass" "$obs_build"

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
xmllint --noout "$stalwart_service_template"
xmllint --noout "$stalwart_seed_template"
xmllint --noout .obs/stalwart-image-meta.example.xml
xmllint --noout .obs/stalwart-image-updates-meta.example.xml
require_fixed "# needssslcertforbuild" "$stalwart_obs_recipe"
require_fixed "Dependencies=stalwart-service" "$stalwart_obs_recipe"
require_fixed "stalwart-particleos-user" "$stalwart_obs_recipe"
require_fixed "stalwart-selinux" "$stalwart_obs_recipe"
require_fixed "# needssslcertforbuild" "$stalwart_seed_obs_recipe"
require_fixed "Dependencies=stalwart-seed" "$stalwart_seed_obs_recipe"
require_fixed "stalwart-particleos-user" "$stalwart_seed_obs_recipe"
require_fixed "stalwart-selinux" "$stalwart_seed_obs_recipe"
require_fixed "https://github.com/thefutureisprivate/custom-particleos.git" \
    "$stalwart_service_template"
require_fixed "REPLACE_WITH_REVIEWED_COMMIT" "$stalwart_service_template"
require_fixed ".obs/stalwart-image/x86-64/mkosi.conf" "$stalwart_service_template"
require_fixed ".obs/stalwart-image/x86-64/stalwart-image.build" \
    "$stalwart_service_template"
require_fixed "https://github.com/thefutureisprivate/custom-particleos.git" \
    "$stalwart_seed_template"
require_fixed "REPLACE_WITH_REVIEWED_COMMIT" "$stalwart_seed_template"
require_fixed ".obs/stalwart-seed/x86-64/mkosi.conf" "$stalwart_seed_template"
require_fixed ".obs/stalwart-seed/x86-64/stalwart-seed.build" \
    "$stalwart_seed_template"
for release_meta in \
        .obs/stalwart-image-meta.example.xml \
        .obs/stalwart-image-updates-meta.example.xml; do
    require_fixed '<disable/>' "$release_meta"
    reject_fixed '<enable ' "$release_meta"
done
require_fixed 'name="stalwart_seed_images" rebuild="local"' \
    .obs/project-meta.example.xml
require_fixed '<service name="download_url">' "$service_template"
require_fixed '<service name="verify_file">' "$service_template"
require_fixed 'protocol">https</param>' "$service_template"
require_fixed 'host">download.opensuse.org</param>' "$service_template"
require_fixed 'stalwart_seed_images/ParticleOS-Stalwart_' "$service_template"
require_fixed 'verifier">sha256</param>' "$service_template"
if grep -Fq 'REPLACE_WITH_OBS_COMPRESSED_SHA256' "$service_template"; then
    fail "$service_template contains an unpinned seed digest"
fi
require_fixed "package: custom-particleos" .obs/workflows.example.yml
reject_fixed "package: custom-particleos-webserver" .obs/workflows.example.yml

require_fixed "Include=%D/mkosi.images/stalwart-common.conf" "$stalwart_service_config"
require_fixed "ImageVersion=0.16.17.26" "$stalwart_service_config"
require_fixed "Output=ParticleOS-Stalwart_%v_%a" "$stalwart_service_config"
require_fixed "Include=%D/mkosi.images/stalwart-common.conf" "$stalwart_built_seed_config"
require_fixed "ImageVersion=0.16.17.25" "$stalwart_built_seed_config"
require_fixed "Output=ParticleOS-Stalwart_%v_%a" "$stalwart_built_seed_config"
require_fixed "ImageId=ParticleOS-Stalwart" "$stalwart_common_config"
require_fixed "Format=disk" "$stalwart_common_config"
require_fixed "Bootable=no" "$stalwart_common_config"
require_fixed "ElTorito=no" "$stalwart_common_config"
require_fixed "SELinuxRelabel=yes" "$stalwart_common_config"
require_fixed "RepartDirectories=%D/mkosi.images/stalwart-service/mkosi.repart" \
    "$stalwart_common_config"
require_fixed "Include=%D/mkosi.service.obs.conf" "$stalwart_common_config"
for service_package in \
        hardened_malloc \
        no_rlimit_as \
        stalwart \
        stalwart-particleos-user \
        stalwart-selinux; do
    require_fixed "$service_package" "$stalwart_common_config"
    require_fixed "$service_package" "$stalwart_obs_recipe"
    require_fixed "$service_package" "$stalwart_seed_obs_recipe"
done
reject_fixed "stalwart-particleos-host" "$stalwart_common_config"
require_fixed "PathExists=/usr/src/packages/SOURCES/_projectcert.crt" "$service_obs_config"
require_fixed "CompressOutput=zstd" "$service_obs_config"
require_fixed "Verity=defer" "$service_obs_config"
require_fixed "PostOutputScripts=%D/$obs_postoutput" "$service_obs_config"
require_fixed "PostOutputScripts=%D/mkosi.scripts/remove-first-pass-checksum" \
    "$stalwart_common_config"
for repart_definition in \
        mkosi.images/stalwart-service/mkosi.repart/10-root-verity-sig.conf \
        mkosi.images/stalwart-service/mkosi.repart/11-root-verity.conf \
        mkosi.images/stalwart-service/mkosi.repart/12-root.conf; do
    test -f "$repart_definition" || fail "$repart_definition is missing"
done
require_fixed "Type=root-verity-sig" \
    mkosi.images/stalwart-service/mkosi.repart/10-root-verity-sig.conf
require_fixed "Type=root-verity" \
    mkosi.images/stalwart-service/mkosi.repart/11-root-verity.conf
require_fixed "Type=root" mkosi.images/stalwart-service/mkosi.repart/12-root.conf
require_fixed "Format=erofs" mkosi.images/stalwart-service/mkosi.repart/12-root.conf
require_fixed "Verity=data" mkosi.images/stalwart-service/mkosi.repart/12-root.conf
require_fixed "VerityMatchKey=root" \
    mkosi.images/stalwart-service/mkosi.repart/10-root-verity-sig.conf
require_fixed "VerityMatchKey=root" \
    mkosi.images/stalwart-service/mkosi.repart/11-root-verity.conf
require_fixed "VerityMatchKey=root" mkosi.images/stalwart-service/mkosi.repart/12-root.conf
for metadata_key in \
        METADATA_VERSION IMAGE_ID IMAGE_VERSION STALWART_VERSION \
        STALWART_PACKAGE_RELEASE WEBUI_VERSION HOST_ABI_MIN HOST_ABI_MAX \
        DATABASE_FORMAT DATABASE_SCHEMA DATABASE_MIGRATION UPDATE_KIND \
        AUTOMATIC_UPDATE ROLLBACK_COMPATIBLE_FROM; do
    require_fixed "$metadata_key=" "$stalwart_service_release"
    require_fixed "$metadata_key=" "$stalwart_built_seed_release"
done
require_fixed "STALWART_PACKAGE_RELEASE=22" "$stalwart_service_release"
require_fixed "IMAGE_VERSION=0.16.17.26" "$stalwart_service_release"
require_fixed "UPDATE_KIND=patch" "$stalwart_service_release"
require_fixed "AUTOMATIC_UPDATE=yes" "$stalwart_service_release"
require_fixed "ROLLBACK_COMPATIBLE_FROM=0.16.17.14:0.16.17.16:0.16.17.20:0.16.17.22:0.16.17.23:0.16.17.25" \
    "$stalwart_service_release"
require_fixed "STALWART_PACKAGE_RELEASE=22" "$stalwart_built_seed_release"
require_fixed "IMAGE_VERSION=0.16.17.25" "$stalwart_built_seed_release"
require_fixed "UPDATE_KIND=seed" "$stalwart_built_seed_release"
require_fixed "AUTOMATIC_UPDATE=no" "$stalwart_built_seed_release"
require_fixed "ROLLBACK_COMPATIBLE_FROM=0.16.17.25" \
    "$stalwart_built_seed_release"
require_fixed "DATABASE_FORMAT=postgresql-18-stalwart" "$stalwart_service_release"
require_fixed "DATABASE_FORMAT=postgresql-18-stalwart" "$stalwart_built_seed_release"
require_fixed 'NAME="ParticleOS Stalwart Service Image"' \
    mkosi.scripts/stalwart-service.postinst.chroot
require_fixed 'ID=particleos-stalwart' mkosi.scripts/stalwart-service.postinst.chroot
require_fixed 'HOME_URL="https://github.com/thefutureisprivate/custom-particleos/"' \
    mkosi.scripts/stalwart-service.postinst.chroot
require_fixed "/usr/lib/stalwart/package-release" \
    mkosi.scripts/stalwart-service.postinst.chroot
require_fixed "STALWART_VERSION|STALWART_PACKAGE_RELEASE" \
    mkosi.scripts/stalwart-service.postinst.chroot
require_fixed "unsafe generic service-image release metadata remains" \
    mkosi.scripts/stalwart-service.finalize
require_fixed 'IMAGE_ID="ParticleOS-Stalwart"' mkosi.scripts/stalwart-service.finalize
require_fixed 'IMAGE_VERSION=\"$IMAGE_VERSION\"' mkosi.scripts/stalwart-service.finalize
require_fixed '! -name cat ! -name cp ! -name stalwart -delete' \
    mkosi.scripts/stalwart-service.finalize
for removed_service_tree in \
        /etc/selinux /usr/lib/systemd /usr/lib/sysusers.d /usr/lib/tmpfiles.d \
        /usr/libexec /usr/sbin /usr/share/selinux /var/lib/selinux; do
    require_fixed "\$BUILDROOT$removed_service_tree" mkosi.scripts/stalwart-service.finalize
done
for seed_key in \
        SEED_METADATA_VERSION IMAGE_VERSION COMPRESSED_FILE \
        COMPRESSED_SHA256 RAW_FILE RAW_SHA256; do
    require_fixed "$seed_key=" "$stalwart_seed_release"
done
require_fixed "PostInstallationScripts=%D/mkosi.scripts/particleos.install-stalwart-seed" \
    mkosi.images/mailserver/mkosi.conf
require_fixed "ExtraTrees=%D/mkosi.resources/stalwart-seed:/usr/lib/particleos/stalwart/seed" \
    mkosi.images/mailserver/mkosi.conf
test -x "$stalwart_seed_installer" || fail "$stalwart_seed_installer must be executable"
require_fixed 'readonly metadata_file=$destination_dir/release' "$stalwart_seed_installer"
require_fixed "readonly sources_dir=/usr/src/packages/SOURCES" "$stalwart_seed_installer"
require_fixed "sha256sum --check --strict" "$stalwart_seed_installer"
require_fixed 'zstd --decompress --force --sparse -o "$temporary"' "$stalwart_seed_installer"
require_fixed 'chmod 0444 "$temporary"' "$stalwart_seed_installer"
if grep -Fq 'REPLACE_WITH_' "$stalwart_seed_release"; then
    fail "$stalwart_seed_release contains an unpinned digest"
fi

if ! diff -u \
        <({
            extract_stanza Packages "$base_config"
            extract_stanza VolatilePackages "$base_config"
            extract_stanza Packages "$initrd_config"
            extract_stanza VolatilePackages "$initrd_config"
            extract_stanza Packages mkosi.images/webserver/mkosi.conf
            extract_stanza Packages mkosi.images/mailserver/mkosi.conf
            extract_stanza BuildPackages mkosi.images/mailserver/mkosi.conf
        } | sed -E \
            -e '/^$/d' \
            -e 's/^(postgresql-(contrib|server))-18\.\*$/\1/' | sort -u) \
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
for required_dependency in authselect btrfs-progs dosfstools findutils gnupg2 libcurl-minimal policycoreutils sbsigntools sed systemd-container; do
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
require_fixed "mount.usrflags=ro,nodev" "$role_policy"
reject_fixed "mount.usrflags=ro,nosuid" "$role_policy"
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
require_fixed "Type=home" "$home_repart"
require_fixed "Format=btrfs" "$home_repart"
require_fixed "SizeMinBytes=1G" "$home_repart"
require_fixed "SizeMaxBytes=4G" "$home_repart"
require_fixed "Encrypt=tpm2" "$home_repart"
require_fixed "TPM2PCRs=7" "$home_repart"
require_fixed "FactoryReset=yes" "$home_repart"
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
xmllint --noout .obs/project-meta.example.xml
require_fixed "project: home:thefutureisprivate" .obs/workflows.example.yml
require_fixed '<path project="Fedora:44" repository="update"/>' .obs/project-meta.example.xml
require_fixed '<path project="system:systemd" repository="Fedora_44"/>' .obs/project-meta.example.xml
require_fixed '<repository name="particleos_base_Fedora_44">' .obs/project-meta.example.xml
require_fixed '<repository name="stalwart_images">' .obs/project-meta.example.xml
for image_repository in fedora_44_images stalwart_images stalwart_seed_images; do
    require_fixed "%_repository\" == \"$image_repository" .obs/project-config.example
done
if [[ $(grep -c '^Type: mkosi$' .obs/project-config.example) -ne 3 ]]; then
    fail ".obs/project-config.example must select mkosi for all image repositories"
fi
require_fixed "Repotype: checksumsfile:rawsig staticlinks" .obs/project-config.example
require_fixed '<path project="home:thefutureisprivate" repository="particleos_base_Fedora_44"/>' \
    .obs/project-meta.example.xml
require_fixed '<path project="home:thefutureisprivate" repository="stalwart_Fedora_44"/>' \
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
require_fixed "includepkgs=stalwart,stalwart-particleos-host,stalwart-particleos-user,stalwart-selinux" \
    mkosi.resources/particleos-obs.repo
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
for moved_package_config in \
        .obs/hardened_malloc-meta.example.xml \
        .obs/ipe-policy-meta.example.xml \
        .obs/no_rlimit_as-meta.example.xml; do
    [[ ! -e $moved_package_config ]] ||
        fail "$moved_package_config belongs in its dedicated package repository"
done
printf '%s  %s\n' \
    5fe4715ba5d0fb9abf18915ea38213c45240fe828a7aa52c574634a13484814c \
    mkosi.resources/particleos-obs-pubkey.gpg | sha256sum --check --status - ||
    fail "the pinned ParticleOS OBS public key changed"

if rg -n 'amd-ucode-firmware|microcode_ctl' mkosi.conf mkosi.role.conf mkosi.images mkosi.profiles "${obs_recipes[@]}"; then
    fail "guest microcode packages are forbidden for the VPS image"
fi

[[ -x $admin_firstboot ]] || fail "$admin_firstboot must be executable"
require_fixed '[[ -t 0 && -t 1 ]]' "$admin_firstboot"
require_fixed '^[a-z][a-z0-9_-]{0,30}$' "$admin_firstboot"
require_fixed "^ssh-ed25519" "$admin_firstboot"
require_fixed 'base64 --decode' "$admin_firstboot"
require_fixed '0000000b7373682d6564323535313900000020' "$admin_firstboot"
require_fixed 'homectl create "$username"' "$admin_firstboot"
require_fixed "--member-of=wheel,systemd-journal" "$admin_firstboot"
require_fixed "--storage=luks" "$admin_firstboot"
require_fixed "--fs-type=btrfs" "$admin_firstboot"
require_fixed "--disk-size=90%" "$admin_firstboot"
require_fixed "--auto-resize-mode=off" "$admin_firstboot"
require_fixed "--luks-discard=yes" "$admin_firstboot"
require_fixed "--nosuid=yes" "$admin_firstboot"
require_fixed "--nodev=yes" "$admin_firstboot"
require_fixed "--enforce-password-policy=yes" "$admin_firstboot"
require_fixed '--ssh-authorized-keys=@"$key_file"' "$admin_firstboot"
require_fixed 'userdbctl ssh-authorized-keys "$account"' "$admin_firstboot"
require_fixed '[[ -e /home/"$account".home ]]' "$admin_firstboot"
require_fixed 'homectl list --no-legend --no-pager' "$admin_firstboot"
require_fixed 'mv --force --no-target-directory' "$admin_firstboot"
reject_fixed '| chpasswd' "$admin_firstboot"
reject_fixed 'useradd ' "$admin_firstboot"
reject_fixed 'authorized_keys' "$admin_firstboot"
require_fixed "ConditionPathExists=!/var/lib/particleos/admin-provisioned" "$admin_firstboot_unit"
reject_fixed "ConditionFirstBoot=yes" "$admin_firstboot_unit"
require_fixed "Requires=systemd-firstboot.service systemd-homed.service" "$admin_firstboot_unit"
require_fixed "After=home.mount" "$admin_firstboot_unit"
require_fixed "systemd-firstboot.service" "$admin_firstboot_unit"
require_fixed "Before=getty-pre.target sshd.socket systemd-user-sessions.service multi-user.target" \
    "$admin_firstboot_unit"
require_fixed "StandardInput=tty-force" "$admin_firstboot_unit"
require_fixed "TTYPath=/dev/console" "$admin_firstboot_unit"
require_fixed "TimeoutStartSec=infinity" "$admin_firstboot_unit"
require_fixed "CapabilityBoundingSet=" "$admin_firstboot_unit"
require_fixed "IPAddressDeny=any" "$admin_firstboot_unit"
require_fixed "NoNewPrivileges=yes" "$admin_firstboot_unit"
reject_fixed "PrivateDevices=" "$admin_firstboot_unit"
require_fixed "PrivateNetwork=yes" "$admin_firstboot_unit"
require_fixed "ProtectHome=read-only" "$admin_firstboot_unit"
require_fixed "ProtectSystem=strict" "$admin_firstboot_unit"
require_fixed "ReadWritePaths=/run /var/lib/particleos" "$admin_firstboot_unit"
require_fixed "RestrictAddressFamilies=AF_UNIX" "$admin_firstboot_unit"
require_fixed "RestrictNamespaces=yes" "$admin_firstboot_unit"
require_fixed "SystemCallFilter=@system-service" "$admin_firstboot_unit"
require_fixed "WantedBy=multi-user.target" "$admin_firstboot_unit"
require_fixed "enable particleos-admin-firstboot.service" "$base_preset"
require_fixed "enable systemd-homed.service" "$base_preset"
require_fixed "disable systemd-homed-firstboot.service" "$base_preset"
require_fixed "authselect select local" mkosi.scripts/particleos.postinst.chroot
require_fixed "authselect enable-feature with-systemd-homed" mkosi.scripts/particleos.postinst.chroot
require_fixed "pam_systemd_home\\.so" mkosi.scripts/particleos.postinst.chroot
require_fixed "pam_unix\\.so/i auth" mkosi.scripts/particleos.postinst.chroot
require_fixed "pam_systemd_loadkey\\.so/d" mkosi.scripts/particleos.postinst.chroot
require_fixed "20-systemd-userdb.conf.example" \
    mkosi.scripts/particleos.postinst.chroot
require_fixed "usermod --password '!unprovisioned' root" \
    mkosi.scripts/particleos.postinst.chroot
require_fixed "/usr/bin/systemd-home-fallback-shell" \
    mkosi.scripts/particleos.postinst.chroot
require_fixed "/usr/lib/particleos/selinux/particleos_homed_login.cil" \
    mkosi.scripts/particleos.postinst.chroot
for retained_homed_path in \
        /usr/bin/homectl \
        /usr/lib64/security/pam_systemd_home.so \
        /usr/lib/systemd/system/systemd-homed-firstboot.service \
        /usr/lib/systemd/system/systemd-homed.service \
        /usr/lib/systemd/systemd-homed \
        /usr/lib/systemd/systemd-homework \
        /usr/lib/systemd/sshd_config.d/20-systemd-userdb.conf \
        /usr/share/dbus-1/system-services/org.freedesktop.home1.service \
        /usr/share/polkit-1/actions/org.freedesktop.home1.policy; do
    reject_fixed "$retained_homed_path" "$role_policy"
done
require_fixed "/usr/lib64/security/pam_systemd_loadkey.so" "$role_policy"
require_fixed "DefaultStorage=luks" "$homed_config"
require_fixed "DefaultFileSystemType=btrfs" "$homed_config"
require_fixed ".sshd_session_t .systemd_userdbd_runtime_t" "$homed_login_policy"
require_fixed ".policykit_auth_t .systemd_homed_t" "$homed_login_policy"
require_fixed "ExecStart=/usr/bin/systemd-firstboot --prompt-root-password --mute-console=yes" \
    "$firstboot_dropin"
reject_fixed "--prompt-locale" "$firstboot_dropin"
require_fixed "ln -sfn ../particleos-admin-firstboot.service" "$finalize"
require_fixed '    "$BUILDROOT/usr/lib/systemd/system/multi-user.target.wants/particleos-admin-firstboot.service"' \
    "$finalize"
reject_fixed "homed_wants=" "$finalize"
require_fixed "PermitRootLogin no"     mkosi.extra/etc/ssh/sshd_config.d/40-particleos-hardening.conf
require_fixed "PasswordAuthentication no"     mkosi.extra/etc/ssh/sshd_config.d/40-particleos-hardening.conf
require_fixed "AuthenticationMethods publickey"     mkosi.extra/etc/ssh/sshd_config.d/40-particleos-hardening.conf
require_fixed "KbdInteractiveAuthentication no"     mkosi.extra/etc/ssh/sshd_config.d/40-particleos-hardening.conf
require_fixed "PubkeyAuthentication yes"     mkosi.extra/etc/ssh/sshd_config.d/40-particleos-hardening.conf
require_fixed "HostKey /etc/ssh/ssh_host_ed25519_key"     mkosi.extra/etc/ssh/sshd_config.d/40-particleos-hardening.conf
require_fixed "PermitListen none"     mkosi.extra/etc/ssh/sshd_config.d/40-particleos-hardening.conf
require_fixed "PermitOpen none"     mkosi.extra/etc/ssh/sshd_config.d/40-particleos-hardening.conf
sshd_template_dropin=mkosi.extra/usr/lib/systemd/system/sshd@.service.d/40-particleos-hardening.conf
require_fixed "Requires=nftables.service particleos-module-lockdown.service" "$sshd_template_dropin"
require_fixed "NoNewPrivileges=no" "$sshd_template_dropin"
reject_fixed "NoNewPrivileges=yes" "$sshd_template_dropin"
require_fixed "CapabilityBoundingSet=" "$sshd_template_dropin"
require_fixed "ProtectSystem=strict" "$sshd_template_dropin"
require_fixed "ReadWritePaths=/run /var/lib/lastlog /var/log" "$sshd_template_dropin"
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
postgres_major_file="$mail_extra/usr/lib/particleos/postgresql/major-version"
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
stalwart_image_manager="$mail_extra/usr/lib/particleos/stalwart/image-manager"
stalwart_host_abi="$mail_extra/usr/lib/particleos/stalwart/host-abi"
stalwart_image_setup_unit="$mail_extra/usr/lib/systemd/system/particleos-stalwart-image-setup.service"
stalwart_update_unit="$mail_extra/usr/lib/systemd/system/particleos-stalwart-update.service"
stalwart_update_timer="$mail_extra/usr/lib/systemd/system/particleos-stalwart-update.timer"
stalwart_activate_unit="$mail_extra/usr/lib/systemd/system/particleos-stalwart-image-activate@.service"
stalwart_rollback_unit="$mail_extra/usr/lib/systemd/system/particleos-stalwart-image-rollback.service"
stalwart_sysupdate="$mail_extra/usr/lib/sysupdate.stalwart.d/50-stalwart.transfer"
stalwart_image_tmpfiles="$mail_extra/usr/lib/tmpfiles.d/particleos-stalwart-images.conf"
stalwart_image_readme="$mail_extra/usr/share/doc/particleos/stalwart/IMAGE-UPDATES.md"
stalwart_pull_policy="$mail_extra/usr/lib/particleos/selinux/particleos_stalwart_pull.cil"
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
require_fixed "meta nfproto ipv4 tcp dport 22 ct state new meter ssh4" "$base_firewall"
require_fixed "meta nfproto ipv6 tcp dport 22 ct state new meter ssh6" "$base_firewall"
require_fixed "tcp dport 22 ct state new accept" "$base_firewall"
reject_fixed "@ssh_ipv4" "$base_firewall"
reject_fixed "@ssh_ipv6" "$base_firewall"
reject_fixed "ssh-allowlist.nft" "$base_firewall"
if [[ -e mkosi.extra/usr/lib/particleos/ssh-allowlist.nft ]]; then
    fail "the obsolete SSH source allowlist must not be shipped"
fi
reject_fixed "ssh-allowlist.nft" mkosi.extra/usr/lib/tmpfiles.d/etc.conf
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
require_fixed "enable particleos-stalwart-image-setup.service" "$mail_preset"
require_fixed "enable stalwart.service" "$mail_preset"
require_fixed "enable particleos-mailserver-health.service" "$mail_preset"
require_fixed "enable particleos-stalwart-update.timer" "$mail_preset"
reject_fixed "network-online.target" "$mail_health_unit"
require_fixed "Requires=nftables.service particleos-module-lockdown.service postgresql.service particleos-stalwart-database.service systemd-resolved.service" "$mail_dropin"
require_fixed "After=nftables.service particleos-module-lockdown.service postgresql.service particleos-stalwart-database.service systemd-resolved.service" "$mail_dropin"
require_fixed "StartLimitIntervalSec=5min" "$mail_dropin"
require_fixed "InaccessiblePaths=/sys/fs/cgroup" "$mail_dropin"
require_fixed "Environment=STALWART_RECOVERY_MODE=1" "$mail_dropin"
require_fixed "Environment=PARTICLEOS_AUTO_RECOVERY_MODE=1" "$mail_dropin"
require_fixed "Environment=PARTICLEOS_RUNTIME_MODE_FILE=/run/stalwart/particleos-mode" "$mail_dropin"
require_fixed "SystemCallFilter=~@privileged @resources" "$mail_dropin"
require_fixed "PostgreSQL" "$mail_readme"
require_fixed "localhost:8080" "$mail_readme"
require_fixed "127.0.0.54:53" "$mail_readme"
require_fixed "There is no database password or environment file." "$mail_readme"
require_fixed "systemd-resolved" "$mail_readme"
reject_fixed "STALWART_DB_PASSWORD" "$mail_readme"
require_fixed "executable, allocator libraries, and WebUI run from the signed, release-pinned" \
    "$mail_readme"
require_fixed "/var/lib/particleos/stalwart/current.raw" "$mail_readme"
reject_fixed "WebUI is a checksum-pinned RPM payload in immutable /usr" "$mail_readme"
require_fixed "Requires=particleos-postgresql-setup.service" "$postgres_dropin"
[[ $(<"$postgres_major_file") == 18 ]] ||
    fail "$postgres_major_file must pin PostgreSQL major 18"
require_fixed "postgresql-contrib-18.*" mkosi.images/mailserver/mkosi.conf
require_fixed "postgresql-server-18.*" mkosi.images/mailserver/mkosi.conf
require_fixed "postgresql-contrib" "$obs_recipe"
require_fixed "postgresql-server" "$obs_recipe"
require_fixed "expected_postgresql_major" "$postinst"
require_fixed "/usr/bin/pg_waldump" "$postinst"
require_fixed "unsupported PostgreSQL binary version" "$postinst"
require_fixed "RestrictAddressFamilies=AF_UNIX" "$postgres_dropin"
require_fixed "IPAddressDeny=any" "$postgres_dropin"
require_fixed "MemoryDenyWriteExecute=yes" "$postgres_dropin"
require_fixed "SystemCallFilter=@chown" "$postgres_dropin"
require_fixed "User=postgres" "$postgres_setup_unit"
reject_fixed "ConditionPathExists=!/var/lib/pgsql/data/.particleos-initialized" "$postgres_setup_unit"
require_fixed "for postgresql_entrypoint in" mkosi.scripts/particleos.postinst.chroot
require_fixed "postgresql_exec_t:s0" mkosi.scripts/particleos.postinst.chroot
require_fixed "/usr/bin/initdb" "$postgres_setup"
require_fixed 'read -r expected_major </usr/lib/particleos/postgresql/major-version' \
    "$postgres_setup"
require_fixed 'data_major != "$expected_major"' "$postgres_setup"
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
require_fixed "/usr/bin/chown postgres:postgres" "$postgres_prepare_recovery"
require_fixed '"$staging/conf.d/particleos-recovery.conf"' "$postgres_prepare_recovery"
require_fixed '"$staging/recovery.signal"' "$postgres_prepare_recovery"
require_fixed "RequiresMountsFor=/var/lib/pgsql/backup" "$postgres_pitr_unit"
require_fixed "ExecStart=/usr/lib/particleos/postgresql/enable-pitr" "$postgres_pitr_unit"
require_fixed "ExecStart=/usr/lib/particleos/postgresql/basebackup" "$postgres_pitr_unit"
require_fixed "ExecStart=/usr/lib/particleos/postgresql/basebackup" "$postgres_basebackup_unit"
require_fixed "OnCalendar=weekly" "$postgres_basebackup_timer"
require_fixed "d /var/lib/pgsql/backup 0700 postgres postgres -" "$postgres_tmpfiles"
require_fixed "postgresql-contrib-18.*" mkosi.images/mailserver/mkosi.conf
require_fixed "postgresql-contrib" "$obs_recipe"
require_fixed "zstd" "$obs_recipe"
require_fixed "zstd" mkosi.images/mailserver/mkosi.conf
require_fixed "never removes backups or WAL" "$postgres_backup_readme"
require_fixed "data.pre-pitr" "$postgres_backup_readme"
require_fixed "Requires=postgresql.service" "$stalwart_db_unit"
require_fixed "User=postgres" "$stalwart_db_unit"
require_fixed "CREATE ROLE stalwart LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE" "$stalwart_db_setup"
require_fixed "REVOKE ALL ON DATABASE stalwart FROM PUBLIC" "$stalwart_db_setup"
reject_fixed "PASSWORD" "$stalwart_db_setup"
require_fixed "/usr/share/selinux/packages/particleos_stalwart.pp" mkosi.scripts/particleos.postinst.chroot
require_fixed "/usr/lib/particleos/selinux/particleos_stalwart_pull.cil" \
    mkosi.scripts/particleos.postinst.chroot
require_fixed ".stalwart_image_manager_t .systemd_importd_exec_t" \
    "$stalwart_pull_policy"
require_fixed "(file (getattr open map read execute ioctl))" "$stalwart_pull_policy"
require_fixed ".stalwart_image_manager_t .systemd_importd_t" \
    "$stalwart_pull_policy"
require_fixed "(process (transition))" "$stalwart_pull_policy"
require_fixed "(typetransition .stalwart_image_manager_t .systemd_importd_exec_t" \
    "$stalwart_pull_policy"
require_fixed "(process2 (nnp_transition nosuid_transition))" \
    "$stalwart_pull_policy"
require_fixed "(type particleos_stalwart_managed_unit_t)" "$stalwart_pull_policy"
require_fixed ".systemd_unit_file_type" "$stalwart_pull_policy"
require_fixed ".systemd_importd_t .stalwart_image_manager_t" \
    "$stalwart_pull_policy"
require_fixed "(fifo_file (getattr write))" "$stalwart_pull_policy"
require_fixed "(unix_dgram_socket (sendto))" "$stalwart_pull_policy"
require_fixed ".system_dbusd_t .stalwart_image_manager_t" \
    "$stalwart_pull_policy"
require_fixed ".stalwart_image_manager_t .stalwart_image_staging_t" \
    "$stalwart_pull_policy"
require_fixed "(file (setattr))" "$stalwart_pull_policy"
require_fixed "(dontaudit .init_t .stalwart_image_staging_t (file (write)))" \
    "$stalwart_pull_policy"
require_fixed ".stalwart_image_manager_t .particleos_stalwart_managed_unit_t" \
    "$stalwart_pull_policy"
require_fixed "(service (start status))" "$stalwart_pull_policy"
if rg -n '(\.stalwart_image_manager_t.*tcp_socket|tcp_socket.*\.stalwart_image_manager_t)' \
        "$stalwart_pull_policy"; then
    fail "the Stalwart image-manager domain must not receive direct TCP access"
fi
if rg -n 'STALWART_DB_PASSWORD|authSecret.*EnvironmentVariable' "$mail_extra"; then
    fail "mailserver must not carry a database secret in the environment"
fi

test -x "$stalwart_image_manager" || fail "$stalwart_image_manager must be executable"
require_fixed "HOST_ABI_CURRENT=1" "$stalwart_host_abi"
require_fixed "HOST_ABI_ROLLBACK=1" "$stalwart_host_abi"
require_fixed 'RootImagePolicy=$image_policy' "$stalwart_image_manager"
require_fixed "systemd-run --quiet --wait --pipe --collect" "$stalwart_image_manager"
require_fixed "systemd-sysupdate --component=stalwart --json=short check-new" \
    "$stalwart_image_manager"
require_fixed "systemd-sysupdate --component=stalwart update" "$stalwart_image_manager"
require_fixed "systemd-sysupdate --component=stalwart vacuum 9>&-" \
    "$stalwart_image_manager"
[[ $(grep -Fc -- '9>&-' "$stalwart_image_manager") == 3 ]] ||
    fail "$stalwart_image_manager must close the manager lock fd for every sysupdate child"
require_fixed 'for image in "${staged_images[@]}"; do' "$stalwart_image_manager"
require_fixed 'candidate_version=$image_version' "$stalwart_image_manager"
reject_fixed 'done < <(' "$stalwart_image_manager"
require_fixed "'{\"available\":null}'" "$stalwart_image_manager"
require_fixed "availability_status == 0 || availability_status == 1" \
    "$stalwart_image_manager"
require_fixed "readonly staging_dir=" "$stalwart_image_manager"
require_fixed "import_staged_image" "$stalwart_image_manager"
require_fixed "discarded invalid staged image" "$stalwart_image_manager"
require_fixed 'inspect_image "$destination" release' "$stalwart_image_manager"
require_fixed "managed service image has the wrong SELinux label" \
    "$stalwart_image_manager"
require_fixed "temporary image did not inherit the protected SELinux label" \
    "$stalwart_image_manager"
reject_fixed "chown root:root" "$stalwart_image_manager"
reject_fixed "restorecon" "$stalwart_image_manager"
require_fixed '((${#staged_images[@]} > 0)) || return 0' "$stalwart_image_manager"
require_fixed '[[ -n $candidate ]] || return 0' "$stalwart_image_manager"
require_fixed '== "${blocked##*/}" ]] && return 0' "$stalwart_image_manager"
require_fixed "resolve_optional_link" "$stalwart_image_manager"
reject_fixed "resolve_link current.raw 2>/dev/null || true" "$stalwart_image_manager"
require_fixed "minor/major Stalwart updates require a database-aware migration path" \
    "$stalwart_image_manager"
require_fixed "only explicitly compatible patch images may activate automatically" \
    "$stalwart_image_manager"
require_fixed "candidate downgrades the Stalwart runtime" "$stalwart_image_manager"
require_fixed "candidate downgrades the Stalwart package release" "$stalwart_image_manager"
require_fixed "candidate downgrades the packaged WebUI" "$stalwart_image_manager"
require_fixed "ROLLBACK_COMPATIBLE_FROM" "$stalwart_image_manager"
require_fixed "atomic_link previous.raw" "$stalwart_image_manager"
require_fixed "atomic_link current.raw" "$stalwart_image_manager"
require_fixed "particleos-mailserver-health.service" "$stalwart_image_manager"
require_fixed "blocked.raw" "$stalwart_image_manager"
require_fixed 'atomic_link blocked.raw "$(relative_target "$current")"' \
    "$stalwart_image_manager"
require_fixed "ExecStart=/usr/lib/particleos/stalwart/image-manager initialize" \
    "$stalwart_image_setup_unit"
require_fixed "RequiresMountsFor=/var/lib/particleos/stalwart" \
    "$stalwart_image_setup_unit"
require_fixed "CapabilityBoundingSet=" "$stalwart_image_setup_unit"
require_fixed "ExecStart=/usr/lib/particleos/stalwart/image-manager update" \
    "$stalwart_update_unit"
require_fixed "NFTSet=cgroup:inet:particleos_filter:sysupdate_cgroups" \
    "$stalwart_update_unit"
require_fixed "labelled systemd-pull child transitions" "$stalwart_update_unit"
require_fixed "CapabilityBoundingSet=" "$stalwart_update_unit"
require_fixed "DevicePolicy=closed" "$stalwart_update_unit"
require_fixed "NoNewPrivileges=yes" "$stalwart_update_unit"
reject_fixed "NoNewPrivileges=no" "$stalwart_update_unit"
require_fixed "RestrictNamespaces=yes" "$stalwart_update_unit"
require_fixed "ExecStart=/usr/lib/particleos/stalwart/image-manager activate %I" \
    "$stalwart_activate_unit"
require_fixed "ExecStart=/usr/lib/particleos/stalwart/image-manager rollback" \
    "$stalwart_rollback_unit"
for stalwart_control_unit in "$stalwart_activate_unit" "$stalwart_rollback_unit"; do
    require_fixed "CapabilityBoundingSet=" "$stalwart_control_unit"
    require_fixed "DevicePolicy=closed" "$stalwart_control_unit"
    require_fixed "IPAddressDeny=any" "$stalwart_control_unit"
    require_fixed "NoNewPrivileges=yes" "$stalwart_control_unit"
    require_fixed "PrivateNetwork=yes" "$stalwart_control_unit"
    require_fixed "PrivateTmp=yes" "$stalwart_control_unit"
    require_fixed "ProtectSystem=strict" "$stalwart_control_unit"
    require_fixed "ReadWritePaths=/var/lib/particleos/stalwart" "$stalwart_control_unit"
    require_fixed "RestrictAddressFamilies=AF_UNIX" "$stalwart_control_unit"
    require_fixed "RestrictNamespaces=yes" "$stalwart_control_unit"
done
reject_fixed "run0 /usr/lib/particleos/stalwart/image-manager" \
    "$stalwart_image_readme"
require_fixed "OnCalendar=daily" "$stalwart_update_timer"
require_fixed "Type=url-file" "$stalwart_sysupdate"
require_fixed "Verify=yes" "$stalwart_sysupdate"
require_fixed "Path=https://download.opensuse.org/repositories/home:/thefutureisprivate/stalwart_images/" \
    "$stalwart_sysupdate"
require_fixed "Type=regular-file" "$stalwart_sysupdate"
require_fixed "Path=/var/lib/particleos/stalwart/staging" "$stalwart_sysupdate"
require_fixed "MatchPattern=ParticleOS-Stalwart_@v_%a.raw.zst" "$stalwart_sysupdate"
require_fixed "MatchPattern=ParticleOS-Stalwart_@v_%a.raw" "$stalwart_sysupdate"
reject_fixed "@a" "$stalwart_sysupdate"
require_fixed "ReadOnly=yes" "$stalwart_sysupdate"
require_fixed "InstancesMax=2" "$stalwart_sysupdate"
reject_fixed "CurrentSymlink=" "$stalwart_sysupdate"
require_fixed "d /var/lib/particleos/stalwart/images 0700 root root -" \
    "$stalwart_image_tmpfiles"
require_fixed "d /var/lib/particleos/stalwart/staging 0700 root root -" \
    "$stalwart_image_tmpfiles"
require_fixed "OS A/B updates and rollbacks never" "$stalwart_image_readme"
require_fixed "stalwart_image_manager_t" "$stalwart_image_readme"
require_fixed 'transitions into Fedora'"'"'s confined `systemd_importd_t` domain' \
    "$stalwart_image_readme"
require_fixed "sysupdate's installed" "$stalwart_image_readme"
require_fixed "only the separately labelled" "$stalwart_image_readme"
require_fixed "root password, twice" README.md
require_fixed "administrator password, twice" README.md
require_fixed "raw Ed25519 SSH public key" README.md
require_fixed "systemd-home-fallback-shell" README.md
require_fixed "PasswordAuthentication" README.md
require_fixed "systemd-home-fallback-shell" docs/SECURITY-MODEL.md
require_fixed "This second prompt is not SSH password authentication" docs/SECURITY-MODEL.md
require_fixed '/usr/lib/systemd/import-pubring\.pgp -- system_u:object_r:systemd_conf_t:s0' \
    mkosi.scripts/particleos.postinst.chroot
require_fixed 'particleos_stalwart_managed_unit_t:s0' \
    mkosi.scripts/particleos.postinst.chroot
require_fixed 'printf '\''%s\n'\'' "$particleos_hostname" >/etc/hostname' \
    mkosi.scripts/particleos.postinst.chroot
require_fixed "C /etc/hostname 0644 root root - /usr/share/factory/etc/hostname" \
    mkosi.extra/usr/lib/tmpfiles.d/etc.conf
require_fixed 'exec /usr/bin/hostnamectl --static --transient hostname "$configured_hostname"' \
    "$hostname_apply"
require_fixed "Wants=network-pre.target" "$hostname_unit"
require_fixed "After=local-fs.target" "$hostname_unit"
reject_fixed "Wants=systemd-hostnamed.service" "$hostname_unit"
reject_fixed "After=local-fs.target systemd-hostnamed.service" "$hostname_unit"
require_fixed "Before=network-pre.target" "$hostname_unit"
require_fixed "CapabilityBoundingSet=" "$hostname_unit"
require_fixed "NoNewPrivileges=yes" "$hostname_unit"
require_fixed "ProtectHostname=yes" "$hostname_unit"
require_fixed "RestrictAddressFamilies=AF_UNIX" "$hostname_unit"
require_fixed "enable particleos-hostname.service" "$base_preset"
require_fixed "UPDATE_KIND=patch" "$stalwart_image_readme"
require_fixed "database-aware migration" "$stalwart_image_readme"
require_fixed "meta skuid systemd-resolve ip daddr { 1.1.1.1, 1.0.0.1 } tcp dport 853 accept" "$base_firewall"
require_fixed "meta skuid systemd-resolve ip6 daddr { 2606:4700:4700::1111, 2606:4700:4700::1001 } tcp dport 853 accept" "$base_firewall"
require_fixed "meta skuid chrony tcp dport 4460 accept" "$base_firewall"
require_fixed "socket cgroupv2 level 2 @sysupdate_cgroups tcp dport 443 ct state new limit rate 16/second burst 32 packets accept"     mkosi.extra/usr/lib/particleos/nftables.conf
require_fixed "NFTSet=cgroup:inet:particleos_filter:sysupdate_cgroups"     mkosi.extra/usr/lib/systemd/system/systemd-sysupdate-update.service.d/40-particleos-egress.conf
require_fixed "enable systemd-sysupdate-update.timer"     mkosi.extra/usr/lib/systemd/system-preset/10-particleos.preset
network_wait_dropin=mkosi.extra/usr/lib/systemd/system/systemd-networkd-wait-online.service.d/40-particleos-nonblocking.conf
require_fixed "disable systemd-networkd-wait-online.service" "$base_preset"
reject_fixed "enable systemd-networkd-wait-online.service" "$base_preset"
require_fixed "ConditionPathExists=/run/particleos-require-network-online" "$network_wait_dropin"
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
require_fixed "Before=multi-user.target systemd-boot-check-no-failures.service boot-complete.target" "$mail_health_unit"
reject_fixed "FailureAction=" "$mail_health_unit"
reject_fixed "ConditionPathExists=/sys/firmware/efi/efivars/LoaderBootCountPath" "$mail_health_unit"
require_fixed "RequiredBy=multi-user.target boot-complete.target" "$mail_health_unit"
require_fixed "User=stalwart" "$mail_health_unit"
require_fixed "IPAddressAllow=localhost" "$mail_health_unit"
require_fixed "IPAddressDeny=any" "$mail_health_unit"
require_fixed "--host=/run/postgresql --username=stalwart --dbname=stalwart" "$mail_health_check"
require_fixed "/usr/lib/particleos/postgresql/major-version" "$mail_health_check"
require_fixed "server_version_num" "$mail_health_check"
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
require_fixed "/run/stalwart/webui-admin.sha256" "$mail_health_check"
require_fixed "/run/stalwart/webui-account.sha256" "$mail_health_check"
require_fixed "/run/stalwart/particleos-mode" "$mail_health_check"
require_fixed 'exec 3<>"/dev/tcp/$address/$port" || return 1' "$mail_health_check"
require_fixed "for address in 127.0.0.1 ::1" "$mail_health_check"
require_fixed "for port in 110 143 587 995 4190" "$mail_health_check"
mail_health_policy="$mail_extra/usr/lib/particleos/selinux/particleos_mail_health.cil"
require_fixed "/usr/lib/particleos/selinux/particleos_mail_health.cil" \
    mkosi.scripts/particleos.postinst.chroot
for mail_health_port_type in \
    smtp_port_t \
    cyrus_imapd_port_t \
    pop_port_t \
    http_port_t \
    http_cache_port_t \
    sieve_port_t; do
    require_fixed ".init_t .$mail_health_port_type (tcp_socket (name_connect))" \
        "$mail_health_policy"
done
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
require_fixed 'homectl --help' mkosi.scripts/particleos.postinst.chroot
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
require_fixed 'readonly pam_shadow_helper="$BUILDROOT/usr/bin/unix_chkpwd"' mkosi.scripts/particleos.finalize
require_fixed 'chmod 4755 "$pam_shadow_helper"' mkosi.scripts/particleos.finalize
require_fixed '((${#remaining_setid[@]} != 1))' mkosi.scripts/particleos.finalize
reject_fixed 'PROFILES' "$postinst"
for role_image_id in "${role_image_ids[@]}"; do
    require_fixed "$role_image_id" "$postinst"
done
require_fixed 'unexpected set-ID executable after finalization' mkosi.scripts/particleos.finalize

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
nosuid_transition_policy=mkosi.extra/usr/lib/particleos/selinux/particleos_nosuid_daemon_transitions.cil
require_fixed ".init_t .udev_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
require_fixed ".init_t .setfiles_t (process2 (nosuid_transition))" "$nosuid_transition_policy"
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
require_fixed ".systemd_homed_t .systemd_homework_t (process2 (nosuid_transition))" \
    "$nosuid_transition_policy"
reject_fixed ".init_t .useradd_t" "$nosuid_transition_policy"
reject_fixed ".init_t .passwd_t" "$nosuid_transition_policy"
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
require_fixed ".systemd_homed_t .udev_var_run_t (lnk_file (read))" \
    "$runtime_symlink_policy"
require_fixed "selinux_factory_link_context='/etc/selinux -l system_u:object_r:etc_t:s0'" \
    mkosi.scripts/particleos.postinst.chroot
pcr_measurement_policy=mkosi.extra/usr/lib/particleos/selinux/particleos_pcr_measurement.cil
require_fixed "/usr/lib/particleos/selinux/particleos_pcr_measurement.cil" \
    mkosi.scripts/particleos.postinst.chroot
require_fixed ".systemd_pcrextend_t .udev_var_run_t (file (getattr open read))" \
    "$pcr_measurement_policy"
require_fixed ".init_t .loop_control_device_t (chr_file (getattr ioctl lock open read write))" \
    "$pcr_measurement_policy"
require_fixed ".init_t .systemd_pcrextend_t (unix_stream_socket (connectto))" \
    "$pcr_measurement_policy"
require_fixed ".systemd_pcrextend_t .init_var_run_t (dir (read))" \
    "$pcr_measurement_policy"
require_fixed "d /run/systemd/nvpcr 0755 root root -" \
    mkosi.extra/usr/lib/tmpfiles.d/particleos-pcr-measurement.conf
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

if [[ -n "$(find . \
        \( -path ./.git -o -path ./mkosi.output -o -path ./mkosi.cache -o -path ./mkosi.tools \) -prune \
        -o -type f \( -iname '*.key' -o -iname '*.p12' -o -iname '*.pfx' -o -iname 'id_rsa' -o -iname 'id_ed25519' \) -print)" ]]; then
    fail "private-key files are forbidden"
fi

if rg -n '[[:blank:]]+$' \
        --glob '!.git/**' \
        --glob '!mkosi.output/**' \
        --glob '!mkosi.cache/**' \
        --glob '!mkosi.tools/**' \
        --glob '!AGENTS.md' .; then
    fail "trailing whitespace is forbidden"
fi

for script in mkosi.bump mkosi.scripts/* scripts/*.sh; do
    /usr/bin/bash -n "$script"
done

git diff --check

printf '%s\n' "ParticleOS server image static validation passed."
