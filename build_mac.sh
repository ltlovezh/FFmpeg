#!/bin/bash

export PREFIX=$(pwd)/mac
echo "PREFIX : ${PREFIX}"

./configure  \
    --prefix=${PREFIX} \
    --enable-gpl \
    --enable-nonfree \
    --cc=/usr/bin/clang \
    --cxx=/usr/bin/clang \
    --enable-shared \
    --enable-avresample \
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

make clean
make -j8
make install