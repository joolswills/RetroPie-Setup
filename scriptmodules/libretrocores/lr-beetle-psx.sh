#!/usr/bin/env bash

# This file is part of The RetroPie Project
#
# The RetroPie Project is the legal property of its developers, whose names are
# too numerous to list here. Please refer to the COPYRIGHT.md file distributed with this source.
#
# See the LICENSE.md file at the top-level directory of this distribution and
# at https://raw.githubusercontent.com/RetroPie/RetroPie-Setup/master/LICENSE.md
#

rp_module_id="lr-beetle-psx"
rp_module_desc="PlayStation emulator - Mednafen PSX Port for libretro"
rp_module_help="ROM Extensions: .bin .cue .cbn .img .iso .m3u .mdf .pbp .toc .z .znx\n\nCopy your PlayStation roms to $romdir/psx\n\nCopy the required BIOS files\n\nscph5500.bin and\nscph5501.bin and\nscph5502.bin to\n\n$biosdir"
rp_module_licence="GPL2 https://raw.githubusercontent.com/libretro/beetle-psx-libretro/master/COPYING"
rp_module_section="opt x86=main aarch64=exp"
rp_module_flags="!arm"

function depends_lr-beetle-psx() {
    local depends=()
    isPlatform "x86" && depends+=(libvulkan-dev libgl1-mesa-dev)
    getDepends "${depends[@]}"
}

function sources_lr-beetle-psx() {
    gitPullOrClone "$md_build" https://github.com/libretro/beetle-psx-libretro.git
}

function build_lr-beetle-psx() {
    local params=()
    local target="mednafen_psx_libretro.so"
    if isPlatform "x86"; then
        params+=(HAVE_HW=1)
        target="mednafen_psx_hw_libretro.so"
    fi
    make clean
    make "${params[@]}"
    md_ret_require="$md_build/$target"
}

function install_lr-beetle-psx() {
    local target="mednafen_psx_libretro.so"
    isPlatform "x86" && target="mednafen_psx_hw_libretro.so"
    md_ret_files="$target"
}

function configure_lr-beetle-psx() {
    local target="mednafen_psx_libretro.so"
    isPlatform "x86" && target="mednafen_psx_hw_libretro.so"

    mkRomDir "psx"
    ensureSystemretroconfig "psx"

    if ! isPlatform "x86"; then
        # Use asyncronous CD loading on (typically low I/O) non-x86 platforms
        setRetroArchCoreOption "beetle_psx_cd_access_method" "async"
        # enable the dynamic recompiler for non-x86 platforms
        setRetroArchCoreOption "beetle_psx_cpu_dynarec" "execute"
    fi

    addEmulator 0 "$md_id" "psx" "$md_inst/$target"
    addSystem "psx"
}
