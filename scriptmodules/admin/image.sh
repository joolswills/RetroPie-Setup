#!/usr/bin/env bash

# This file is part of The RetroPie Project
#
# The RetroPie Project is the legal property of its developers, whose names are
# too numerous to list here. Please refer to the COPYRIGHT.md file distributed with this source.
#
# See the LICENSE.md file at the top-level directory of this distribution and
# at https://raw.githubusercontent.com/RetroPie/RetroPie-Setup/master/LICENSE.md
#

rp_module_id="image"
rp_module_desc="Create/Manage RetroPie images"
rp_module_section=""
rp_module_flags=""

function depends_image() {
    local depends=(kpartx unzip binfmt-support rsync parted squashfs-tools dosfstools e2fsprogs xz-utils)
    isPlatform "x86" && depends+=(qemu-user-binfmt)
    getDepends "${depends[@]}"

    # enable C flag in qemu-aarch64/qemu-arm binfmt_misc override to allow suid binaries in emulated chroot
    if isPlatform "x86"; then
        local platform
        for platform in arm aarch64; do
            local config="qemu-$platform.conf"
            local src_config="/usr/lib/binfmt.d/$config"
            local dest_config="/etc/binfmt.d/$config"
            if [[ ! -f "$dest_config" ]]; then
                printMsgs "console" "Adding C flag to $src_config (overriding in $dest_config)"
                sed "s/$/C/" "/usr/lib/binfmt.d/$config" >"/etc/binfmt.d/$config"
            fi
        done
        systemctl restart systemd-binfmt
    fi
}

function _get_info_image() {
    local dist="$1"
    local key="$2"
    # don't use $md_data so this function can be used directly from builder.sh
    local ini="${__mod_info[image/path]%/*}/image/dists/${dist}.ini"

    # if the file is found try and extract the value else echo an empty string
    if [[ -f "$ini" ]]; then
        iniConfig "=" "\"" "$ini"
        iniGet "$key"
        echo "$ini_value"
    else
        echo ""
    fi
}

function create_chroot_image() {
    local dist="$1"
    [[ -z "$dist" ]] && return 1

    local chroot="$2"
    [[ -z "$chroot" ]] && chroot="$md_build/$dist"

    mkdir -p "$md_build"
    pushd "$md_build"

    mkdir -p "$chroot"

    local url=$(_get_info_image "$dist" "url")
    [[ -z "$url" ]] && fatalError "Unable to get url information for $dist"

    local format=$(_get_info_image "$dist" "format")
    [[ -z "$format" ]] && fatalError "Unable to get format information for $dist"

    local base="raspbian-${dist}-lite"
    local image="${dist}.img"
    local dest="${image}.${format}"
    if [[ ! -f "$image" ]]; then
        case "$format" in
            zip)
                download "$url" "$dest"
                unzip -o "$dest"
                mv "$(unzip -Z -1 "$dest")" "$image"
                rm "$dest"
                ;;
            xz)
                download "$url" "$dest"
                xz -d -v "$dest"
                ;;
        esac
    fi

    # abort if there is no extracted image present
    [[ ! -f "$image" ]] && return 1

    # mount image
    local partitions=($(kpartx -s -a -v "$image" | awk '{ print "/dev/mapper/"$3 }'))
    local part_boot="${partitions[0]}"
    local part_root="${partitions[1]}"

    # get temporary directory
    local tmp="$(mktemp -d -p "$md_build")"

    # mount root partition
    mount "$part_root" "$tmp"

    # get the mount location of the boot partition from etc/fstab
    local boot_path="$(_get_boot_path_image "$tmp")"

    # create the boot partition mountpoint and mount
    mkdir -p "$tmp$boot_path"
    mount "$part_boot" "$tmp$boot_path"

    printMsgs "console" "Creating chroot from $image ..."
    rsync -aAHX --numeric-ids --delete "$tmp/" "$chroot/"

    umount -l "$tmp$boot_path" "$tmp"
    rm -rf "$tmp"

    dmsetup remove "${partitions[@]}"
    kpartx -d "$image"

    popd
    return 0
}

function _get_boot_path_image() {
    local chroot="$1"
    # extract boot partition mount location from fstab
    awk '$3=="vfat" {print $2}' "$chroot/etc/fstab"
}

