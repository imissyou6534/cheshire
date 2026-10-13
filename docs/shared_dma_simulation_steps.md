# 共享 iDMA 验证仿真步骤与命令

核对日期：2026-10-12。服务器项目：`/home/user06/work/xinkailai/cheshire`。

## 1. 验证范围

后续已增加实际 CPU 系统验证入口：`bash util/run_shared_dma_system.sh`。
完整命令和证据见 [shared_dma_system_verification.md](shared_dma_system_verification.md)。
以下 AXI 驱动单元仿真命令仍保留；表内的 lint 入口仍不执行 CPU 程序。

| 入口 | 执行内容 | 是否执行真实 CPU 程序 |
| --- | --- | --- |
| `util/run_shared_dma_tests.sh` | Verilator 编译及运行 AXI 请求驱动的 DMA 测试台，另执行 C 驱动主机测试 | 否 |
| `util/run_shared_dma_vcs.sh` | VCS 编译及运行同一 DMA 测试台，默认 4×2 | 否 |
| `tb_multi_tile_elab` 的 lint/elaboration | 检查四个实际 Cheshire/CVA6 实例与共享 DMA 顶层连接 | 否，仅检查 RTL |

功能测试使用真实 DMA、调度器、DDR 互连及全局原子操作 RTL；CPU 请求由测试台任务模拟，DDR 为 AXI 内存模型。测试台为 `target/sim/src/tb_shared_dma.sv`。

## 2. 从 Windows 登录服务器

下面这条命令在 Windows PowerShell 执行；后续所有 `bash` 命令均在服务器 SSH 会话中执行。

```powershell
ssh -p 2022 user06@10.181.10.18
```

```bash
cd /home/user06/work/xinkailai/cheshire
command -v bender verilator gcc vcs
verilator --version
bender --version
```

本次验证环境使用 Verilator 5.052 和 VCS W-2024.09-SP1。VCS 需要有效的服务器许可证环境。

Verilator 测试脚本会自动加载 `/opt/rh/devtoolset-11/enable`（如果存在），以提供 C++20 timing 仿真所需编译器。

## 3. 准备依赖补丁

```bash
bash util/prepare_shared_dma_deps.sh
```

该脚本可重复执行，已应用补丁时通常不输出内容。它修正 iDMA legalizer 页宽，以及全局 LR/SC monitor 的 reservation 计数宽度和寄存器赋值时序。两个仿真脚本也会自动调用它。

当前命令针对服务器已经存在的依赖 checkout。补丁检查失败应先阅读报错，核对锁定依赖及 checkout 内容，不要直接覆盖依赖中的其他修改。

## 4. Verilator 冒烟测试

先运行 1 tile、1 engine：

```bash
DMA_TEST_SHAPES=1:1 DMA_TEST_ADDR_WIDTH=32 DMA_TEST_RANDOM_STALLS=0 \
  bash util/run_shared_dma_tests.sh
```

预期输出：

```text
PASS shared DMA 1 tiles x 1 engines addr=32 random=0; 16 completions
```

运行默认系统的 4×2 单独配置：

```bash
DMA_TEST_SHAPES=4:2 DMA_TEST_ADDR_WIDTH=32 DMA_TEST_RANDOM_STALLS=0 \
  bash util/run_shared_dma_tests.sh
```

预期输出包含 `PASS shared DMA 4 tiles x 2 engines`，检查 21 个完成事件。

脚本自动执行：依赖准备、C 驱动主机测试、Bender 文件列表生成、Verilator 编译、仿真及 PASS 检查。无需另行编译裸机 ELF。

## 5. Verilator 完整数量矩阵

```bash
DMA_TEST_SHAPES="1:1 2:1 2:2 4:2 3:2 2:3" \
  DMA_TEST_ADDR_WIDTH=32 DMA_TEST_RANDOM_STALLS=0 \
  bash util/run_shared_dma_tests.sh
```

在未设置 `DMA_TEST_*` 环境变量时，简写 `bash util/run_shared_dma_tests.sh` 也使用上述默认矩阵。

| Tile × Engine | 当前测试台预期完成事件数 |
| --- | --- |
| 1×1 | 16 |
| 2×1 | 17 |
| 2×2 | 19 |
| 4×2 | 21 |
| 3×2 | 20 |
| 2×3 | 19 |

通过判据是本次脚本退出码为 0，并出现六组对应的 PASS。遇到某一组失败，脚本会停止。

## 6. 48 位地址与随机 AXI 反压

```bash
DMA_TEST_SHAPES=4:2 DMA_TEST_ADDR_WIDTH=48 DMA_TEST_RANDOM_STALLS=1 \
  DMA_TEST_BUILD_ROOT="$PWD/target/shared_dma_verify/addr48_random" \
  bash util/run_shared_dma_tests.sh
```

预期输出：

```text
PASS shared DMA 4 tiles x 2 engines addr=48 random=1; 21 completions
```

`DMA_TEST_ADDR_WIDTH=48` 改变总线地址宽度，当前测试数据仍位于 `0x80000000..0x80010000`，不代表已经测试了 4 GiB 以上的数据搬运。

| Verilator 环境变量 | 含义 | 默认值 |
| --- | --- | --- |
| `DMA_TEST_SHAPES` | 空格分隔的 `Tile数量:Engine数量` | `1:1 2:1 2:2 4:2 3:2 2:3` |
| `DMA_TEST_ADDR_WIDTH` | AXI 地址位宽 | `32` |
| `DMA_TEST_RANDOM_STALLS` | 是否启用随机 AXI 反压 | `0` |
| `DMA_TEST_BUILD_ROOT` | 编译产物及日志目录，建议使用绝对路径 | `$PWD/target/shared_dma_verify` |

