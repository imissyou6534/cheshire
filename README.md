# Cheshire 多 Tile SoC

本项目基于 [PULP Cheshire](https://github.com/pulp-platform/cheshire)，集成 CVA6、Ara、FFT 加速器、私有 SPM 和共享 DMA，支持多 tile 系统的 VCS 仿真与 VCU118 FPGA 构建。
上游 Cheshire 由 ETH Zurich 和 University of Bologna 的 PULP 项目开发；本分支维护自有 SoC 集成和 IP 修改。

以下命令在 Linux 服务器的仓库根目录执行。推荐按“克隆、依赖初始化、系统仿真、FPGA 构建”的顺序操作，不以传统 `make all` 作为唯一入口。

## 1. 环境要求

| 工具 | 当前使用环境 |
| --- | --- |
| Python | 3.9，安装 requirements.txt |
| Bender | 0.31.0 |
| RISC-V GCC/binutils | 支持 rv64gcv_zifencei，命令前缀 riscv64-unknown-elf- |
| VCS / vlogan | W-2024.09-SP1 |
| Vivado | 2024.2，安装 VCU118 器件和板卡文件 |
| 其他 | Git、GNU Make、wget、unzip；商业工具许可证需已配置 |

先确认工具在 PATH 中：

```bash
command -v git make python3 bender riscv64-unknown-elf-gcc vcs vlogan
bender --version
```

服务器上的 `vivado24` 是加载 Vivado 2024.2 环境的本地包装脚本，并非 Vivado 标准命令。其他环境可加载 `settings64.sh` 后，在后续 Make 命令中使用 `VIVADO=vivado`。

## 2. 获取主仓库

在新目录中克隆开发分支：

```bash
git clone --branch dsa/multi-tile-v0 \
  https://github.com/imissyou6534/cheshire.git cheshire
cd cheshire
git status --short --branch
```

安装 Python 依赖：

```bash
python3 -m pip install -r requirements.txt
```

## 3. 初始化子模块与 Bender 依赖

依赖来源分为两类：

- 主仓库的 `sw/deps/printf`、`sw/deps/cva6-sdk`：由 Git 子模块管理。
- 26 个 HDL 包：由 `Bender.yml`、`.bender.yml` 和 `Bender.lock` 管理，检出到 `.bender/git/checkouts/`；部分包内部还有递归子模块。

七个自有 IP 的 Bender 地址统一使用 HTTPS，与主仓库的克隆方式一致。公开仓库拉取无需 GitHub SSH 认证，不需要额外配置 Git 地址映射。

初始化：

```bash
git submodule update --init --recursive
bender checkout
python3 util/rom_bender.py check
```

`rom_bender.py check` 只确认 lock 中的包能否唯一定位到含 `Bender.yml` 的现有目录，不验证所有递归文件、配置或 HEAD。
初始化时使用 `bender checkout` 恢复 lock，不执行 `bender update` 升级依赖。

下载结束后检查子模块，至少确认没有意外的 `+` 或未完成检出：

```bash
git submodule status --recursive
ARA_DIR="$(python3 util/rom_bender.py path ara)"
CVA6_DIR="$(python3 util/rom_bender.py path cva6)"
git -C "$ARA_DIR" submodule status --recursive
git -C "$CVA6_DIR" submodule status --recursive
git -C "$ARA_DIR" status --short --ignore-submodules=none
git -C "$CVA6_DIR" status --short --ignore-submodules=none
```

前缀 `+` 表示实际提交偏离父仓库记录，`-` 表示未初始化。Ara 的 rvv-bench、newlib、riscv-gnu-toolchain、riscv-llvm 设置了 `update = none`，允许不初始化。
`Checked out PACKAGE` 仅表示主包检出完成，不能替代内部子模块完整性检查；已有 HEAD 但源码为空的目录也必须处理。
失败后可对具体包重试 `git -C "$ARA_DIR" submodule update --init --recursive`，不要加 `--remote`。

日常 Make 使用 `util/rom_bender.py` 消费已有工作区，允许本地 IP 修改，不强制 HEAD 等于 lock，也不要求工作区干净。不要通过日常构建自动重置、打补丁或重新生成依赖。
当前使用已提交的依赖 RTL，不需要创建五个 `.generated` 空标记。详细策略见 [依赖保护说明](docs/dependency_protection.md)。

## 4. VCS 多 Tile 系统仿真

当前多 tile 配置关闭 SPI Host、I2C，且不实例化外部 Flash/EEPROM 模型。但现有 Bender 仿真清单仍包含旧单 SoC 平台，首次运行仍须提供其模型文件。下面的 `make chs-sim-all` 沿用项目原有规则，按需下载模型并生成传统仿真编译脚本；实际多 tile 编译和运行由 Python 入口完成。下载异常时参考[旧单 SoC 仿真模型说明](docs/legacy_simulation_models.md)，不需要修改 Bender 版本或重复克隆整个项目。

推荐从 SPM 启动的双 tile / 双 DMA 配置开始：

```bash
make chs-sim-all
python3 util/run_multitile_sim.py \
  --boot spm --tiles 2 --dmas 2 --uart-tiles all
```

该入口自动执行以下流程，无需先手动构建默认 C 程序：

1. 编译默认应用 `sw/tests/vector_helloworld.c` 和 loader，生成 ELF、应用二进制和固件记录。
2. 通过 Bender 生成源码列表，调用 vlogan、vcs 编译和展开。
3. VIP 通过 AXI 装载各 tile 的 SPM 并启动 CPU。
4. 检查每个 tile 的程序返回值、Ara 请求、UART 内容和 64 字节缓冲区读回。

`--dmas 2` 表示实例化两个共享 DMA 引擎；默认 Hello 不等同于 DMA 专项传输测试。

### 参数与默认值

| 参数 | 默认值 | 含义 |
| --- | --- | --- |
| --boot | rom | 启动方式；主示例显式选择 spm，ROM 的当前限制见下文 |
| --bus-profile | wide | 数据通路位宽与 Ara lane 配置，不改变 CPU 的 RV64 架构 |
| --tiles / --dmas | 1 / 1 | tile 数与共享 DMA 引擎数 |
| --uart-tiles | tile0 | 默认只对 tile 0 做选定的 UART 内容校验；all 校验各 tile 的 UART |
| --require-ara | 未设置 | 要求各 tile 确实发出 Ara 请求；内置 Hello 即使省略该参数也自动要求 |
| --app | 未指定 | 未指定时选择内置 Hello；指定后作为自定义应用编译 |
| --out | 自动选择 | 输出到 target/sim/build/multitile/启动方式/tilesxdmas/ |
| --reuse-build | 未设置 | 设置后仅复用签名匹配的模型；不匹配时必须重新编译 |

内置 Hello 还会自动设置 UART 和内存预期。显式传入 `--app` 后，即使指定同一个 Hello 文件，也按自定义应用处理，需要自行添加所需的 Ara、UART、缓冲区检查。

`--bus-profile` 对应配置：

| 数据通路 | wide（默认） | legacy |
| --- | --- | --- |
| CPU / Debug | 64 位 | 64 位 |
| tile / Ara / FFT / DMA | 128 位 | 64 位 |
| 共享互连 | 256 位 | 64 位 |
| Ara lanes | 4 | 2 |
| VLEN | 2048 | 2048 |

因此主示例省略 `--bus-profile wide` 和 `--require-ara`；保留 `--uart-tiles all` 是为了核对两颗 CPU 的 UART，而不是只检查 tile 0。

### 输出与重复运行

主示例的默认输出位置：

```text
target/sim/build/multitile/spm/2x2/
├── firmware/          固件、应用二进制、ROM 快照及 payload.json
├── compile_deps.sh    编译脚本
├── compile.json       模型签名和配置
├── simv               VCS 仿真程序
├── build.log          编译、展开日志
├── run.log            仿真日志
├── result.csv         每个 tile 的结果
└── result.json        总体状态、输入指纹和结果
```

输出统一放在 Git 忽略的 `target/sim/build/`，无需额外的 fresh 目录。
软件或硬件修改后不加 `--reuse-build` 正常重编译；已编译且签名匹配时可使用：

```bash
python3 util/run_multitile_sim.py \
  --boot spm --tiles 2 --dmas 2 --uart-tiles all --reuse-build
```

程序打印和工具退出码不足以判断通过，还需 `PASS MULTITILE`、正确返回值、完整 JSON/CSV 结果和 `hardware_unchanged=true`。首次使用新分支仍需重新验收，不能沿用旧克隆的通过记录。

### ROM 启动仿真，可选

ROM runner 也会自动编译本次应用并使用它的不可变 ROM 快照。不过当前源码列表生成阶段仍先要求根工程的 ROM 路径存在，全新克隆时暂时需要先准备该路径：

```bash
make chs-rom-autoboot
python3 util/run_multitile_sim.py --boot rom --tiles 2 --dmas 2 --uart-tiles all
```

这条前置命令是当前路径衔接的临时要求，不是 SPM 仿真和 FPGA ROM 构建的通用必需步骤。

## 5. FPGA 综合与 Bitstream

以下以 VCU118、1 tile、1 DMA、ROM 启动为例。Make 会按需生成 clkwiz、VIO、DDR4 厂商 IP，并自动编译 `CHS_ROM_APP`、生成 ROM 和源码列表。
`CHS_ROM_APP` 默认是 `sw/tests/vector_helloworld.c`，无需先单独执行 `make chs-rom-autoboot`。

仅进行 SoC 综合：

```bash
make chs-xilinx-multi-tile-rom-vcu118 \
  CHS_NUM_TILES=1 CHS_NUM_DMAS=1 \
  CHS_XILINX_SYNTH_ONLY=1 VIVADO=vivado24
```

需要完整布局布线和 bitstream 时执行：

```bash
make chs-xilinx-multi-tile-rom-vcu118 \
  CHS_NUM_TILES=1 CHS_NUM_DMAS=1 \
  CHS_XILINX_SYNTH_ONLY=0 VIVADO=vivado24
```

`CHS_XILINX_SYNTH_ONLY` 默认是 0；不指定会继续实现，而非只综合。两个命令是不同阶段的选择，不要求都运行。
应用通过 `CHS_ROM_APP=相对路径.c` 更换。程序变化后需要重新生成包含它的 bitstream。
目标器件为 `xcvu9p-flga2104-2L-e`，板卡定义为 `xilinx.com:vcu118:part0:2.4`。

主要输出：

```text
target/rom_autoboot/                                      FPGA 固件与 ROM 快照
target/xilinx/build/multi_tile_rom.vcu118.log              Vivado 主日志
target/xilinx/build/vcu118.multi_tile_rom/reports.synth/   综合报告
target/xilinx/build/vcu118.multi_tile_rom/reports.impl/    实现报告
target/xilinx/out/multi_tile_rom.vcu118.bit                最终 bitstream
```

综合检查实际 run 状态、ERROR 日志和 `PASS Xilinx synthesis`。完整实现还需检查 DRC、setup/hold、资源与 write_bitstream 结果。
构建脚本会清理同名实现工程目录，重跑可能覆盖该目录的旧报告；需保存历史结果时先备份输出。

## 6. 其他 Make 入口与当前边界

| 命令 | 作用 |
| --- | --- |
| make chs-hw-all | 准备/检查根工程硬件输入，使用已有依赖 RTL，不重新生成依赖 IP |
| make chs-rom-autoboot | 单独编译默认或 CHS_ROM_APP 指定的固件，输出到 target/rom_autoboot/ |
| make chs-sim-all | 准备模型、生成传统仿真编译脚本，不执行系统仿真 |
| make chs-sw-all | 传统软件全量构建 |
| make chs-all / make all | 组合传统软件、硬件和仿真准备目标，不等于运行 VCS 或 FPGA 构建 |

推荐采用本文的分目标流程。传统软件全量规则仍将 `sw/tests/*.c` 视为独立应用，而部分辅助文件没有 main；其默认 ISA 也不是所有向量用例需要的配置，不能将 `make all` 视为当前完整一键验收。

其他已知边界：

- 依赖生成器仍可供显式维护使用，但正常构建不会重置、打补丁或覆盖 IP。修改模板/配置后应审查生成结果并提交。
- serial_link 主项目 HJSON 的 NumBits 为 8，已提交 RTL 为 16；恢复旧生成流程会改变接口，需先统一配置。
- FPGA PLIC `--check` 仍直接使用原始 `bender path`，应避免在含多套来源缓存的开发目录盲目调用；建议后续统一为只读路径接口。
- 不需要 nonfree 仓库或完整 Linux SDK 镜像来运行本文的 Hello 系统仿真和 ROM FPGA 入口。Linux 镜像、FFT 精度和其他专项验证另行准备。

依赖保护回归测试：

```bash
python3 -m unittest discover \
  -s util/tests -p test_make_dependency_guard.py -v
```

更多系统仿真说明见 [multitile_simulation.md](docs/multitile_simulation.md)，上游文档见 [Getting Started](https://pulp-platform.github.io/cheshire/gs/) 和 [User Manual](https://pulp-platform.github.io/cheshire/um/)。

## License

Unless specified otherwise in the respective file headers, all code checked into this repository is made available under a permissive license. All hardware sources and tool scripts are licensed under the Solderpad Hardware License 0.51 (see `LICENSE`) or compatible licenses. Register file code (e.g. `hw/regs/*.sv`) is generated by a fork of lowRISC's [`regtool`](https://github.com/lowRISC/opentitan/blob/master/util/regtool.py) and licensed under Apache 2.0. The USB OHCI controller (`hw/future/UsbOhciAxi4.v`) is generated from the [SpinalHDL](https://github.com/SpinalHDL/SpinalHDL) library licensed under the MIT license. All software sources are licensed under Apache 2.0.

## Publication

If you use Cheshire in your work, cite the original project:

```
@article{ottaviano2023cheshire,
      title   = {Cheshire: A Lightweight, Linux-Capable RISC-V Host
                 Platform for Domain-Specific Accelerator Plug-In},
      author  = {Alessandro Ottaviano and Thomas Benz and
                 Paul Scheffler and Luca Benini},
      journal = {IEEE Transactions on Circuits and Systems II: Express Briefs},
      year    = {2023},
      volume  = {70},
      number  = {10},
      pages   = {3777-3781},
      doi     = {10.1109/TCSII.2023.3289186}
}
```