function install_rp_image() {
    local platform="$1"
    if [[ -z "$platform" ]]; then
        printMsgs "console" "Requires a platform (eg rpi3/rpi4)"
        return 1
    fi

    local dist="$2"
    if [[ -z "$dist" ]]; then
        printMsgs "Requires a distribution name (eg rpios-buster/rpios-bullseye)"
        return 1
    fi

    local chroot="$3"
    [[ -z "$chroot" ]] && chroot="$md_build/$dist"

    local dist_version="$(_get_info_image "$dist" "version")"
    [[ -z "$dist_version" ]] && fatalError "Unable to get version information for $dist"

    # hostname to retropie
    echo "retropie" >"$chroot/etc/hostname"
    sed -i "s/raspberrypi/retropie/" "$chroot/etc/hosts"

    local boot_path="$(_get_boot_path_image "$chroot")"

    # quieter boot / disable plymouth (as without the splash parameter it
    # causes all boot messages to be displayed and interferes with people
    # using tty3 to make the boot even quieter)
    if ! grep -q consoleblank "$chroot$boot_path/cmdline.txt"; then
        # extra quiet as the raspbian usr/lib/raspi-config/init_resize.sh does
        # sed -i 's/ quiet init=.*$//' /boot/cmdline.txt so this will remove the last quiet
        # and the init line but leave ours intact
        sed -i "s/quiet/quiet loglevel=3 consoleblank=0 plymouth.enable=0 quiet/" "$chroot/boot/cmdline.txt"
    fi

    iniConfig "=" "" "$chroot$boot_path/config.txt"
    # set default GPU mem (videocore only)
    if [[ "$dist_version" -lt 11 && "$platform" == rpi[123] ]]; then
        iniSet "gpu_mem_256" 128
        iniSet "gpu_mem_512" 256
        iniSet "gpu_mem_1024" 256
    fi
    # set overscan_scale so ES scales to overscan settings.
    iniSet "overscan_scale" 1

    # disable 64bit kernel on 32bit userland OSs (to disable rpi4 defaulting to 64bit kernel)
    # 64 bit distros end in -64
    if [[ "$dist" != *-64 ]]; then
        iniSet "arm_64bit" 0
    # otherwise if on 64bit switch to using the 4k page size kernel
    else
        iniSet "kernel" "kernel8.img"
    fi

    [[ -z "$__chroot_repo" ]] && __chroot_repo="https://github.com/RetroPie/RetroPie-Setup.git"
    [[ -z "$__chroot_branch" ]] && __chroot_branch="master"
    cat > "$chroot/home/pi/install.sh" <<_EOF_
#!/bin/bash
cd
if systemctl is-enabled userconfig &>/dev/null; then
    echo "pi:raspberry" | sudo chpasswd
    sudo systemctl disable userconfig
    sudo systemctl --quiet enable getty@tty1
fi
sudo apt-get update
sudo apt-get -y install git dialog xmlstarlet joystick
git clone -b "$__chroot_branch" "$__chroot_repo"
cd RetroPie-Setup
modules=(
    # add apt-get parameters to force the use of new configuration files.
    # raspberrypi os packaging, sometimes thinks config files have been changed outside the packaging and prompts.
    'raspbiantools apt_upgrade -o Dpkg::Options::=--force-confnew'
    'setup basic_install'
    'bluetooth depends'
    'raspbiantools enable_modules'
    'autostart enable'
    'usbromservice'
    'samba depends'
    'samba install_shares'
    'splashscreen default'
    'splashscreen enable'
    'bashwelcometweak'
    'xpad'
)
for module in "\${modules[@]}"; do
    sudo __platform=$platform __nodialog=1 __has_binaries=$__chroot_has_binaries ./retropie_packages.sh \$module
done

# Remove any generated ssh host keys, which can happen if there is an update to openssh-server since the last raspberrypi os image
sudo rm /etc/ssh/*_key*

sudo rm -rf tmp
sudo apt-get clean
_EOF_

    # chroot and run install script
    rp_callModule image chroot "$chroot" bash /home/pi/install.sh

    rm "$chroot/home/pi/install.sh"

    # remove any ssh host keys that may have been generated during any ssh package upgrades
    rm -f "$chroot/etc/ssh/ssh_host"*
}

function _init_chroot_image() {
    local chroot="$1"
    [[ -z "$chroot" ]] && return 1

    # unmount on ctrl+c
    trap "_trap_chroot_image '$chroot'" INT

    # mount special filesystems to chroot
    mkdir -p "$chroot"{/dev/pts,/proc}
    mount none -t devpts "$chroot/dev/pts"
    mount -t proc /proc "$chroot/proc"

    local nameserver="$__nameserver"
    [[ -z "$nameserver" ]] && nameserver="$(nmcli device show | grep IP4.DNS | awk '{print $NF; exit}')"
    # so we can resolve inside the chroot
    echo "nameserver $nameserver" >"$chroot/etc/resolv.conf"

    # move /etc/ld.so.preload out of the way to avoid warnings
    if [[ -f "$chroot/etc/ld.so.preload" ]]; then
        mv "$chroot/etc/ld.so.preload" "$chroot/etc/ld.so.preload.bak"
    fi
}

function _deinit_chroot_image() {
    local chroot="$1"
    [[ -z "$chroot" ]] && return 1

    trap "" INT

    >"$chroot/etc/resolv.conf"

    # restore /etc/ld.so.preload if backup present
    if [[ -f "$chroot/etc/ld.so.preload.bak" ]]; then
        mv "$chroot/etc/ld.so.preload.bak" "$chroot/etc/ld.so.preload"
    fi

    umount -l "$chroot/proc" "$chroot/dev/pts"
    trap INT
}

function _trap_chroot_image() {
    _deinit_chroot_image "$1"
    exit
}

function chroot_image() {
    local chroot="$1"
    [[ -z "$chroot" ]] && return 1
    shift

    printMsgs "console" "Chrooting to $chroot ..."
    _init_chroot_image "$chroot"
    HOME="/home/pi" chroot --userspec 1000:1000 "$chroot" "$@"
    _deinit_chroot_image "$chroot"
}

function create_image() {
    local image="$1"
    [[ -z "$image" ]] && return 1

    local chroot="$2"
    [[ -z "$chroot" ]] && chroot="$md_build/chroot"

    local boot_size_mib="$3"
    # if not specified default the boot size partition to 512MiB
    [[ -z "$boot_size_mib" ]] && boot_size_mib=512

    # get size of files in MiB
    local chroot_size_mib=$(du -s -m "$chroot" 2>/dev/null | cut -f1)
    # make image size 256MiB larger than contents of chroot and boot partition
    local image_size_mib=$((boot_size_mib + chroot_size_mib + 256))

    # create image
    printMsgs "console" "Creating image $image ..."
    dd if=/dev/zero of="$image" bs=1M count="$image_size_mib"

    # partition
    printMsgs "console" "partitioning $image ..."
    local boot_start_mib=8
    local boot_end_mib=$((boot_start_mib + boot_size_mib))
    parted -s "$image" -- \
        mklabel msdos \
        unit mib \
        mkpart primary fat32 $boot_start_mib $boot_end_mib \
        mkpart primary $boot_end_mib -1s

    # format
    printMsgs "console" "Formatting $image ..."

    # change to the image folder as kpartx has problems removing the
    # device mapper files when using a full path to the image
    local image_path="${image%/*}"
    local image_name="${image##*/}"
    pushd "$image_path"

    local partitions=($(kpartx -s -a -v "$image_name" | awk '{ print "/dev/mapper/"$3 }'))
    local part_boot="${partitions[0]}"
    local part_root="${partitions[1]}"

    mkfs.vfat -F 32 -n bootfs "$part_boot"
    # use the mke2fs config from the chroot so we create the filesystem with supported features
    # disable huge_file & 64bit as with the Raspberry Pi OS images
    MKE2FS_CONFIG="$chroot/etc/mke2fs.conf" mkfs.ext4 -O ^huge_file,^64bit -L retropie "$part_root"

    parted "$image_name" print

    # disable ctrl+c
    trap "" INT

    # mount
    printMsgs "console" "Mounting $image_name ..."

    # get temporary directory
    local tmp="$(mktemp -d -p "$md_build")"

    # mount root partition
    mount "$part_root" "$tmp"

    # get the mount location of the boot partition from etc/fstab
    local boot_path="$(_get_boot_path_image "$chroot")"

    # create the boot partition mountpoint and mount
    mkdir -p "$tmp$boot_path"
    mount "$part_boot" "$tmp$boot_path"

    # copy files
    printMsgs "console" "Rsyncing chroot to $image_name ..."
    rsync -aAHX --numeric-ids "$chroot/" "$tmp/"

    # we need to fix up the UUIDS for /boot/cmdline.txt and /etc/fstab
    local old_id="$(sed "s/.*PARTUUID=\([^-]*\).*/\1/" $tmp$boot_path/cmdline.txt)"
    local new_id="$(blkid -s PARTUUID -o value "$part_root" | cut -c -8)"
    sed -i "s/$old_id/$new_id/" "$tmp$boot_path/cmdline.txt"
    sed -i "s/$old_id/$new_id/g" "$tmp/etc/fstab"

    # unmount
    umount -l "$tmp$boot_path" "$tmp"
    rm -rf "$tmp"

    kpartx -d "$image_name"

    trap INT
}

