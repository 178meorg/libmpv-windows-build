#!/bin/bash
set -x

main() {
    gitdir=$(pwd)
    clang_root=$(pwd)/clang_root
    buildroot=$(pwd)
    srcdir=$(pwd)/src_packages
    local target=$1
    compiler=$2
    simple_package=$3

    prepare
    if [ "$target" == "32" ]; then
        package "32" 
    elif [ "$target" == "64" ]; then
        package "64"
    elif [ "$target" == "64-v3" ]; then
        package "64-v3"
    elif [ "$target" == "aarch64" ]; then
        package "aarch64"
    elif [ "$target" == "all-64" ]; then
        package "64"
        package "64-v3"
        package "aarch64"
    else [ "$target" == "all" ];
        package "32"
        package "64"
        package "64-v3"
        package "aarch64"
    fi
    rm -rf ./release/mpv-packaging-master
}

package() {
    local bit=$1
    if [ $bit == "32" ]; then
        local arch="i686"
    elif [ $bit == "64" ]; then
        local arch="x86_64"
    elif [ $bit == "64-v3" ]; then
        local arch="x86_64"
        local gcc_arch="-DGCC_ARCH=x86-64-v3"
        local x86_64_level="-v3"
    elif [ $bit == "aarch64" ]; then
        local arch="aarch64"
    fi

    build $bit $arch $gcc_arch
    zip $bit $arch $x86_64_level
    sudo rm -rf $buildroot/build$bit/mpv-*
    sudo chmod -R a+rwx $buildroot/build$bit
}

build() {
    local bit=$1
    local arch=$2
    local gcc_arch=$3
    
    if [ "$compiler" == "clang" ]; then
        clang_option=(-DCMAKE_INSTALL_PREFIX=$clang_root -DMINGW_INSTALL_PREFIX=$buildroot/build$bit/install/$arch-w64-mingw32 -DCLANG_PACKAGES_LTO=ON)
    fi
    cmake -Wno-dev --fresh -DTARGET_ARCH=$arch-w64-mingw32 $gcc_arch -DCOMPILER_TOOLCHAIN=$compiler "${clang_option[@]}" $extra_option -DENABLE_CCACHE=ON -DSINGLE_SOURCE_LOCATION=$srcdir -DRUSTUP_LOCATION=$buildroot/install_rustup -G Ninja -H$gitdir -B$buildroot/build$bit

    ninja -C $buildroot/build$bit download || true

    if [ "$compiler" == "gcc" ] && [ ! -f "$buildroot/build$bit/install/bin/cross-gcc" ]; then
        ninja -C $buildroot/build$bit gcc && rm -rf $buildroot/build$bit/toolchain
    elif [ "$compiler" == "clang" ]; then
        local target_prefix="$arch-w64-mingw32"
        local target_sysroot="$buildroot/build$bit/install/$target_prefix"

        if [ ! -x "$clang_root/bin/clang" ]; then
            echo "Prebuilt LLVM toolchain is missing: $clang_root/bin/clang"
            echo "Run the LLVM workflow to publish the ${LLVM_RELEASE_TAG:-llvm-toolchain} release first."
            exit 1
        fi

        local compiler_resource_dir
        compiler_resource_dir=$("$clang_root/bin/clang" --print-resource-dir) || exit 1
        if [ ! -x "$clang_root/bin/$target_prefix-clang" ] || \
           [ ! -x "$clang_root/bin/$target_prefix-ar" ] || \
           [ ! -f "$compiler_resource_dir/lib/$arch-pc-windows-gnu/libclang_rt.builtins.a" ] || \
           [ ! -f "$target_sysroot/include/windows.h" ] || \
           [ ! -f "$target_sysroot/lib/libc++.a" ]; then
            cmake --build "$buildroot/build$bit" --target llvm-download || exit 1
            # A native LLVM release can be combined with an existing sysroot
            # cache whose stamps refer to cross tools no longer in clang_root.
            ninja -C "$buildroot/build$bit" llvm-wrapper-fullclean llvm-compiler-rt-builtin-fullclean || exit 1
            ninja -C "$buildroot/build$bit" llvm-clang || exit 1
        fi
    fi

    if [[ ! "$(ls -A $buildroot/install_rustup/.cargo/bin)" ]]; then
        ninja -C $buildroot/build$bit rustup-fullclean
        ninja -C $buildroot/build$bit rustup
    fi
    ninja -C $buildroot/build$bit update

    # A changed pin must invalidate restored build stamps before mpv links the
    # corresponding static library. Matching pins keep their dependency cache.
    local package_name pinned_commit built_commit
    for package_name in ffmpeg uchardet; do
        pinned_commit=$(awk '$1 == "GIT_RESET" { print $2; exit }' "$gitdir/packages/$package_name.cmake")
        if [[ ! "$pinned_commit" =~ ^[0-9a-f]{40}$ ]]; then
            echo "Invalid $package_name commit pin: $pinned_commit" >&2
            exit 1
        fi
        built_commit=$(cat "$buildroot/build$bit/packages/$package_name-prefix/src/$package_name-stamp/HEAD" 2>/dev/null || true)
        if [[ "$built_commit" != "$pinned_commit" ]]; then
            ninja -C "$buildroot/build$bit" "$package_name-fullclean" || exit 1
        fi
    done
    ninja -C $buildroot/build$bit mpv-fullclean
    
    ninja -C $buildroot/build$bit mpv

    if [ -n "$(find $buildroot/build$bit -maxdepth 1 -type d -name "mpv*$arch*" -print -quit)" ] ; then
        echo "Successfully compiled $bit-bit. Continue"
    else
        echo "Failed compiled $bit-bit. Stop"
        exit 1
    fi
    
    ninja -C $buildroot/build$bit cargo-clean
}

zip() {
    local bit=$1
    local arch=$2
    local x86_64_level=$3

    mv $buildroot/build$bit/mpv-* $gitdir/release
    if [ "$simple_package" != "true" ]; then
        cd $gitdir/release/mpv-packaging-master
        cp -r ./mpv-root/* ../mpv-$arch$x86_64_level*
    fi
    cd $gitdir/release
    for dir in ./mpv*$arch$x86_64_level*; do
        if [ -d $dir ]; then
            7z a -m0=lzma2 -mx=9 -ms=on $dir.7z $dir/* -x!*.7z
            rm -rf $dir
        fi
    done
    cd ..
}

download_mpv_package() {
    local package_url="https://codeload.github.com/zhongfly/mpv-packaging/zip/master"
    if [ -e mpv-packaging.zip ]; then
        echo "Package exists. Check if it is newer.."
        remote_commit=$(git ls-remote https://github.com/zhongfly/mpv-packaging.git master | awk '{print $1;}')
        local_commit=$(unzip -z mpv-packaging.zip | tail +2)
        if [ "$remote_commit" != "$local_commit" ]; then
            wget -qO mpv-packaging.zip $package_url
        fi
    else
        wget -qO mpv-packaging.zip $package_url
    fi
    unzip -o mpv-packaging.zip
}

prepare() {
    mkdir -p ./release
    if [ "$simple_package" != "true" ]; then
        cd ./release
        download_mpv_package
        cd ./mpv-packaging-master
        cd ../..
    fi
}

while getopts t:c:s:e: flag
do
    case "${flag}" in
        t) target=${OPTARG};;
        c) compiler=${OPTARG};;
        s) simple_package=${OPTARG};;
        e) extra_option=${OPTARG};;
    esac
done

main "${target:-all-64}" "${compiler:-gcc}" "${simple_package:-false}"