并行运行多个测试脚本时应使用不同的 `DMA_TEST_BUILD_ROOT`，避免同时写同一个依赖列表或编译目录。

## 7. VCS 交叉验证

```bash
bash util/run_shared_dma_vcs.sh
```

预期输出：

```text
PASS shared DMA 4 tiles x 2 engines addr=32 random=0; 21 completions
```

当前 VCS 脚本使用测试台默认参数，不读取上表中的 `DMA_TEST_*` 参数。它将依赖列表、编译产物和日志放在 `target/shared_dma_verify/vcs/`。

脚本从 VCS 文件列表中排除未实例化的 `idma_error_handler.sv`，原因是其中嵌套在 `always_comb` 的并发断言被 VCS 拒绝。当前 Engine 使用 `NO_ERROR_HANDLING` 并由 wrapper 监测 AXI 错误；测试台和 wrapper 的显式断言保持启用。

## 8. 实际四 Tile 顶层 lint/elaboration

此步骤检查 `multi_tile_top` 内四个实际 Cheshire/CVA6 实例的类型、参数和连接，不启动 CPU 程序。

```bash
bash util/prepare_shared_dma_deps.sh
mkdir -p target/shared_dma_verify

bender script verilator -t rtl -t cva6 -t cv64a6_imafdchsclic_sv39_wb \
  -t exclude_first_pass_decoder --compilation-mode common \
  > target/shared_dma_verify/soc.f

verilator --lint-only --timing --assert -Wno-fatal \
  --top-module tb_multi_tile_elab \
  -f target/shared_dma_verify/soc.f target/sim/src/tb_multi_tile_elab.sv \
  > target/shared_dma_verify/soc_lint.log 2>&1
```

最后一条命令执行后，可立即查看其退出码及日志：

```bash
echo $?
tail -n 30 target/shared_dma_verify/soc_lint.log
```

退出码 0 表示检查完成。由于使用 `-Wno-fatal`，仍可能有上游位宽和组合路径等警告，不能将其解释为无警告或综合时序已经收敛。

## 9. 单独运行 C 驱动主机测试

该测试也包含在 Verilator 脚本中。单独执行命令如下：

```bash
mkdir -p target/shared_dma_verify
gcc -std=c11 -Wall -Wextra -Werror -Isw/include \
  target/sim/src/shared_dma_driver_test.c \
  -o target/shared_dma_verify/driver_test
target/shared_dma_verify/driver_test
```

当前测试成功时无输出，退出码为 0；检查参数验证及失败提交不会返回旧 Job ID。这里生成的是服务器主机程序，不是 CVA6 裸机程序。

## 10. 日志和只重跑仿真

| 验证类型 | 编译日志 | 仿真日志 |
| --- | --- | --- |
| Verilator 4×2、32位 | `target/shared_dma_verify/4x2_a32_r0/build.log` | 同目录 `run.log` |
| Verilator 48位随机反压 | `target/shared_dma_verify/addr48_random/4x2_a48_r1/build.log` | 同目录 `run.log` |
| VCS | `target/shared_dma_verify/vcs/build.log` | 同目录 `run.log` |
| 实际Tile顶层检查 | `target/shared_dma_verify/soc_lint.log` | 无功能仿真日志 |

失败时优先检查本次对应日志：

```bash
tail -n 80 target/shared_dma_verify/4x2_a32_r0/build.log
tail -n 80 target/shared_dma_verify/4x2_a32_r0/run.log
```

构建失败可能留下之前运行的 `run.log`。只看到旧日志中的 PASS 不足以证明本次运行成功，应核对本次退出码和日志修改时间。

已编译完成且 RTL/测试台未修改时，可以只运行现有仿真程序：

```bash
target/shared_dma_verify/4x2_a32_r0/obj/Vtb_shared_dma \
  > target/shared_dma_verify/4x2_a32_r0/rerun.log 2>&1
grep 'PASS shared DMA' target/shared_dma_verify/4x2_a32_r0/rerun.log
```

需要详细 MMIO 和 AXI 事务文本时加 `+VERBOSE`：

```bash
target/shared_dma_verify/4x2_a32_r0/obj/Vtb_shared_dma +VERBOSE \
  > target/shared_dma_verify/4x2_a32_r0/verbose.log 2>&1

target/shared_dma_verify/vcs/simv +VERBOSE \
  > target/shared_dma_verify/vcs/verbose.log 2>&1
```

修改 RTL、依赖补丁或测试台后，应重新运行对应构建脚本，不能只运行旧二进制。当前脚本没有启用 VCD/FSDB 波形输出。

## 11. 当前验证边界

功能回归覆盖配置隔离、快照、二维步长、跨页、最终 B 反压、非法提交、队列容量、IRQ 电平、完成归属、AXI 错误以及全局 AMO/LRSC。

本页的单元测试自身不覆盖 CPU 软件运行；新增系统测试已覆盖实际多 CPU 启动、IRQ/PLIC handler、缓存维护及 AMO 软件同步。FPGA 综合时序和板级 DDR 尚未验证。活动任务复位测试在 DDR 接收请求前阻断流量；物理 DDR 已接受事务的复位仍须平台验证。独立 Tile/Engine 热复位和超时取消未实现。

具体历史验证结果见 [shared_dma_verification.md](shared_dma_verification.md)，设计接口见 [shared_dma_design.md](shared_dma_design.md)。
