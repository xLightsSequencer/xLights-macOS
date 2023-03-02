sudo mkdir -p /opt/local/lib
sudo mkdir -p /opt/local/bin

#setup permissions on /opt/local
sudo chgrp -R staff /opt/local*
sudo chmod -R g+w /opt/local*

export MACOSX_DEPLOYMENT_TARGET=10.14
export OSX_VERSION_MIN="-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
export ARM64_TARGETS="-target arm64-apple-macos10.14 -arch arm64"
export X86_64_TARGETS="-target x86_64-apple-macos10.14 -arch x86_64"

#need ONE of these lines
export XL_TARGETS="${X86_64_TARGETS} ${ARM64_TARGETS}"
# export XL_TARGETS="${X86_64_TARGETS}"
# export XL_TARGETS="${ARM64_TARGETS}"

# need ONE of these
# export BUILD_HOST=x86_64
export BUILD_HOST=arm

#Note: Some libraries require Homebrew Tools, to install Homebrew:
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

#Autotools and LibTool are required from Homebrew:
brew install automake libtool cmake nasm

echo "libzstd"
git clone https://github.com/facebook/zstd
cd zstd
git checkout v1.5.2
export CFLAGS="-g -flto=thin  ${OSX_VERSION_MIN} ${XL_TARGETS}"
export LDFLAGS="-flto=thin  ${OSX_VERSION_MIN} ${XL_TARGETS} "
make clean
make -j 8 HAVE_LZMA=0 HAVE_LZ4=0 lib-mt
cp lib/libzstd.a /opt/local/lib
unset CFLAGS
unset LDFLAGS

echo "log4cpp"
#Download latest src release (current 1.1.3)
wget https://nchc.dl.sourceforge.net/project/log4cpp/log4cpp-1.1.x%20%28new%29/log4cpp-1.1/log4cpp-1.1.3.tar.gz
tar -xzf log4cpp-1.1.3.tar.gz
cd log4cpp
patch -p1 < ~/working/xLights/macOS/patches/log4cpp.patch
export CXXFLAGS="-g -O2 -flto=thin ${OSX_VERSION_MIN} ${XL_TARGETS} -std=c++11 -stdlib=libc++ -fvisibility-inlines-hidden"
export LDFLAGS="-flto=thin ${XL_TARGETS} "
./configure --prefix=/opt/local -host ${BUILD_HOST}
make clean
make -j 8
cp src/.libs/liblog4cpp.a /opt/local/lib
unset CXXFLAGS
unset LDFLAGS


echo "liquidfun"
# requires cmake to be installed, most likely need to have
# homebrew installed and then "brew install cmake"
# aternatively, install CMAKE for OSX from https://cmake.org/download/
# and add the full path to cmake to PATH
# PATH=$PATH:/Applications/CMake.app/Contents/bin/
git clone https://github.com/google/liquidfun
cd liquidfun/liquidfun/Box2D
git status --ignored -s | colrm 1 2 | xargs rm -rf
export CXX=clang++
export CXXFLAGS="-g -O3 -flto=thin ${XL_TARGETS} ${OSX_VERSION_MIN}"
cmake -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release -DBOX2D_BUILD_EXAMPLES=OFF
make clean
make -j 8
cp ./Box2D/Release/libliquidfun.a /opt/local/lib
unset CXXFLAGS
unset CXX


echo "SDL2"  #currently using 2.0.22
git clone https://github.com/libsdl-org/SDL
cd SDL
git reset --hard
git checkout release-2.0.22
export CXXFLAGS="-g -O3 -flto=thin ${XL_TARGETS} ${OSX_VERSION_MIN}"
export CFLAGS="-g -O3 -flto=thin ${XL_TARGETS} ${OSX_VERSION_MIN}"
export LDFLAGS="-g -O3 -flto=thin ${XL_TARGETS} ${OSX_VERSION_MIN}"
./configure --disable-shared --enable-static --disable-render-metal --disable-video-metal --disable-video-dummy --disable-video-opengl --disable-video-opengles --disable-video-opengles2 --disable-video-vulkan --disable-haptic --disable-joystick
make clean
make -j 8
cp ./build/.libs/libSDL2.a /opt/local/lib
unset CXXFLAGS
unset CFLAGS
unset LDFLAGS


