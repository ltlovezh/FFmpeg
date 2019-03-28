#!/bin/bash

export PREFIX=$(pwd)/mac
echo "PREFIX : ${PREFIX}"

./configure  \
    --prefix=${PREFIX} \
    --enable-gpl \
    --enable-nonfree \
    --enable-libass \
    --enable-libfdk-aac \
    --enable-libfreetype \
    --enable-libmp3lame \
    --enable-libtheora \
    --enable-libvorbis \
    --enable-libvpx \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libopus \
    --enable-libxvid \
    --samples=fate-suite \
    --extra-ldflags="-L/usr/local/lib \
    -L/usr/local/Cellar/libogg/1.3.3/lib \
    -L/usr/local/Cellar/theora/1.1.1/lib \
    -L/usr/local/Cellar/libvorbis/1.3.6/lib" \
    --extra-cflags="-I/usr/local/include \
    -I/usr/local/Cellar/libogg/1.3.3/include \
    -I/usr/local/Cellar/theora/1.1.1/include \
    -I/usr/local/Cellar/libvorbis/1.3.5/include"

make clean
make -j8
make install