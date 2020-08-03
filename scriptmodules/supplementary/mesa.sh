#!/usr/bin/env bash

# This file is part of The RetroPie Project
#
# The RetroPie Project is the legal property of its developers, whose names are
# too numerous to list here. Please refer to the COPYRIGHT.md file distributed with this source.
#
# See the LICENSE.md file at the top-level directory of this distribution and
# at https://raw.githubusercontent.com/RetroPie/RetroPie-Setup/master/LICENSE.md
#

rp_module_id="mesa"
rp_module_desc="mesa - build latest mesa from debian-experimental"
rp_module_licence="MIT https://www.mesa3d.org/license.html"
rp_module_section="exp"
rp_module_flags="!all rpi"

function _get_rasp_ver_mesa() {
    local pkg="$1"
    [[ -z "$pkg" ]] && pkg="libgl1-mesa-dri"
    # quick hack to get version of raspbian version (xargs used as a shortcut to trim whitespace)
    apt-cache madison "$pkg" | grep -m1 raspberrypi.org | cut -d\| -f2 | xargs
}

function add_repo_mesa() {
    echo "deb [trusted=yes] file:$md_inst ./" >/etc/apt/sources.list.d/retropie-mesa.list
}

function del_repo_mesa() {
    rm -f /etc/apt/sources.list.d/retropie-mesa.list
}

function remove_mesa() {
    del_repo_mesa
    downgrade_mesa
}

function depends_mesa() {
    local meson_ver="meson_0.54.3-1_all.deb"
    mkdir -p "$__tmpdir"
    local meson_pkg="$__tmpdir/$meson_ver"
    # get dependencies from system mesa
    apt-get -y build-dep mesa libdrm
    # additional dependencies
    getDepends libzstd-dev rsync llvm-9-dev libclang-9-dev valgrind
    if hasPackage meson 0.54 lt; then
        # latest mesa requires newer meson than is available in buster
        wget -O"$meson_pkg" "http://http.us.debian.org/debian/pool/main/m/meson/$meson_ver"
        dpkg -i "$meson_pkg"
        rm "$meson_pkg"
    fi
}

function sources_mesa() {
    local xorg_team_git="https://salsa.debian.org/xorg-team/"

    __persistent_repos=1

    # mesa 20.x requires newer libdrm
    gitPullOrClone "$md_build/libdrm" "$xorg_team_git/lib/libdrm.git" "debian-unstable"

    # get latest mesa sources
    gitPullOrClone "$md_build/mesa" https://gitlab.freedesktop.org/mesa/mesa.git

    cd "$md_build/mesa"

    # add debian mesa repository and fetch commits
    git remote add debian "$xorg_team_git/lib/mesa.git"
    git fetch debian debian-experimental

    # checkout debian folder from debian-experimental - ideally we would use debian-experimental as a base
    # and merge in upstream changes or rebase over upstream, however this requires manual intervention to resolve
    # conflicts, depending on how far debian-experimental is behind, and this is a more reliable, but hacky method.
    rm -rf debian
    git checkout debian/debian-experimental -- debian

    # lower dependencies from debian-experimental packaging
    applyPatch "$md_data/01-lower-dependencies.diff"

    # fix DRI_DRIVERS parameters to avoid a trailing empty , parameter which fails with recent meson.build
    applyPatch "$md_data/02-meson-array-fix.diff"

    # create a new entry in debian/changelog
    DEBEMAIL="Jools Wills <buzz@exotica.org.uk>" dch -v $(<VERSION) "Latest Mesa Developent code"
}

function build_mesa() {
    # force building/installing of libdrm first
    cd "$md_build/libdrm"
    (unset CFLAGS; dpkg-buildpackage -b -us -uc)
    install_mesa

    cd "$md_build/mesa"
    DEB_CFLAGS_PREPEND="$CFLAGS" DEB_CXXFLAGS_PREPEND="$CXXFLAGS" dpkg-buildpackage -us -uc -j$(nproc)
}

