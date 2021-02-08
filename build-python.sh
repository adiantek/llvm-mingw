#!/bin/sh
#
# Copyright (c) 2018 Martin Storsjo
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

set -e

: ${LIBFFI_VERSION:=dd5bd03075149d7cf8441875c1a344e8beb57dde}
: ${PYTHON_MAJOR:=3}
: ${PYTHON_MINOR:=8}
: ${PYTHON_PATCH:=7}
: ${PYTHON_VERSION:=v${PYTHON_MAJOR}.${PYTHON_MINOR}.${PYTHON_PATCH}}
: ${MINGW_W64_PATCH_VERSION:=2154528361f6818a40533ff872440b9cc2cb3e9a}

unset HOST

BUILDDIR=build

while [ $# -gt 0 ]; do
    case "$1" in
    --host=*)
        HOST="${1#*=}"
        BUILDDIR=$BUILDDIR-$HOST
        ;;
    *)
        PREFIX="$1"
        ;;
    esac
    shift
done

if [ -z "$CHECKOUT_ONLY" ]; then
    if [ -z "$PREFIX" ]; then
        echo $0 --host=triple dest
        exit 1
    fi

    mkdir -p "$PREFIX"
    PREFIX="$(cd "$PREFIX" && pwd)"
fi

MAKE=make
if [ -n "$(which gmake)" ]; then
    MAKE=gmake
fi

: ${CORES:=$(nproc 2>/dev/null)}
: ${CORES:=$(sysctl -n hw.ncpu 2>/dev/null)}
: ${CORES:=4}

if [ -z "$HOST" ]; then
    # Use a separate checkout for python for the native build; the
    # patches we apply for the mingw target break building for other
    # platforms.
    if [ ! -d cpython-native ]; then
        git clone https://github.com/python/cpython.git cpython-native
        CHECKOUT_PYTHON_NATIVE=1
    fi

    if [ -n "$SYNC" ] || [ -n "$CHECKOUT_PYTHON_NATIVE" ]; then
        cd cpython-native
        [ -z "$SYNC" ] || git fetch
        git checkout $PYTHON_VERSION
        autoreconf -vfi
        cd ..
    fi

    [ -z "$CHECKOUT_ONLY" ] || exit 0

    # Native build of python; assume libffi exists
    cd cpython-native
    [ -z "$CLEAN" ] || rm -rf $BUILDDIR
    mkdir -p $BUILDDIR
    cd $BUILDDIR
    ../configure --prefix="$PREFIX" --without-ensurepip
    $MAKE -j$CORES
    $MAKE install
    exit 0
fi

# Fetching
if [ ! -d libffi ]; then
    git clone https://github.com/libffi/libffi.git
    CHECKOUT_LIBFFI=1
fi

if [ ! -d cpython ]; then
    git clone https://github.com/python/cpython.git
    CHECKOUT_PYTHON=1
fi

if [ ! -d MINGW-packages ]; then
    git clone https://github.com/msys2/MINGW-packages.git
    CHECKOUT_PATCHES=1
fi

if [ -n "$SYNC" ] || [ -n "$CHECKOUT_LIBFFI" ]; then
    cd libffi
    [ -z "$SYNC" ] || git fetch
    git checkout $LIBFFI_VERSION
    autoreconf -vfi
    cd ..
fi

if [ -n "$SYNC" ] || [ -n "$CHECKOUT_PATCHES" ]; then
    cd MINGW-packages
    [ -z "$SYNC" ] || git fetch
    git checkout $MINGW_W64_PATCH_VERSION
    cd ..
fi

if [ -n "$SYNC" ] || [ -n "$CHECKOUT_PYTHON" ]; then
    cd cpython
    [ -z "$SYNC" ] || git fetch
    # Revert our patches
    git reset --hard HEAD
    git clean -fx
    git checkout $PYTHON_VERSION
    cat ../MINGW-packages/mingw-w64-python/*.patch | patch -Nup1
    cat ../patches/python/*.patch | patch -Nup1
    autoreconf -vfi
    cd ..
fi

[ -z "$CHECKOUT_ONLY" ] || exit 0

cd libffi
[ -z "$CLEAN" ] || rm -rf $BUILDDIR
mkdir -p $BUILDDIR
cd $BUILDDIR
../configure --prefix="$PREFIX" --host=$HOST --disable-symvers --disable-docs
$MAKE -j$CORES
$MAKE install
cd ../..

cd cpython
rm -f PC/pyconfig.h
[ -z "$CLEAN" ] || rm -rf $BUILDDIR
mkdir -p $BUILDDIR
cd $BUILDDIR
BUILD=$(../config.guess) # Python configure requires build triplet for cross compilation

export ac_cv_working_tzset=no
export ac_cv_header_dlfcn_h=no
export ac_cv_lib_dl_dlopen=no
export ac_cv_have_decl_RTLD_GLOBAL=no
export ac_cv_have_decl_RTLD_LAZY=no
export ac_cv_have_decl_RTLD_LOCAL=no
export ac_cv_have_decl_RTLD_NOW=no
export ac_cv_have_decl_RTLD_DEEPBIND=no
export ac_cv_have_decl_RTLD_MEMBER=no
export ac_cv_have_decl_RTLD_NODELETE=no
export ac_cv_have_decl_RTLD_NOLOAD=no

# Avoid gcc workarounds in distutils
export CC=$HOST-clang
export CXX=$HOST-clang++

../configure --prefix="$PREFIX" --build=$BUILD --host=$HOST \
    CFLAGS=" -fwrapv -D__USE_MINGW_ANSI_STDIO=1 -D_WIN32_WINNT=0x0601 -DNDEBUG -I../PC -I$PREFIX/include -Wno-ignored-attributes" \
    CXXFLAGS=" -fwrapv -D__USE_MINGW_ANSI_STDIO=1 -D_WIN32_WINNT=0x0601 -DNDEBUG -I../PC -I$PREFIX/include -Wno-ignored-attributes" \
    LDFLAGS="-L$PREFIX/lib -Wl,-s" \
    --enable-shared --with-nt-threads --with-system-ffi --without-ensurepip --without-c-locale-coercion
# $MAKE regen-importlib
# Omitting because it requires building a native Python, which gets complicated depending on what system we're building on
$MAKE -j$CORES
$MAKE install
rm -rf $PREFIX/lib/python*/test
find $PREFIX/lib/python* -name __pycache__ | xargs rm -rf
cd ../..
