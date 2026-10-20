#include "Vfftifftmain.h"
#include "verilated.h"
#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

using Complex = std::complex<double>;
constexpr unsigned N = 4096;
static void edge(Vfftifftmain &d) {
    d.i_clk = 0; d.eval(); d.i_clk = 1; d.eval();
    d.i_clk = 0; d.eval();
}
static uint32_t pack(Complex x) {
    return (uint32_t(uint16_t(int(x.real()))) << 16)
        | uint16_t(int(x.imag()));
}
static int32_t signed23(uint64_t x) {
    uint32_t y = x & 0x7fffff;
    return (y & 0x400000) ? int32_t(y) - 0x800000 : int32_t(y);
}
static Complex unpack(uint64_t x) {
    return Complex(signed23(x >> 23), signed23(x));
}
static std::vector<Complex> reference(std::vector<Complex> x, bool inverse) {
    for (unsigned i = 1, j = 0; i < N; ++i) {
        unsigned bit = N >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(x[i], x[j]);
    }
    for (unsigned len = 2; len <= N; len <<= 1) {
        auto root = std::polar(1.0, (inverse ? 2 : -2) * std::acos(-1.0) / len);
        for (unsigned i = 0; i < N; i += len) {
            Complex w = 1;
            for (unsigned j = 0; j < len / 2; ++j) {
                auto a = x[i+j], b = w * x[i+j+len/2];
                x[i+j] = a+b; x[i+j+len/2] = a-b; w *= root;
            }
        }
    }
    // This generated fixed-point datapath drops five bits across 12 stages.
    for (auto &v : x) v /= 32;
    return x;
}
static std::vector<Complex> simulate(Vfftifftmain &d,
        const std::vector<Complex> &input, bool inverse, bool stalls) {
    d.i_reset = 1; d.i_ce = 0; d.i_inverse = inverse;
    for (unsigned i = 0; i < 4; ++i) edge(d);
    d.i_reset = 0;
    unsigned accepted = 0;
    bool started = false;
    std::vector<Complex> result;
    for (unsigned wall = 0; wall < 30000 && result.size() < N; ++wall) {
        bool ce = !stalls || (wall % 7 != 2 && wall % 11 != 4 && wall % 19 != 9);
        d.i_ce = ce;
        unsigned i = accepted * 2;
        d.i_left = i < N ? pack(input[i]) : 0;
        d.i_right = i+1 < N ? pack(input[i+1]) : 0;
        d.eval();
        auto old_left = d.o_left, old_right = d.o_right;
        auto old_sync = d.o_sync;
        if (ce && (started || d.o_sync)) {
            if (!started) {
                std::printf(" first_pair_ce=%u", accepted);
                started = true;
            } else if (d.o_sync) {
                std::fprintf(stderr, "unexpected frame sync inside first output frame\n");
                std::exit(1);
            }
            result.push_back(unpack(d.o_left));
            result.push_back(unpack(d.o_right));
        }
        edge(d);
        if (!ce && (d.o_left != old_left || d.o_right != old_right || d.o_sync != old_sync)) {
            std::fprintf(stderr, "output changed during CE pause\n"); std::exit(1);
        }
        if (ce) ++accepted;
    }
    if (result.size() != N) { std::fprintf(stderr, "output timeout\n"); std::exit(1); }
    return result;
}
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vfftifftmain dut;
    std::mt19937 random(0x40961623);
    for (unsigned kind = 0; kind < 4; ++kind) {
        std::vector<Complex> input(N);
        for (unsigned i = 0; i < N; ++i) {
            double angle = 2 * std::acos(-1.0) * i / N;
            if (kind == 0) input[i] = Complex(512, 0);
            if (kind == 1 && i == 37) input[i] = Complex(16000, -8000);
            if (kind == 2) input[i] = Complex(std::round(8000*std::cos(17*angle)+4000*std::sin(93*angle)), 0);
            if (kind == 3) input[i] = Complex(int(random()%16001)-8000, int(random()%16001)-8000);
        }
        for (bool inverse : {false, true}) {
            auto expected = reference(input, inverse);
            std::printf("case=%u inverse=%u", kind, inverse);
            auto baseline = simulate(dut, input, inverse, false);
            auto paused = simulate(dut, input, inverse, true);
            double max_error = 0, sum_squared = 0;
            for (unsigned i = 0; i < N; ++i) {
                if (baseline[i] != paused[i]) {
                    std::fprintf(stderr, "CE mismatch at %u\n", i); return 1;
                }
                auto delta = baseline[i] - expected[i];
                max_error = std::max({max_error, std::abs(delta.real()), std::abs(delta.imag())});
                sum_squared += std::norm(delta);
            }
            std::printf(" max_component_error=%.5f rms_complex_error=%.5f\n", max_error, std::sqrt(sum_squared/N));
            if (max_error > 24) { std::fprintf(stderr, "numeric tolerance exceeded\n"); return 1; }
        }
    }
    std::puts("PASS dual runtime FFT/IFFT: 16 frames, all 4096 natural-order complex bins, CE pauses bit-identical");
}
