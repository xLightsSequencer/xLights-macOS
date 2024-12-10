#!/bin/bash -e

# System dependency checks...
if [ ! -d /opt/local/lib ] || [ ! -d /opt/local/libdbg ] || [ ! -d /opt/local/bin ] || [ ! -d /opt/local/bin ] ; then
  echo "/opt/local/bin, /opt/local/lib, /opt/local/libdbg and /opt/local/include must exist and be writable!"
  exit 1
fi
if ! command -v brew > /dev/null ; then
  echo 'Some libraries require Homebrew Tools, to install Homebrew:'
  echo '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  exit 1
fi

export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-11.0}
export OSX_VERSION_MIN="-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
export ARM64_TARGETS="-target arm64-apple-macos11.0 -arch arm64"
export X86_64_TARGETS="-target x86_64-apple-macos11.0 -arch x86_64"

# Absolute path to directory containing the xLights source tree
# Default assumes that xlights is cloned in your cwd
export XL_DIR="${XL_DIR:-$(realpath ./xlights)}"

# Core count of the build host
export NUM_CPUS="${NUM_CPUS:-$(sysctl -n hw.ncpu)}"
echo "Building with $NUM_CPUS cores"

#need ONE of these lines
export XL_TARGETS="${X86_64_TARGETS} ${ARM64_TARGETS}"
# export XL_TARGETS="${X86_64_TARGETS}"
# export XL_TARGETS="${ARM64_TARGETS}"

export BUILD_HOST="$(uname -p)"
echo "Build host architecture is $BUILD_HOST"

set -x
# install dependencies from homebrew
brew install automake libtool cmake nasm

echo "libzstd"
if [ ! -d "zstd" ]; then git clone https://github.com/facebook/zstd ; fi
pushd zstd
git checkout v1.5.6
export CFLAGS="-g -flto=thin  ${OSX_VERSION_MIN} ${XL_TARGETS}"
export LDFLAGS="-flto=thin  ${OSX_VERSION_MIN} ${XL_TARGETS} "
make clean
make -j ${NUM_CPUS} HAVE_LZMA=0 HAVE_LZ4=0 lib-mt
cp lib/libzstd.a /opt/local/lib
export CFLAGS="-g  ${OSX_VERSION_MIN} ${XL_TARGETS}"
export LDFLAGS=" ${OSX_VERSION_MIN} ${XL_TARGETS}"
make clean
make -j ${NUM_CPUS} HAVE_LZMA=0 HAVE_LZ4=0 lib-mt
cp lib/libzstd.a /opt/local/libdbg
unset CFLAGS
unset LDFLAGS
popd

echo "log4cpp"
# Download latest src release (current 1.1.3)
if [ -d "log4cpp" ] ; then rm -r log4cpp ; fi
curl -LO https://nchc.dl.sourceforge.net/project/log4cpp/log4cpp-1.1.x%20%28new%29/log4cpp-1.1/log4cpp-1.1.3.tar.gz
tar -xzf log4cpp-1.1.3.tar.gz
pushd log4cpp
patch -p1 < "${XL_DIR}/macOS/patches/log4cpp.patch"
export CXXFLAGS="-g -O2 -flto=thin ${OSX_VERSION_MIN} ${XL_TARGETS} -std=c++11 -stdlib=libc++ -fvisibility-inlines-hidden "
export LDFLAGS="-flto=thin ${XL_TARGETS} "
./configure --prefix=/opt/local -host ${BUILD_HOST}
make clean
make -j ${NUM_CPUS}
cp src/.libs/liblog4cpp.a /opt/local/lib
export CXXFLAGS="-g ${OSX_VERSION_MIN} ${XL_TARGETS} -std=c++11 -stdlib=libc++ -fvisibility-inlines-hidden "
export LDFLAGS="${XL_TARGETS} "
./configure --prefix=/opt/local -host ${BUILD_HOST}
make clean
make -j ${NUM_CPUS}
cp src/.libs/liblog4cpp.a /opt/local/libdbg
unset CXXFLAGS
unset LDFLAGS
popd