echo "ffmpeg"   #currently using 6.0
# Note: requires nasm to be install.   Easiest option is via "brew install nasm"
git clone https://git.ffmpeg.org/ffmpeg.git
cd ffmpeg
git checkout n6.0
make clean
./configure --disable-inline-asm --enable-static --disable-shared --disable-securetransport --extra-cflags="${OSX_VERSION_MIN}" --disable-indev=lavfi --disable-libx264 --disable-lzma --enable-gpl --enable-opengl --disable-programs --arch=x86_64
sed -i -e "s/^CFLAGS=/CFLAGS=-g ${X86_64_TARGETS} ${OSX_VERSION_MIN} /" ffbuild/config.mak
sed -i -e "s/^CXXFLAGS=/CXXFLAGS=-g ${X86_64_TARGETS} ${OSX_VERSION_MIN} /" ffbuild/config.mak
sed -i -e "s/^LDFLAGS=/LDFLAGS=-g ${X86_64_TARGETS} ${OSX_VERSION_MIN} /" ffbuild/config.mak
make -j 16
mkdir ./x86_64
find . -name "*.a" -exec cp {} ./x86_64 \;
make clean
./configure --disable-inline-asm --enable-static --disable-shared --disable-securetransport --extra-cflags="${OSX_VERSION_MIN}" --disable-indev=lavfi --disable-libx264 --disable-lzma --enable-gpl --enable-opengl --disable-programs --arch=arm64
sed -i -e "s/^CFLAGS=/CFLAGS=-g ${ARM64_TARGETS} ${OSX_VERSION_MIN} /" ffbuild/config.mak
sed -i -e "s/^CXXFLAGS=/CXXFLAGS=-g ${ARM64_TARGETS} ${OSX_VERSION_MIN} /" ffbuild/config.mak
sed -i -e "s/^LDFLAGS=/LDFLAGS=-g ${ARM64_TARGETS} ${OSX_VERSION_MIN} /" ffbuild/config.mak
make -j 16
lipo -create -output /opt/local/lib/libavutil.a ./libavutil/libavutil.a ./x86_64/libavutil.a
lipo -create -output /opt/local/lib/libavfilter.a ./libavfilter/libavfilter.a ./x86_64/libavfilter.a
lipo -create -output /opt/local/lib/libavcodec.a ./libavcodec/libavcodec.a ./x86_64/libavcodec.a
lipo -create -output /opt/local/lib/libpostproc.a ./libpostproc/libpostproc.a ./x86_64/libpostproc.a
lipo -create -output /opt/local/lib/libavformat.a ./libavformat/libavformat.a ./x86_64/libavformat.a
lipo -create -output /opt/local/lib/libavdevice.a ./libavdevice/libavdevice.a ./x86_64/libavdevice.a
lipo -create -output /opt/local/lib/libswresample.a ./libswresample/libswresample.a ./x86_64/libswresample.a
lipo -create -output /opt/local/lib/libswscale.a ./libswscale/libswscale.a ./x86_64/libswscale.a

echo "libxslwriter"
git clone https://github.com/jmcnamara/libxlsxwriter.git
cd libxlsxwriter/cmake
export CXXFLAGS="-g -O3 -flto=thin ${XL_TARGETS} ${OSX_VERSION_MIN}"
export CFLAGS="-g -O3 -flto=thin ${XL_TARGETS} ${OSX_VERSION_MIN}"
export LDFLAGS="-g -O3 -flto=thin ${XL_TARGETS} ${OSX_VERSION_MIN}"
cmake -DCMAKE_OSX_ARCHITECTURES="x86_64;arm64" ..
make
cp libxlsxwriter.a /opt/local/lib/
git status --ignored -s | colrm 1 3 | xargs rm -rf
make  clean
git status --ignored -s | colrm 1 3 | xargs rm -rf

echo "liblua" #(currently using v5.4.4)
git clone https://github.com/lua/lua
cd lua
git checkout v5.4.4
make clean
export CFLAGS="-g -O3 -flto=thin -Wall -fno-stack-protector -fno-common ${XL_TARGETS} ${OSX_VERSION_MIN}"
make -j4 all CFLAGS="$CFLAGS" MYLDFLAGS="$CFLAGS"
cp liblua.a /opt/local/lib
cp lua.h luaconf.h lualib.h lauxlib.h /opt/local/include
unset CFLAGS

echo "libhidapi" #(currently using 0.11.2)
git clone https://github.com/libusb/hidapi
cd hidapi
git checkout hidapi-0.11.2
export CFLAGS="-g -O3 -flto=thin -Wall -fno-stack-protector -fno-common ${XL_TARGETS} ${OSX_VERSION_MIN}"
./bootstrap
./configure --prefix=/opt/local
make clean
make
cp ./mac/.libs/libhidapi.a /opt/local/lib
make clean

echo "done"
