#!/bin/bash
# egpu-stress.sh — install and run CUDA stress/diag tools for eGPU validation
#
# Tools (all compute-only — no OpenGL/Vulkan/X11 dependency):
#   - deviceQuery   verify CUDA enumerates the GPU (SM count, VRAM, capabilities)
#   - bw            minimal H↔D / D↔H / D↔D bench (custom, ~30 LoC of CUDA)
#                   — replaces cuda-samples bandwidthTest which was removed
#                   from the official repo in 2025
#   - gpu-burn      sustained full-load compute (CUBLAS GEMM), optionally with
#                   VRAM corruption check (triggers Xid 79 if the link is flaky)
#
# Everything is built under ~/.local/share/egpu-tools/, zero system install.
#
# Usage:
#   ./egpu-stress.sh install         clone + build (idempotent)
#   ./egpu-stress.sh query           run deviceQuery
#   ./egpu-stress.sh bandwidth       run the bandwidth bench (bw)
#   ./egpu-stress.sh burn [SECS]     gpu-burn SECS seconds (default 60)
#   ./egpu-stress.sh burn-mem [SECS] gpu-burn -d (compute + VRAM corruption check)
#   ./egpu-stress.sh all [BURN_SECS] query + bandwidth + short burn (default 30s)
#   ./egpu-stress.sh clean           rm -rf the install dir

set -euo pipefail

DEST="$HOME/.local/share/egpu-tools"
CUDA_SAMPLES_REPO="https://github.com/NVIDIA/cuda-samples.git"
GPU_BURN_REPO="https://github.com/wilicc/gpu-burn.git"

DEV_Q="$DEST/cuda-samples/build/cpp/1_Utilities/deviceQuery/deviceQuery"
BW_T="$DEST/bw"
BW_SRC="$DEST/bw.cu"
GPU_B_DIR="$DEST/gpu-burn"
GPU_B="$GPU_B_DIR/gpu_burn"

usage() { sed -n '2,19p' "$0"; }

