FROM ubuntu:16.04

MAINTAINER Hugo Beauzée-Luyssen <hugo@beauzee.fr>

#FIXME: Remove vim once debuging is complete
# git-svn is only used to get sensible version numbers in clang version printouts
RUN apt-get update -qq && apt-get install -qqy \
    git wget bzip2 file libwine-development-dev unzip libtool pkg-config cmake \
    build-essential automake texinfo ragel yasm p7zip-full gettext autopoint \
    vim python git-svn


RUN git config --global user.name "VideoLAN Buildbot" && \
    git config --global user.email buildbot@videolan.org

WORKDIR /build

# When cloning master and checking out a pinned old hash, we can't use --depth=1.
RUN git clone -b master https://github.com/llvm-mirror/llvm.git && \
    cd llvm/tools && \
    git clone -b master https://github.com/llvm-mirror/clang.git && \
    git clone -b master https://github.com/llvm-mirror/lld.git && \
    cd .. && \
    git svn init https://llvm.org/svn/llvm-project/llvm/trunk && \
    git config svn-remote.svn.fetch :refs/remotes/origin/master && \
    git svn rebase -l && \
    git checkout 3254c743c87df0aefff33424852df5ca3fbda277 && \
    cd tools/clang && \
    git svn init https://llvm.org/svn/llvm-project/cfe/trunk && \
    git config svn-remote.svn.fetch :refs/remotes/origin/master && \
    git svn rebase -l && \
    git checkout 420a3ebdcee02758222bc4a11351e3a4083e6922 && \
    cd ../lld && \
    git checkout a1d06e7cbe1fcb2370fef00d4cc9f367d4b577cc


RUN mkdir /build/prefix

# Build LLVM
RUN cd llvm && mkdir build && cd build && cmake \
    -DCMAKE_INSTALL_PREFIX="/build/prefix" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_TARGETS_TO_BUILD="ARM;AArch64;X86" \
    ../ && \
    make -j4 && \
    make install

RUN git clone git://git.code.sf.net/p/mingw-w64/mingw-w64 && \
    cd mingw-w64 && \
    git checkout e09dd4ca58c9570d0ce0206bef95881f79663a0d


ENV TOOLCHAIN_PREFIX=/build/prefix
ENV PATH=$TOOLCHAIN_PREFIX/bin:$PATH

RUN cd mingw-w64/mingw-w64-headers && \
    for arch in armv7 aarch64 i686 x86_64; do \
      mkdir build-${arch} && cd build-${arch} && \
        ../configure --host=${arch}-w64-mingw32 --prefix=$TOOLCHAIN_PREFIX/${arch}-w64-mingw32 \
        --enable-secure-api && \
        make install && \
      cd .. || exit 1; \
    done

# Install the usual $TUPLE-clang binaries
RUN mkdir /build/wrappers
COPY wrappers/clang-target-wrapper /build/wrappers
RUN for arch in armv7 aarch64 i686 x86_64; do \
      for exec in clang clang++; do \
        cp wrappers/clang-target-wrapper $TOOLCHAIN_PREFIX/bin/${arch}-w64-mingw32-${exec}; \
      done; \
    done

ENV AR=llvm-ar 
ENV RANLIB=llvm-ranlib 
ENV LD=lld
ENV AS=llvm-as
ENV NM=llvm-nm

# Build mingw with our freshly built cross compiler
RUN cd mingw-w64/mingw-w64-crt && \
    for arch in armv7 aarch64 i686 x86_64; do \
        mkdir build-$arch && cd build-$arch && \
        case $arch in \
        armv7) \
            FLAGS="--disable-lib32 --disable-lib64 --enable-libarm32" \
            ;; \
        aarch64) \
            FLAGS="--disable-lib32 --disable-lib64 --enable-libarm64" \
            ;; \
        i686) \
            FLAGS="--enable-lib32 --disable-lib64" \
            ;; \
        x86_64) \
            FLAGS="--disable-lib32 --enable-lib64" \
            ;; \
        esac && \
        CC=$arch-w64-mingw32-clang \
        AR=llvm-ar DLLTOOL=llvm-dlltool ../configure --host=$arch-w64-mingw32 --prefix=$TOOLCHAIN_PREFIX/$arch-w64-mingw32 $FLAGS && \
        make -j4 && make install && \
        cd .. || exit 1; \
    done

#RUN cp /build/mingw-w64/mingw-w64-libraries/winpthreads/include/* $MINGW_PREFIX/include/