echo "liquidfun"
# requires cmake to be installed, most likely need to have
# homebrew installed and then "brew install cmake"
# aternatively, install CMAKE for OSX from https://cmake.org/download/
# and add the full path to cmake to PATH
# PATH=$PATH:/Applications/CMake.app/Contents/bin/
if [ ! -d "liquidfun" ] ; then git clone https://github.com/google/liquidfun ; fi
pushd liquidfun/liquidfun/Box2D
git status --ignored -s | colrm 1 2 | xargs rm -rf
export CXX=clang++
export CXXFLAGS="-g -O3 -flto=thin  ${XL_TARGETS} ${OSX_VERSION_MIN} "
cmake -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release -DBOX2D_BUILD_EXAMPLES=OFF
echo "CXX_FLAGS += -Wno-unused-but-set-variable -Wno-error " >> ./Box2D/CMakeFiles/Box2D.dir/flags.make
make clean
make -j $NUM_CPUS
cp ./Box2D/Release/libliquidfun.a /opt/local/lib
git status --ignored -s | colrm 1 2 | xargs rm -rf
export CXXFLAGS="-g ${XL_TARGETS} ${OSX_VERSION_MIN} "
cmake -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release -DBOX2D_BUILD_EXAMPLES=OFF
echo "CXX_FLAGS += -Wno-unused-but-set-variable -Wno-error " >> ./Box2D/CMakeFiles/Box2D.dir/flags.make
make clean
make -j $NUM_CPUS
cp ./Box2D/Release/libliquidfun.a /opt/local/libdbg
unset CXXFLAGS
unset CXX
popd

echo "SDL2"  currently using 2.30.9
if [ ! -d "SDL" ] ; then git clone https://github.com/libsdl-org/SDL ; fi
pushd SDL
git fetch -v
git reset --hard
git checkout release-2.30.9
export CXXFLAGS="-g -O3 -flto=thin ${XL_TARGETS} ${OSX_VERSION_MIN} "
export CFLAGS="-g -O3 -flto=thin ${XL_TARGETS} ${OSX_VERSION_MIN} "
export LDFLAGS="-g -O3 -flto=thin ${XL_TARGETS} ${OSX_VERSION_MIN} "
./configure --disable-shared --enable-static --disable-render-metal --disable-video-metal --disable-video-dummy  --disable-video-x11 --disable-video-opengles --disable-video-opengles2 --disable-video-vulkan --disable-haptic --disable-joystick --prefix=/opt/local
make clean
make -j $NUM_CPUS
cp ./build/.libs/libSDL2.a /opt/local/lib
export CXXFLAGS="-g ${XL_TARGETS} ${OSX_VERSION_MIN} "
export CFLAGS="-g ${XL_TARGETS} ${OSX_VERSION_MIN} "
export LDFLAGS="-g ${XL_TARGETS} ${OSX_VERSION_MIN} "
./configure --disable-shared --enable-static --disable-render-metal --disable-video-metal --disable-video-dummy  --disable-video-x11 --disable-video-opengles --disable-video-opengles2 --disable-video-vulkan --disable-haptic --disable-joystick --prefix=/opt/local
make clean
make -j $NUM_CPUS
cp ./build/.libs/libSDL2.a /opt/local/libdbg
unset CXXFLAGS
unset CFLAGS
unset LDFLAGS
popd

