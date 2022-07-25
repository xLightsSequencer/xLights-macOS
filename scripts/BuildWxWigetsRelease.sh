#!/bin/bash

echo "Changing Dir..."
cd ../../..
echo "$PWD"
cd wxWidgets/build/

echo "Configure..."
echo "$PWD"

export BINARY_PLATFORMS="x86_64,arm64"
export CXXFLAGS=""
export OBJCXXFLAGS=""
export CPPFLAGS="-g  -flto=thin"
export LDFLAGS="-flto=thin"
export CXX=clang++ 
export CXXCPP="clang++ -E" 
export CC=clang 
export CPP="clang -E" 
export CFLAGS="-g"
../configure  --disable-debug_flag --enable-debug_info --enable-optimise --prefix=/opt/local --enable-universal_binary=${BINARY_PLATFORMS} \
                --with-osx_cocoa --with-macosx-version-min=10.14 --disable-dependency-tracking \
                --disable-compat30  --enable-mimetype --enable-aui --with-opengl \
                --enable-webview --enable-webviewwebkit --disable-mdi --disable-mdidoc --disable-loggui \
                --disable-xrc --disable-stc --disable-ribbon --disable-htmlhelp --disable-mediactrl \
                --with-cxx=17 --enable-cxx11 --enable-std_containers --enable-std_string --enable-std_string_conv_in_wxstring \
                --without-liblzma  --with-expat=builtin --with-zlib=builtin --with-libjpeg=builtin  --without-libtiff \
                --disable-sys-libs \
                --enable-backtrace --enable-exceptions --disable-shared
echo "Make..."
make -j 8
rm -rf /opt/local/lib/libwx*.dylib
echo "Install..."
make install
echo "Done"