RUN git clone -b master https://github.com/llvm-mirror/compiler-rt.git && \
    cd compiler-rt && \
    git checkout 1c3df8c3b6deb2547abd998c3f688c7d56494333

# Add a symlink for i386 -> i686; we normally name the toolchain
# i686-w64-mingw32, but due to the compiler-rt cmake peculiarities, we
# need to refer to it as i386 at this stage.
RUN cd /build/prefix && ln -s i686-w64-mingw32 i386-w64-mingw32

# Manually build compiler-rt as a standalone project
RUN cd compiler-rt && \
    for arch in armv7 aarch64 i686 x86_64; do \
        buildarchname=$arch && \
        libarchname=$arch && \
        case $arch in \
        armv7) \
            libarchname=arm \
            ;; \
        i686) \
            buildarchname=i386 \
            libarchname=i386 \
            ;; \
        esac && \
        mkdir build-$arch && cd build-$arch && cmake \
            -DCMAKE_C_COMPILER=$arch-w64-mingw32-clang \
            -DCMAKE_SYSTEM_NAME=Windows \
            -DCMAKE_AR=$TOOLCHAIN_PREFIX/bin/$AR \
            -DCMAKE_RANLIB=$TOOLCHAIN_PREFIX/bin/$RANLIB \
            -DCMAKE_C_COMPILER_WORKS=1 \
            -DCMAKE_C_COMPILER_TARGET=$buildarchname-windows-gnu \
            -DCOMPILER_RT_DEFAULT_TARGET_ONLY=TRUE \
            ../lib/builtins && \
        make -j4 && \
        mkdir -p /build/prefix/lib/clang/6.0.0/lib/windows && \
        cp lib/windows/libclang_rt.builtins-$buildarchname.a /build/prefix/lib/clang/6.0.0/lib/windows/libclang_rt.builtins-$libarchname.a && \
        cd .. || exit 1; \
    done

#RUN cd mingw-w64/mingw-w64-libraries && cd winstorecompat && \
#    autoreconf -vif && \
#    mkdir build && cd build && \
#    ../configure --host=$TARGET_TUPLE --prefix=$MINGW_PREFIX && make && make install

#RUN cd /build/mingw-w64/mingw-w64-tools/widl && \
#    mkdir build && cd build && \
#    CC=gcc \
#    ../configure --prefix=$TOOLCHAIN_PREFIX --target=$TARGET_TUPLE && \
#    make -j4 && \
#    make install 

RUN git clone -b master https://github.com/llvm-mirror/libcxx.git && \
    git clone -b master https://github.com/llvm-mirror/libcxxabi.git && \
    cd libcxx && \
    git checkout 5f919fe349450b3da0e29611ae37f6a940179290 && \
    cd ../libcxxabi && \
    git checkout b157fdd968a4e1093645ec7c65213736c4bc7ea6

#    git clone -b release_40 --depth=1 https://github.com/llvm-mirror/libunwind.git

#RUN cd libunwind && mkdir build && cd build && \
#    CXXFLAGS="-nodefaultlibs -D_LIBUNWIND_IS_BAREMETAL" \
#    LDFLAGS="/build/prefix/armv7-w64-mingw32/lib/crt2.o /build/prefix/armv7-w64-mingw32/lib/crtbegin.o -lmingw32 /build/prefix/bin/../lib/clang/4.0.1/lib/windows/libclang_rt.builtins-arm.a -lmoldname -lmingwex -lmsvcrt -ladvapi32 -lshell32 -luser32 -lkernel32 /build/prefix/armv7-w64-mingw32/lib/crtend.o" \
#    cmake \
#        -DCMAKE_CXX_COMPILER_WORKS=TRUE \
#        -DLLVM_ENABLE_LIBCXX=TRUE \
#        -DCMAKE_BUILD_TYPE=Release \
#        -DLIBUNWIND_ENABLE_SHARED=OFF \
#        ..

#RUN cd libunwind/build && make -j4
#RUN cd libunwind/build && make install

