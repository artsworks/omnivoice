#!/bin/bash

rm -rf build
mkdir build
cd build

cmake .. -DGGML_CUDA=ON -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DCMAKE_CUDA_ARCHITECTURES=75 -DCMAKE_CUDA_ARCHITECTURES_NATIVE=OFF
cmake --build . --config Release -j "$(getconf _NPROCESSORS_ONLN)"