echo "ffmpeg"   # currently using 6.1.2
# Note: requires nasm to be install.   Easiest option is via "brew install nasm"
if [ ! -d "ffmpeg" ] ; then git clone https://git.ffmpeg.org/ffmpeg.git ; fi
pushd ffmpeg
git fetch -v
git checkout n6.1.2
make clean || true    # can exit nonzero
rm -rf x86_64
git status --ignored -s | colrm 1 2 | xargs rm -rf
./configure --disable-inline-asm --enable-static --disable-shared --disable-securetransport --extra-cflags="${OSX_VERSION_MIN}" --disable-indev=lavfi --disable-libx264 --disable-lzma --enable-gpl --enable-opengl --disable-programs --arch=x86_64
sed -i -e "s/^CFLAGS=/CFLAGS=-g ${X86_64_TARGETS} ${OSX_VERSION_MIN} -DGL_SILENCE_DEPRECATION=1 -Wno-incompatible-function-pointer-types /" ffbuild/config.mak
sed -i -e "s/^CXXFLAGS=/CXXFLAGS=-g ${X86_64_TARGETS} ${OSX_VERSION_MIN} -DGL_SILENCE_DEPRECATION=1 /" ffbuild/config.mak
sed -i -e "s/^LDFLAGS=/LDFLAGS=-g ${X86_64_TARGETS} ${OSX_VERSION_MIN} /" ffbuild/config.mak
make -j $NUM_CPUS ; make
mkdir ./x86_64
find . -name "*.a" -exec cp -f {} ./x86_64 \;
make clean || true    # can exit nonzero
git status --ignored -s | colrm 1 2  | grep -v x86_64 | xargs rm -rf
./configure --enable-static --disable-shared --disable-securetransport --extra-cflags="${OSX_VERSION_MIN}" --disable-indev=lavfi --disable-libx264 --disable-lzma --enable-gpl --enable-opengl --disable-programs --arch=arm64
sed -i -e "s/^CFLAGS=/CFLAGS=-g ${ARM64_TARGETS} ${OSX_VERSION_MIN} -DGL_SILENCE_DEPRECATION=1 -Wno-incompatible-function-pointer-types /" ffbuild/config.mak
sed -i -e "s/^CXXFLAGS=/CXXFLAGS=-g ${ARM64_TARGETS} ${OSX_VERSION_MIN} -DGL_SILENCE_DEPRECATION=1 /" ffbuild/config.mak
sed -i -e "s/^LDFLAGS=/LDFLAGS=-g ${ARM64_TARGETS} ${OSX_VERSION_MIN} /" ffbuild/config.mak
make -j $NUM_CPUS ; make
lipo -create -output /opt/local/lib/libavutil.a ./libavutil/libavutil.a ./x86_64/libavutil.a
lipo -create -output /opt/local/lib/libavfilter.a ./libavfilter/libavfilter.a ./x86_64/libavfilter.a
lipo -create -output /opt/local/lib/libavcodec.a ./libavcodec/libavcodec.a ./x86_64/libavcodec.a
lipo -create -output /opt/local/lib/libpostproc.a ./libpostproc/libpostproc.a ./x86_64/libpostproc.a
lipo -create -output /opt/local/lib/libavformat.a ./libavformat/libavformat.a ./x86_64/libavformat.a
lipo -create -output /opt/local/lib/libavdevice.a ./libavdevice/libavdevice.a ./x86_64/libavdevice.a
lipo -create -output /opt/local/lib/libswresample.a ./libswresample/libswresample.a ./x86_64/libswresample.a
lipo -create -output /opt/local/lib/libswscale.a ./libswscale/libswscale.a ./x86_64/libswscale.a
make clean || true    # can exit nonzero
git status --ignored -s  | colrm 1 2 | xargs rm  -rf
./configure --disable-asm --disable-x86asm --enable-static --disable-shared --disable-securetransport --extra-cflags="${OSX_VERSION_MIN}" --disable-indev=lavfi --disable-libx264 --disable-lzma --enable-gpl --enable-opengl --disable-programs --disable-optimizations
sed -i -e "s/^CFLAGS=/CFLAGS=-g ${XL_TARGETS} ${OSX_VERSION_MIN} -DGL_SILENCE_DEPRECATION=1 -Wno-incompatible-function-pointer-types /" ffbuild/config.mak
sed -i -e "s/^CXXFLAGS=/CXXFLAGS=-g ${XL_TARGETS} ${OSX_VERSION_MIN} -DGL_SILENCE_DEPRECATION=1 /" ffbuild/config.mak
sed -i -e "s/^LDFLAGS=/LDFLAGS=-g ${XL_TARGETS} ${OSX_VERSION_MIN} /" ffbuild/config.mak
make -j $NUM_CPUS ; make
find . -name "*.a" -exec cp {} /opt/local/libdbg/ \;
popd

