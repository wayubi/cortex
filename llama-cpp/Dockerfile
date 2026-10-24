# Shared by every llama.cpp router (compose.yml):
#   llama-build        upstream ggml-org/llama.cpp @ a b* tag        → llama-cpp:latest
#   prism-llama-build  PrismML-Eng/llama.cpp @ a prism-b* tag        → prism-llama-cpp:latest
#   flint-llama-build  upstream ggml-org/llama.cpp @ a b* tag        → flint-llama-cpp:latest
#   raon-llama-build   krafton-ai/llama.cpp raon-1-mini-preview @ SHA → raon-llama-cpp:latest
# The PrismML fork (ternary PQ2_0 / PTQ1_0 types, Hadamard runtime) is built from
# its `prism` branch at a pinned release tag; its `master` is a stale upstream mirror.
# A fork without release tags is pinned by LLAMA_COMMIT (a full SHA on LLAMA_REF).
FROM nvidia/cuda:12.4.0-devel-ubuntu22.04 AS builder

ARG BUILD_JOBS=6
ARG LLAMA_REPO=https://github.com/ggml-org/llama.cpp.git
ARG LLAMA_REF=master
# Optional: build this exact commit of LLAMA_REF (for a branch with no tags)
ARG LLAMA_COMMIT=
# 86 = RTX 3060. Empty builds llama.cpp's default architecture list (slower).
ARG CUDA_ARCH=86
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        git cmake build-essential libcurl4-openssl-dev libssl-dev curl \
        wget gnupg2 ca-certificates libcurl4 libgomp1 && \
    rm -f /etc/apt/sources.list.d/cuda*.list && \
    wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb && \
    dpkg -i cuda-keyring_1.1-1_all.deb && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        libnccl2=2.20.5-1+cuda12.4 && \
    ldconfig && \
    rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch ${LLAMA_REF} ${LLAMA_REPO} /tmp/llama-cpp-build \
    && if [ -n "${LLAMA_COMMIT}" ]; then \
         git -C /tmp/llama-cpp-build fetch --depth 1 origin ${LLAMA_COMMIT} \
         && git -C /tmp/llama-cpp-build checkout --detach FETCH_HEAD; \
       fi \
    && git -C /tmp/llama-cpp-build log -1 --format='built from %H (%cd)'

WORKDIR /tmp/llama-cpp-build

# Set up CUDA driver stub for linking
RUN ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1 && \
    ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/libcuda.so.1 && \
    ldconfig

ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64/stubs:/usr/local/cuda/lib64:${LD_LIBRARY_PATH}

RUN rm -rf build

# Build with CUDA + flash attention + MTP support
# Note: LLAMA_CUDA → GGML_CUDA in recent llama.cpp
RUN rm -rf build && cmake -B build \
        -DGGML_CUDA=ON \
        ${CUDA_ARCH:+-DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH}} \
        -DGGML_CUDA_FA=ON \
        -DGGML_CUDA_FA_ALL_QUANTS=ON \
        -DGGML_NCCL=OFF \
        -DLLAMA_CURL=ON \
        -DCMAKE_C_FLAGS="-DGGML_NCCL=0" \
        -DCMAKE_CXX_FLAGS="-DGGML_NCCL=0" \
        -DCMAKE_EXE_LINKER_FLAGS="-L/usr/local/cuda/lib64/stubs -Wl,-rpath,/usr/local/cuda/lib64" \
    && cmake --build build --config Release -j${BUILD_JOBS} -- llama-server

# ──────────────────────────────────────────────
# Stage 2: Runtime
# ──────────────────────────────────────────────
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        libcurl4 libgomp1 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /tmp/llama-cpp-build/build/bin/ /usr/local/lib/
COPY --from=builder /usr/local/cuda/lib64/libcudart.so* /usr/local/lib/
COPY --from=builder /usr/local/cuda/lib64/libcublas.so* /usr/local/lib/
COPY --from=builder /usr/local/cuda/lib64/libcublasLt.so* /usr/local/lib/
COPY --from=builder /usr/lib/x86_64-linux-gnu/libnccl.so* /usr/local/lib/

RUN ldconfig

COPY --from=builder /tmp/llama-cpp-build/build/bin/llama-server /usr/local/bin/llama-server

RUN mkdir -p /root/.cache/huggingface/hub
EXPOSE 8080
ENTRYPOINT ["llama-server"]