ensure_tools() {
    local missing=()
    for c in nvcc cmake make git; do
        command -v "$c" &>/dev/null || missing+=("$c")
    done
    if (( ${#missing[@]} )); then
        echo "Missing tools: ${missing[*]}" >&2
        echo "Ensure /usr/local/cuda/bin is in PATH for nvcc, and install cmake/make/git via your distro." >&2
        exit 1
    fi
}

# nvcc bundled in CUDA 13 currently caps host gcc at 15. Fedora 44 ships gcc 16+.
# When the system gcc is newer than what nvcc's host_config.h accepts, we use
# nvcc's own escape hatch (--allow-unsupported-compiler) which propagates to all
# child nvcc invocations via NVCC_PREPEND_FLAGS.
setup_nvcc_compat() {
    local gcc_major
    gcc_major=$(gcc -dumpfullversion 2>/dev/null | cut -d. -f1)
    if [[ -n "$gcc_major" && "$gcc_major" -gt 15 ]]; then
        export NVCC_PREPEND_FLAGS="${NVCC_PREPEND_FLAGS:-} --allow-unsupported-compiler"
        echo "[*] GCC $gcc_major detected (> 15): enabling --allow-unsupported-compiler for nvcc"
    fi
}

install_cuda_samples() {
    # cuda-samples is only used for deviceQuery now. bandwidthTest was removed
    # from the repo in 2025 — we ship our own minimal bench (bw.cu).
    local dir="$DEST/cuda-samples"
    if [[ ! -d "$dir/.git" ]]; then
        echo "[*] Cloning cuda-samples (shallow)..."
        git clone --depth 1 "$CUDA_SAMPLES_REPO" "$dir"
    else
        echo "[*] cuda-samples already cloned"
    fi

    if [[ ! -x "$DEV_Q" ]]; then
        echo "[*] Configuring cuda-samples (Release)..."
        cmake -S "$dir" -B "$dir/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
        echo "[*] Building deviceQuery..."
        cmake --build "$dir/build" --target deviceQuery -j
    else
        echo "[*] deviceQuery already built"
    fi
}

install_bw() {
    # Embedded minimal H↔D bandwidth bench. Pure CUDA Runtime API, ~50 LoC,
    # builds in 2 seconds. Replaces the removed cuda-samples bandwidthTest.
    if [[ ! -f "$BW_SRC" ]]; then
        echo "[*] Writing bw.cu (custom bandwidth bench)..."
        cat > "$BW_SRC" <<'EOF'
// bw.cu — minimal H<->D PCIe bandwidth bench (compute-only, no GL/X11)
#include <cuda_runtime.h>
#include <stdio.h>
#include <chrono>

static double secs_since(std::chrono::high_resolution_clock::time_point t0) {
    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double>(t1 - t0).count();
}

int main() {
    const size_t N = 256ull * 1024 * 1024;  // 256 MiB transfer
    const int reps = 16;
    void *h_buf = nullptr, *d_buf = nullptr;
    cudaError_t err;

    if ((err = cudaMallocHost(&h_buf, N)) != cudaSuccess) {
        fprintf(stderr, "cudaMallocHost: %s\n", cudaGetErrorString(err)); return 1;
    }
    if ((err = cudaMalloc(&d_buf, N)) != cudaSuccess) {
        fprintf(stderr, "cudaMalloc: %s\n", cudaGetErrorString(err)); return 1;
    }

    // Warmup
    cudaMemcpy(d_buf, h_buf, N, cudaMemcpyHostToDevice);
    cudaDeviceSynchronize();

    double gib = (double)N * reps / (1024.0 * 1024.0 * 1024.0);

    auto t0 = std::chrono::high_resolution_clock::now();
    for (int i = 0; i < reps; i++)
        cudaMemcpy(d_buf, h_buf, N, cudaMemcpyHostToDevice);
    cudaDeviceSynchronize();
    double s_h2d = secs_since(t0);

    t0 = std::chrono::high_resolution_clock::now();
    for (int i = 0; i < reps; i++)
        cudaMemcpy(h_buf, d_buf, N, cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();
    double s_d2h = secs_since(t0);

    t0 = std::chrono::high_resolution_clock::now();
    for (int i = 0; i < reps; i++)
        cudaMemcpy(d_buf, d_buf, N, cudaMemcpyDeviceToDevice);
    cudaDeviceSynchronize();
    double s_d2d = secs_since(t0);

    printf("Transfer size: %zu MiB x %d reps (%.2f GiB total per direction)\n",
           N / (1024 * 1024), reps, gib);
    printf("H -> D  (pinned): %7.2f GiB/s   [PCIe up]\n",   gib / s_h2d);
    printf("D -> H  (pinned): %7.2f GiB/s   [PCIe down]\n", gib / s_d2h);
    printf("D -> D           : %7.2f GiB/s   [VRAM]\n",     gib / s_d2d);

    cudaFree(d_buf);
    cudaFreeHost(h_buf);
    return 0;
}
EOF
    fi
    if [[ ! -x "$BW_T" ]]; then
        echo "[*] Building bw (custom bandwidth bench)..."
        nvcc -O2 -o "$BW_T" "$BW_SRC"
    else
        echo "[*] bw already built"
    fi
}

install_gpu_burn() {
    if [[ ! -d "$GPU_B_DIR/.git" ]]; then
        echo "[*] Cloning gpu-burn..."
        git clone --depth 1 "$GPU_BURN_REPO" "$GPU_B_DIR"
    else
        echo "[*] gpu-burn already cloned"
    fi
    if [[ ! -x "$GPU_B" ]]; then
        echo "[*] Building gpu-burn..."
        (cd "$GPU_B_DIR" && make)
    else
        echo "[*] gpu-burn already built"
    fi
}

install_all() {
    ensure_tools
    setup_nvcc_compat
    mkdir -p "$DEST"
    install_cuda_samples
    install_bw
    install_gpu_burn

    # Sanity check: no display libs linked.
    for bin in "$DEV_Q" "$BW_T" "$GPU_B"; do
        [[ -x "$bin" ]] || continue
        if ldd "$bin" 2>/dev/null | grep -qiE 'libGL\.|libEGL|libX11'; then
            echo "[!] WARNING: $bin links to display libs — unexpected" >&2
        fi
    done

    echo ""
    echo "[✓] Tools installed in $DEST"
    echo "    Try: $0 query   |   $0 bandwidth   |   $0 burn 60"
}

need_installed() {
    [[ -x "$1" ]] || {
        echo "Not installed. Run: $0 install" >&2
        exit 1
    }
}

run_query()     { need_installed "$DEV_Q"; "$DEV_Q"; }
run_bandwidth() { need_installed "$BW_T";  "$BW_T"; }

run_burn() {
    need_installed "$GPU_B"
    local secs="${1:-60}"
    # gpu-burn loads compare.ptx via relative path → must run from its dir.
    (cd "$GPU_B_DIR" && ./gpu_burn "$secs")
}

run_burn_mem() {
    need_installed "$GPU_B"
    local secs="${1:-60}"
    (cd "$GPU_B_DIR" && ./gpu_burn -d "$secs")
}

cmd="${1:-}"
case "$cmd" in
    install)   install_all ;;
    query)     run_query ;;
    bandwidth) run_bandwidth ;;
    burn)      run_burn "${2:-60}" ;;
    burn-mem)  run_burn_mem "${2:-60}" ;;
    all)
        secs="${2:-30}"
        echo "==== deviceQuery ===="
        run_query
        echo ""
        echo "==== bandwidth ===="
        run_bandwidth
        echo ""
        echo "==== gpu-burn ${secs}s ===="
        run_burn "$secs"
        ;;
    clean)     rm -rf "$DEST"; echo "[✓] Cleaned $DEST" ;;
    -h|--help|"") usage ;;
    *) echo "Unknown command: $cmd" >&2; usage; exit 1 ;;
esac