echo "libxslxwriter"
if [ ! -d "libxlsxwriter" ] ; then git clone https://github.com/jmcnamara/libxlsxwriter.git ; fi
pushd libxlsxwriter
git checkout v1.1.9
cd cmake
export CXXFLAGS="-g -O3 -flto=thin ${XL_TARGETS} ${OSX_VERSION_MIN} "
export CFLAGS="-g -O3 -flto=thin ${XL_TARGETS} ${OSX_VERSION_MIN} "
export LDFLAGS="-g -O3 -flto=thin ${XL_TARGETS} ${OSX_VERSION_MIN} "
cmake -DCMAKE_OSX_ARCHITECTURES="x86_64;arm64" ..
make
cp libxlsxwriter.a /opt/local/lib/
git status --ignored -s | colrm 1 3 | xargs rm -rf
export CXXFLAGS="-g ${XL_TARGETS} ${OSX_VERSION_MIN} "
export CFLAGS="-g ${XL_TARGETS} ${OSX_VERSION_MIN} "
export LDFLAGS="-g ${XL_TARGETS} ${OSX_VERSION_MIN} "
cmake -DCMAKE_OSX_ARCHITECTURES="x86_64;arm64" ..
make
cp libxlsxwriter.a /opt/local/libdbg/
cp -a ../include/* /opt/local/include
make  clean
git status --ignored -s | colrm 1 3 | xargs rm -rf
unset CXXFLAGS
unset CFLAGS
unset LDFLAGS
popd


echo "liblua"   # currently using v5.4.7
if [ ! -d "liblua" ] ; then git clone https://github.com/lua/lua ; fi
pushd lua
git fetch -v
git checkout v5.4.7
make clean
export CFLAGS="-g -O3 -flto=thin -Wall -fno-stack-protector -fno-common ${XL_TARGETS} ${OSX_VERSION_MIN} "
make -j $NUM_CPUS all CFLAGS="$CFLAGS" MYLDFLAGS="$CFLAGS"
cp liblua.a /opt/local/lib
cp lua.h luaconf.h lualib.h lauxlib.h /opt/local/include
make clean
export CFLAGS="-g ${XL_TARGETS} ${OSX_VERSION_MIN} "
make -j $NUM_CPUS all CFLAGS="$CFLAGS" MYLDFLAGS="$CFLAGS"
cp liblua.a /opt/local/libdbg
unset CFLAGS
popd

echo "libhidapi"   # currently using 0.14.0
if [ ! -d "hidapi" ] ; then git clone https://github.com/libusb/hidapi ; fi
pushd hidapi
git fetch -v
git checkout hidapi-0.14.0
export CFLAGS="-g -O3 -flto=thin -Wall -fno-stack-protector -fno-common ${XL_TARGETS} ${OSX_VERSION_MIN} "
./bootstrap
./configure --prefix=/opt/local
make clean
make
cp ./mac/.libs/libhidapi.a /opt/local/lib
make clean
export CFLAGS="-g -Wall -fno-stack-protector -fno-common ${XL_TARGETS} ${OSX_VERSION_MIN} "
./configure --prefix=/opt/local
make
rm -f /opt/local/libdbg/libhidapi*
cp ./mac/.libs/libhidapi.a /opt/local/libdbg
make clean
unset CFLAGS
popd

echo "libwebp"    # currently using v1.4.0
if [ ! -d "libwebp" ] ; then git clone https://chromium.googlesource.com/webm/libwebp ; fi
pushd libwebp
git fetch -v
git checkout v1.4.0
./autogen.sh
export CFLAGS="-g -O3 -flto=thin -Wall -fno-stack-protector -fno-common ${XL_TARGETS} ${OSX_VERSION_MIN} "
./configure --prefix=/opt/local --disable-shared
make clean
make -j $NUM_CPUS
cp ./src/.libs/libwebp.a /opt/local/lib
cp ./src/demux/.libs/libwebpdemux.a  /opt/local/lib
cp ./sharpyuv/.libs/libsharpyuv.a /opt/local/lib
make clean
export CFLAGS="-g -Wall -fno-stack-protector -fno-common ${XL_TARGETS} ${OSX_VERSION_MIN} "
./configure --prefix=/opt/local --disable-shared
make -j $NUM_CPUS
cp ./src/.libs/libwebp.a /opt/local/libdbg
cp ./src/demux/.libs/libwebpdemux.a  /opt/local/libdbg
cp ./sharpyuv/.libs/libsharpyuv.a /opt/local/libdbg
unset CFLAGS
popd
echo "Libraries built"
ls -ltR /opt/local
