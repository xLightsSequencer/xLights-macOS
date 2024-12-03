#!/bin/bash -e
# System dependency checks...
if [ ! -d /opt/local ] || [ ! -d /opt/local/libdbg ] || [ ! -d /opt/local/bin ] ; then
  echo "/opt/local/lib, /opt/local/libdbg and /opt/local/include must exist and be writable!"
  exit 1
fi

if [ ! -e "wx-config.in" ] ; then
  # We are not inside of the wxWidgets source tree
  echo "Changing Dir to ../../../wxWidgets"
  cd ../../..
  echo "$PWD"
  cd wxWidgets
fi

export NUM_CPUS="${NUM_CPUS:-$(sysctl -n hw.ncpu)}"
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-11.0}
export BINARY_PLATFORMS="x86_64,arm64"
export CXXFLAGS=""
export OBJCXXFLAGS=""
export CPPFLAGS="-g -flto=thin"
export LDFLAGS="-g -flto=thin"
export CXX=clang++
export CXXCPP="clang++ -E"
export CC=clang
export CPP="clang -E"
export CFLAGS="-g"
set -x    # prints all executed commands from now on
mkdir -p build
cd build
../configure  --disable-debug_flag --enable-debug_info --enable-optimise --prefix=/opt/local --enable-universal_binary=${BINARY_PLATFORMS} \
              --with-osx_cocoa --with-macosx-version-min=${MACOSX_DEPLOYMENT_TARGET} --disable-dependency-tracking \
              --disable-compat30  --enable-mimetype --enable-aui --with-opengl \
              --enable-webview --enable-webviewwebkit --disable-mdi --disable-mdidoc --disable-loggui \
              --disable-xrc --disable-stc --disable-ribbon --disable-htmlhelp --disable-mediactrl \
              --with-cxx=17 --enable-cxx11 --enable-std_containers --enable-std_string_conv_in_wxstring \
              --without-liblzma  --with-expat=builtin --with-zlib=builtin --with-libjpeg=builtin  --without-libtiff \
              --disable-sys-libs \
              --enable-backtrace --enable-exceptions --disable-shared
make -j $NUM_CPUS
rm -rf /opt/local/lib/libwx*.dylib
make install

echo "Done"
