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
    local meson_ver="meson_0.56.2-1_all.deb"
    mkdir -p "$__tmpdir"
    local meson_pkg="$__tmpdir/$meson_ver"
    # make sure raspberrypi deb-src repo is enabled
    sed -i "s/#.*deb-src/deb-src/" /etc/apt/sources.list.d/raspi.list
    aptUpdate
    # get dependencies from system mesa
    apt-get -y build-dep mesa libdrm libglvnd
    # additional dependencies
    getDepends libzstd-dev rsync llvm-9-dev libclang-9-dev valgrind libxcb-shm0-dev python3-docutils
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

    # and libglvnd
    gitPullOrClone "$md_build/libglvnd" "$xorg_team_git/lib/libglvnd.git" "debian-unstable"

    # reset / clean any existing source folder
    if [[ -d "$md_build/mesa/.git" ]]; then
        git -C "$md_build/mesa" reset --hard
        git -C "$md_build/mesa" clean -f -d
    fi

    # get latest mesa sources
    gitPullOrClone "$md_build/mesa" https://gitlab.freedesktop.org/mesa/mesa.git main

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
    cd debian
    applyPatch "$md_data/01-lower-dependencies.diff"
    cd ..

    # create a new entry in debian/changelog
    DEBEMAIL="Jools Wills <buzz@exotica.org.uk>" dch -v $(<VERSION) "Latest Mesa Developent code"
}

function build_mesa() {
    # force building/installing of libdrm first
    cd "$md_build/libdrm"
    (unset CFLAGS; dpkg-buildpackage -b -us -uc)
    cd "$md_build/libglvnd"
    (unset CFLAGS; dpkg-buildpackage -b -us -uc)

    install_mesa

    cd "$md_build/mesa"
    DEB_CFLAGS_PREPEND="$CFLAGS" DEB_CXXFLAGS_PREPEND="$CXXFLAGS" dpkg-buildpackage -us -uc -j$(nproc)
}

function install_mesa() {
    rsync -av "$md_build"/*.deb "$md_inst/"
    cd "$md_inst"
    dpkg-scanpackages -m . | gzip >"$md_inst/Packages.gz"
    add_repo_mesa
    apt-get update
    apt-get -y dist-upgrade
}

function downgrade_mesa() {
    declare -A name_pkg=(
        ["mesa"]="libgl1-mesa-dev"
        ["libdrm"]="libdrm-dev"
        ["libglvnd"]="libglvnd-dev"
    )

    local name
    local pkg
    for name in "${!name_pkg[@]}"; do
        local rasp_ver="$(_get_rasp_ver_mesa "${name_pkg[$name]}")"
        while read pkg; do
            hasPackage "$pkg" && pkgs+=("$pkg=$rasp_ver")
        done < <(_get_${name}_packages_mesa)
        aptInstall --allow-downgrades "${pkgs[@]}"
    done

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

function _get_libglvnd_packages_mesa() {
    local pkgs=(
        libegl1
        libegl1-dbgsym
        libegl-dev
        libgl1
        libgl1-dbgsym
        libgl-dev
        libgles1
        libgles1-dbgsym
        libgles2
        libgles2-dbgsym
        libgles-dev
        libglvnd0
        libglvnd0-dbgsym
        libglvnd-core-dev
        libglvnd-dev
        libglx0
        libglx0-dbgsym
        libglx-dev
        libopengl0
        libopengl0-dbgsym
        libopengl-dev
    )
    printf "%s\n" "${pkgs[@]}"
}