# generate berryboot squashfs from filesystem
function create_bb_image() {
    local image="$1"
    [[ -z "$image" ]] && return 1

    local chroot="$2"
    [[ -z "$chroot" ]] && return 1

    # replace fstab
    echo "proc            /proc           proc    defaults          0       0" >"$chroot/etc/fstab"

    # remove any earlier image
    rm -f "$image"

    mksquashfs "$chroot" "$image" -comp lzo -e boot -e lib/modules
}

function all_image() {
    local dist="$1"
    local make_bb="$2"
    local platforms="$(_get_info_image "$dist" "platforms")"
    [[ -z "$platforms" ]] && fatalError "Unable to get platforms information for $dist"

    local platform
    printMsgs "heading" "Building $platforms images based on $dist ..."
    for platform in $platforms; do
        platform_image "$platform" "$dist" "$make_bb"
    done
    combine_json_image
}

function platform_image() {
    local platform="$1"
    local dist="$2"
    local make_bb="$3"
    [[ -z "$platform" ]] && return 1

    local dest="$__tmpdir/images"
    mkdir -p "$dest"

    printMsgs "heading" "Building $platform image based on $dist ..."

    rp_callModule image create_chroot "$dist"
    rp_callModule image install_rp "$platform" "$dist" "$md_build/$dist"

    local dist_name="$(_get_info_image "$dist" "name")"
    [[ -z "$dist_name" ]] && fatalError "Unable to get name information for $dist"

    local dist_version="$(_get_info_image "$dist" "version")"
    [[ -z "$dist_version" ]] && fatalError "Unable to get version information for $dist"

    local file_add="$(_get_info_image "$dist" "file_${platform}")"
    [[ -z "$file_add" ]] && fatalError "Unable to get file_* information for $dist"

    local image_title="$(_get_info_image "$dist" "title_${platform}")"
    [[ -z "$image_title" ]] && fatalError "Unable to get image_title information for $dist"

    local image_base="retropie-${dist_name}-${__version}-${file_add}"
    local image_name="${image_base}.img"
    local image_file="$dest/$image_name"

    local boot_size_mib=512
    # use a 256MiB boot partition for Raspberry Pi OS lower than 12 (Bullseye and below)
    if [[ "$dist_version" -lt 12 ]]; then
        boot_size_mib=256
    fi

    rp_callModule image create "$image_file" "$md_build/$dist" $boot_size_mib
    [[ "$make_bb" -eq 1 ]] && rp_callModule image create_bb "$dest/${image_base}-berryboot.img256"

    printMsgs "console" "Compressing ${image_name} ..."
    xz -v --compress --stdout "$image_file" > "${image_file}.xz"

    printMsgs "console" "Generating JSON data for rpi-imager ..."
    local template
    template="$(<"$md_data/template.json")"
    template="${template/IMG_PATH/$__version\/${image_name}.xz}"
    template="${template/IMG_EXTRACT_SIZE/$(stat -c %s $image_file)}"
    template="${template/IMG_SHA256/$(sha256sum $image_file | cut -d" " -f1)}"
    template="${template/IMG_DOWNLOAD_SIZE/$(stat -c %s ${image_file}.xz)}"
    template="${template/IMG_VERSION/$__version}"
    template="${template/IMG_PLATFORM/$image_title}"
    template="${template/IMG_DATE/$(date '+%Y-%m-%d')}"
    echo "$template" >"${image_file}.json"

    rm -f "$image_file"
}

function combine_json_image() {
    local dest="$__tmpdir/images"
    {
        local template
        echo -en "{\n    \"os_list\": [\n"
        local i=0
        while read file; do
            [[ "$i" -gt 0 ]] && echo -en ",\n"
            template="$(<$file)"
            echo -n "$template"
            ((i++))
        done < <(find "$dest" -name "*.img.json" | sort)
        echo -en "\n    ]\n}\n"
    } >"$dest/os_list_imagingutility.json"
}
