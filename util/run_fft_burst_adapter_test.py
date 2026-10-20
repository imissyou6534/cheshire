#!/usr/bin/env python3
"""Focused AXI FFT transport test; uses a deterministic CE-gated pair core."""
import argparse
import cmath
import pathlib
import random
import subprocess


def reference(values, inverse):
    """Radix-two floating-point DFT oracle, with the software scale of 1/32."""
    values=[complex(value) for value in values]
    n=len(values)
    j=0
    for i in range(1,n):
        bit=n>>1
        while j & bit:
            j^=bit
            bit>>=1
        j^=bit
        if i<j:
            values[i],values[j]=values[j],values[i]
    length=2
    while length<=n:
        root=cmath.exp((2j if inverse else -2j)*cmath.pi/length)
        for start in range(0,n,length):
            weight=1
            for k in range(length//2):
                a=values[start+k]
                b=weight*values[start+k+length//2]
                values[start+k]=a+b
                values[start+k+length//2]=a-b
                weight*=root
        length*=2
    return [value/32 for value in values]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-root", type=pathlib.Path, required=True)
    parser.add_argument("--verilator", default="verilator")
    parser.add_argument("--real-core", action="store_true")
    args = parser.parse_args()
    repo = pathlib.Path(__file__).resolve().parents[1]
    sources = ["hw/fft/src/fft_accel_pkg.sv", "hw/fft/src/fft_task_ctrl.sv",
               "hw/fft/src/fft_accelerator_ip.sv", "hw/fft/tb/fft_burst_adapter_tb.sv"]
    args.build_root.mkdir(parents=True, exist_ok=True)
    if args.real_core:
        rng=random.Random(4096)
        source_values=[rng.randint(-24000,24000) for _ in range(4096)]
        input_path=args.build_root.resolve()/"input.hex"
        input_path.write_text("".join(f"{int(x)&0xffff:04x}\n" for x in source_values))
        for inverse in (0,1):
            values=reference(source_values,inverse)
            words=[((int(round(x.imag))&0xffffffff)<<32)|(int(round(x.real))&0xffffffff) for x in values]
            (args.build_root/f"expected-{inverse}.hex").write_text("".join(f"{x:016x}\n" for x in words))
        sources += ["hw/fft/rtl/"+name+".v" for name in (
            "fftifftmain","fftstage","butterfly","longbimpy","bimpy",
            "qtrstage","laststage","bitreverse","convround")]
    configurations=((128,False),(64,False)) if args.real_core else ((128,False),(64,False),(128,True))
    for width, early in configurations:
        name=str(width) + ("-early" if early else "")
        build = args.build_root / name
        with (args.build_root / (name + "-build.log")).open("w") as log:
            subprocess.run([args.verilator, "--binary", "--timing", "--assert",
                            "-CFLAGS", "-std=c++20", "-Wno-fatal",
                            "+define+FFT_TEST_DW=" + str(width), "--top-module",
                            "fft_burst_adapter_tb", "--Mdir", str(build)] +
                           (["+define+FFT_TEST_EARLY"] if early else []) +
                           (["+define+FFT_REAL_CORE", '+define+CHESHIRE_FFT_COEFF_ROOT="'+str(repo/"hw/fft/rtl")+'"']
                            if args.real_core else []) + sources,
                           cwd=repo, stdout=log, stderr=subprocess.STDOUT, check=True)
        for source in (0, 8):
            for destination in (0, 8):
                for inverse in ((0,1) if args.real_core else (0,)):
                    subprocess.run([str(build / "Vfft_burst_adapter_tb"),
                                "+SRC_OFFSET=" + str(source),
                                "+DST_OFFSET=" + str(destination),"+INVERSE="+str(inverse)] +
                                (["+INPUT_HEX="+str(input_path),"+EXPECTED_HEX="+
                                  str((args.build_root/f"expected-{inverse}.hex").resolve()),
                                  "+TOLERANCE=8"] if args.real_core else []), check=True)
        for error in (() if args.real_core else ((1,2,3,4,5) if early else (1,2))):
            subprocess.run([str(build / "Vfft_burst_adapter_tb"),
                            "+SRC_OFFSET=8", "+DST_OFFSET=8",
                            "+ERROR=" + str(error), "+RECOVER"], check=True)


if __name__ == "__main__":
    main()
