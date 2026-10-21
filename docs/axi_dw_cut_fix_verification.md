# AXI 降宽边界寄存器隔离修复

日期：2026-10-21。实际工程：`/home/user06/work/xinkailai/cheshire`。
本次修复对应 FPGA `write_bitstream` 前的两项 LUTLP-1：外设寄存器路径和 Debug 寄存器路径。

## RTL 修改

只修改 `/home/user06/work/xinkailai/cheshire/hw/cheshire_soc.sv`，增加 42 行、替换 2 行。

| 新增实例 | 位置和作用 |
| --- | --- |
| `i_periph_width_cut`，第 438 行 | `i_periph_width` 的 64 位输出与 `i_axi_to_reg_v2` 之间 |
| `i_debug_mem_width_cut`，第 1316 行 | `i_debug_mem_width` 的 Debug 原生位宽输出与 `i_dbg_slv_axi_to_mem` 之间；当前为 64 位 |

两个实例均使用现有 `axi_cut`，固定 `Bypass=0`，采用各自窄侧 AW/W/B/AR/R 类型，
与原模块使用相同的 `clk_i/rst_ni`。
新增 `periph_uncut_req/rsp`、`debug_mem_uncut_req/rsp`，转换器先连接这些信号；
cut 输出继续连接原有 `periph_req/rsp` 和 `debug_mem_req/rsp`。

```text
原有上游 AXI cut -> 128 到 64 位转换器 -> 新增完整 AXI cut -> 下游 AXI 桥
```

这隔断了 WREADY 到 BREADY 再返回 WREADY 的组合依赖。
五个通道一起缓存，地址、ID、USER、burst、字节使能和响应信息均由现有 AXI cut 传递。
接口位宽、地址映射、时钟、SPM 容量和原子操作配置不变；legacy64 也保留新 cut，增加通道延迟。

## Vivado 红绿对照

使用真实依赖模块组成小规模综合探针，分别实例化外设桥和 Debug 桥，比较边界直接连接和加入 cut。
Vivado 2024.2 在 VCU118 器件上综合后，显式运行 `report_drc -checks LUTLP-1`。

| 探针 | 直接连接的环数 | 非旁路 cut 后的环数 |
| --- | --- | --- |
| 外设：downsizer + axi_to_reg_v2 | 1 | 0 |
| Debug：downsizer + axi_to_mem_interleaved | 1 | 0 |

这验证的是目标连接的综合后组合环，不等同于完整 SoC 布局布线通过。
没有添加 ALLOW_COMBINATORIAL_LOOPS 或降低 DRC 严重等级。
实际完整 FPGA 失败日志和旧 bitstream 保留，未覆盖。

可重复运行：

```bash
cd /home/user06/work/xinkailai/cheshire
python3 util/run_axi_dw_cut_drc.py \
  --out /tmp/axi-dw-cut-drc-recheck \
  --vivado /opt/Xilinx/Vivado/2024.2/bin/vivado
```

测试需要支持 JSON metadata 输出的 Verilator，以及 Vivado。
入口使用 `prepared_paths()` 查找现有依赖，没有调用 raw Bender、切换版本或重新生成依赖。
输出目录必须是新目录；正例必须为零环，负例必须检出环，缺少或重复结果均判失败。
探针和 Tcl 分别为 `target/sim/src/dw_loop_probe.sv`、`util/tests/axi_dw_cut_drc.tcl`。

## 系统回归

| 工作负载 | legacy 2lane/64 | wide 4lane/128 |
| --- | --- | --- |
| 217 个 VID/相邻 mask 指令场景 | PASS | PASS |
| 原始 mask overlap 程序 | PASS，91 次 Ara 请求 | PASS，91 次 Ara 请求 |
| Hello：完整 38 字节 UART 和缓冲区读回 | PASS | PASS |
| VID 内部入队/issue/计数断言 | PASS | PASS |

FPGA 顶层 RTL 模型还通过：

- 真实 JTAG/DMI/SBA 读 ROM、停核、下载 ELF、恢复执行与 EOC。
- 38 字节 UART 与 64 字节向量缓冲读回。
- 通过 JTAG 提交共享 DMA、PLIC pending 检查、DDR 目标数据读回。
- 2tile/2DMA 的 JTAG 串链和 UART 连接检查；此项仅验证连接，不宣称双 tile 全应用执行。
- 类型断言：Debug64、Tile128、DMA128、Shared256、MIG512、Ara4。

依赖保护的 8 项主机测试通过。独立只读代码审查未发现待处理问题。
准备好的依赖保持原状态，先前 VID 修复仍在原 Ara 工作区中，未重置或覆盖。

## 证据和限制

本轮输出根目录：`/tmp/cheshire-dw-cut-fix-20261021/`。
`drc/` 保存可重复入口的四个综合/DRC 对照；`wide/`、`legacy/` 保存新编译的系统回归；
`board/` 保存 FPGA 顶层 JTAG/UART/DMA 模型结果。
汇总、源文件哈希、依赖状态和硬件指纹见 [机器记录](axi_dw_cut_fix_verification.json)。
完整 FPGA 工程尚未用本次修改重新进行布局布线，未生成或下载新 bitstream。
原来正裕量的时序报告不能证明新设计最终时序；重新构建仍需检查实际 LUTLP-1、setup/hold 和资源结果。
后续使用原 ROM 多 tile Make 入口即可纳入当前源码修改；该入口本身会重建对应 FPGA 工程目录。