RUN cd libcxxabi && \
    for arch in armv7 aarch64 i686 x86_64; do \
        mkdir build-$arch && cd build-$arch && cmake \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX=$TOOLCHAIN_PREFIX/$arch-w64-mingw32 \
            -DCMAKE_C_COMPILER=$arch-w64-mingw32-clang \
            -DCMAKE_CXX_COMPILER=$arch-w64-mingw32-clang++ \
            -DCMAKE_CROSSCOMPILING=TRUE \
            -DCMAKE_SYSTEM_NAME=Windows \
            -DCMAKE_C_COMPILER_WORKS=TRUE \
            -DCMAKE_CXX_COMPILER_WORKS=TRUE \
            -DCMAKE_AR=$TOOLCHAIN_PREFIX/bin/$AR \
            -DCMAKE_RANLIB=$TOOLCHAIN_PREFIX/bin/$RANLIB \
            -DLIBCXXABI_USE_COMPILER_RT=ON \
            -DLIBCXXABI_ENABLE_EXCEPTIONS=OFF \
            -DLIBCXXABI_ENABLE_THREADS=OFF \
            -DLIBCXXABI_TARGET_TRIPLE=$arch-w64-mingw32 \
            -DLIBCXXABI_ENABLE_SHARED=OFF \
            -DLIBCXXABI_LIBCXX_INCLUDES=../../libcxx/include \
            -DLLVM_NO_OLD_LIBSTDCXX=TRUE \
            -DCXX_SUPPORTS_CXX11=TRUE \
            -DCMAKE_CXX_FLAGS="-fno-exceptions -D_WIN32_WINNT=0x600 -D_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS -Xclang -flto-visibility-public-std" \
            .. && \
        make -j4 && \
        cd .. || exit 1; \
    done

RUN cd libcxx && \
    for arch in armv7 aarch64 i686 x86_64; do \
        mkdir build-$arch && cd build-$arch && cmake \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX=$TOOLCHAIN_PREFIX/$arch-w64-mingw32 \
            -DCMAKE_C_COMPILER=$arch-w64-mingw32-clang \
            -DCMAKE_CXX_COMPILER=$arch-w64-mingw32-clang++ \
            -DCMAKE_CROSSCOMPILING=TRUE \
            -DCMAKE_SYSTEM_NAME=Windows \
            -DCMAKE_C_COMPILER_WORKS=TRUE \
            -DCMAKE_CXX_COMPILER_WORKS=TRUE \
            -DCMAKE_AR=$TOOLCHAIN_PREFIX/bin/$AR \
            -DCMAKE_RANLIB=$TOOLCHAIN_PREFIX/bin/$RANLIB \
            -DLIBCXX_INSTALL_HEADERS=ON \
            -DLIBCXX_ENABLE_EXCEPTIONS=OFF \
            -DLIBCXX_ENABLE_THREADS=OFF \
            -DLIBCXX_ENABLE_MONOTONIC_CLOCK=OFF \
            -DLIBCXX_ENABLE_SHARED=OFF \
            -DLIBCXX_SUPPORTS_STD_EQ_CXX11_FLAG=TRUE \
            -DLIBCXX_HAVE_CXX_ATOMICS_WITHOUT_LIB=TRUE \
            -DLIBCXX_ENABLE_EXPERIMENTAL_LIBRARY=OFF \
            -DLIBCXX_ENABLE_FILESYSTEM=OFF \
            -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=TRUE \
            -DLIBCXX_CXX_ABI=libcxxabi \
            -DLIBCXX_CXX_ABI_INCLUDE_PATHS=../../libcxxabi/include \
            -DLIBCXX_CXX_ABI_LIBRARY_PATH=../../libcxxabi/build-$arch/lib \
            -DCMAKE_CXX_FLAGS="-fno-exceptions -D_LIBCXXABI_DISABLE_VISIBILITY_ANNOTATIONS -Xclang -flto-visibility-public-std" \
            .. && \
        make -j4 && make install && \
        cd .. || exit 1; \
    done

RUN cd /build/prefix/include && ln -s /build/prefix/armv7-w64-mingw32/include/c++ .

RUN mkdir -p /build/hello
COPY hello.c hello.cpp /build/hello/
RUN cd /build/hello && \
    for arch in armv7 aarch64 x86_64 i686; do \
        $arch-w64-mingw32-clang hello.c -o hello-$arch.exe || exit 1; \
    done

RUN cd /build/hello && \
    for arch in armv7 aarch64 x86_64 i686; do \
        $arch-w64-mingw32-clang++ hello.cpp -o hello-cpp-$arch.exe -fno-exceptions -D_LIBCXXABI_DISABLE_VISIBILITY_ANNOTATIONS -Xclang -flto-visibility-public-std -D_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS || exit 1; \
    done

RUN git clone --depth=1 git://git.libav.org/libav.git

RUN cd /build/libav && \
    mkdir build && cd build && \
    ../configure --arch=aarch64 --target-os=mingw32 --cc=aarch64-w64-mingw32-clang --ar=llvm-ar --nm=llvm-nm --enable-cross-compile --enable-gpl && \
    make -j4 all testprogs