function install_mesa() {
    rsync -av --delete *.deb "$md_inst/"
    cd "$md_inst"
    dpkg-scanpackages -m . | gzip >"$md_inst/Packages.gz"
    add_repo_mesa
    apt-get update
    apt-get -y upgrade
}

function downgrade_mesa() {
    local rasp_ver="$(_get_rasp_ver_mesa)"
    local pkg

    while read pkg; do
        hasPackage "$pkg" && pkgs+=("$pkg=$rasp_ver")
    done < <(_get_mesa_packages_mesa)
    aptInstall --allow-downgrades "${pkgs[@]}"

    rasp_ver="$(_get_rasp_ver_mesa libdrm-dev)"
    while read pkg; do
        hasPackage "$pkg" && pkgs+=("$pkg=$rasp_ver")
    done < <(_get_libdrm_packages_mesa)
    aptInstall --allow-downgrades "${pkgs[@]}"

    # downgrade meson
    meson_ver=$(apt-cache madison meson | grep -m1 raspberrypi.org | cut -d\| -f2 | xargs)
    aptInstall --allow-downgrades "meson=$meson_ver"
}

function list_packages_mesa() {
    local rasp_ver="$(_get_rasp_ver_mesa)"

    local msg
    if hasPackage "libgl1-mesa-dri" "$rasp_ver" eq; then
        msg="You are running the Raspbian Mesa Packages (${rasp_ver})"
    else
        msg="You are NOT running the Raspbian Mesa Packages (${rasp_ver})"
    fi
    printMsgs "console" "$msg\n"

    printMsgs "console" "Currently installed:"
    local pkg
    while read pkg; do
        if hasPackage "$pkg"; then
            dpkg-query -W --showformat='Package: ${Package} - ${Version}\n' "$pkg"
        fi
    done < <(_get_mesa_packages_mesa)
}

function _get_mesa_packages_mesa() {
    local pkgs=(
        libd3dadapter9-mesa
        libd3dadapter9-mesa-dbgsym
        libd3dadapter9-mesa-dev
        libegl1-mesa
        libegl1-mesa-dev
        libegl-mesa0
        libegl-mesa0-dbgsym
        libgbm1
        libgbm1-dbgsym
        libgbm-dev
        libgl1-mesa-dev
        libgl1-mesa-dri
        libgl1-mesa-dri-dbgsym
        libgl1-mesa-glx
        libglapi-mesa
        libglapi-mesa-dbgsym
        libgles2-mesa
        libgles2-mesa-dev
        libglx-mesa0
        libglx-mesa0-dbgsym
        libosmesa6
        libosmesa6-dbgsym
        libosmesa6-dev
        libwayland-egl1-mesa
        mesa-common-dev
        mesa-opencl-icd
        mesa-opencl-icd-dbgsym
        mesa-va-drivers
        mesa-va-drivers-dbgsym
        mesa-vdpau-drivers
        mesa-vdpau-drivers-dbgsym
        mesa-vulkan-drivers
        mesa-vulkan-drivers-dbgsym
    )
    printf "%s\n" "${pkgs[@]}"
}

function _get_libdrm_packages_mesa() {
    local pkgs=(
        libdrm2
        libdrm2-dbgsym
        libdrm-amdgpu1
        libdrm-amdgpu1
        libdrm-common
        libdrm-dev
        libdrm-etnaviv1
        libdrm-etnaviv1-dbgsym
        libdrm-exynos1
        libdrm-exynos1-dbgsym
        libdrm-freedreno1
        libdrm-freedreno1-dbgsym
        libdrm-nouveau2
        libdrm-nouveau2-dbgsym
        libdrm-omap1
        libdrm-omap1-dbgsym
        libdrm-radeon1
        libdrm-radeon1-dbgsym
        libdrm-tegra0
        libdrm-tegra0-dbgsym
        libdrm-tests
        libdrm-tests-dbgsym
    )
    printf "%s\n" "${pkgs[@]}"
}
