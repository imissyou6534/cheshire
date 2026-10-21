# 128 到 64 位 AXI 组合逻辑环分析

后续状态：已实施两个降宽器输出侧的完整 AXI cut，验证见
[隔离修复记录](axi_dw_cut_fix_verification.md)。以下保留修复前的分析过程。

日期：2026-10-21。分析对象为服务器 `/home/user06/work/xinkailai/cheshire`。
本轮没有修改工程 RTL、依赖或约束，也没有重跑完整 FPGA 构建。

## 结论

本次集成在两个 128 到 64 位降宽器与下游 AXI 桥之间形成了跨 W/B 通道的结构性组合反馈。
它不是数据位数本身造成的普通长路径，也不是 VID 算术路径的问题。

```text
后级桥输出 WREADY
  -> 降宽器确认最后一个 W beat 的本拍握手
  -> 生成 forward_b_beat_i / forward_b_beat_push
  -> 空的 fall-through FIFO 将新筛选标记直接送到输出
  -> 降宽器据此选择送往下游的 BREADY
  -> 后级桥判断本拍 B 响应是否可以被消费
  -> stream_to_mem 判断本拍是否能接收新请求
  -> 写请求 fork/mux 产生 wr_ready
  -> 后级桥输出 WREADY
```

Vivado 完整设计的 LUTLP-1 报告已确认两处实际网表环：外设路径 11 个 LUT、Debug 路径 13 个 LUT。
RTL 分析说明了其跨模块依赖机制；未通过形式验证证明所有使能条件可同时达到，
也没有宣称已经在仿真中观察到振荡或死锁。

## 两条实例路径

外设路径：

```text
128-bit AXI -> i_reg_atomics_cut -> i_periph_width
           -> 64-bit AXI -> i_axi_to_reg_v2 -> 32-bit Regbus
```

Debug 路径：

```text
128-bit AXI -> i_dbg_slv_axi_atomics_cut -> i_debug_mem_width
           -> 64-bit AXI -> i_dbg_slv_axi_to_mem -> Debug module
```

两个降宽器都使用当前 `axi_dw_converter`。同宽时该模块直接连接请求和响应；
现在 Tile 为 128 位、外设及 Debug 为 64 位，激活了 `axi_dw_downsizer`，引入新的 W 到 B 依赖。

## 关键 RTL

| 服务器文件与行号 | 相关行为 |
| --- | --- |
| `/home/user06/work/xinkailai/cheshire/.bender/git/checkouts/axi-ecdc900686449c15/src/axi_dw_converter.sv:46` | 同宽分支直接透传；降宽分支实例化 downsizer |
| `/home/user06/work/xinkailai/cheshire/.bender/git/checkouts/axi-ecdc900686449c15/src/axi_dw_downsizer.sv:660` | B 响应筛选标记 FIFO 开启 FALL_THROUGH |
| `/home/user06/work/xinkailai/cheshire/.bender/git/checkouts/axi-ecdc900686449c15/src/axi_dw_downsizer.sv:767` | 本拍 WREADY 和 WVALID 确认 W 握手 |
| `/home/user06/work/xinkailai/cheshire/.bender/git/checkouts/axi-ecdc900686449c15/src/axi_dw_downsizer.sv:807` | 最后一个 W beat 握手后，本拍 push 筛选标记 1 |
| `/home/user06/work/xinkailai/cheshire/.bender/git/checkouts/common_cells-7f7ae0f5e6bf7fb5/src/fifo_v3.sv:103` | FIFO 为空且 push 时，data_o 直接选择 data_i，不等待时钟 |
| `/home/user06/work/xinkailai/cheshire/.bender/git/checkouts/axi-ecdc900686449c15/src/axi_dw_downsizer.sv:719` | 筛选标记为 1 时 BREADY 跟随上游，否则强制为 1 |
| `/home/user06/work/xinkailai/cheshire/.bender/git/checkouts/axi-ecdc900686449c15/src/axi_demux.sv:56` | 默认 SpillAw/Ar=1，但 SpillW/B/R=0，未对 W/B 做完整隔离 |
| `/home/user06/work/xinkailai/cheshire/.bender/git/checkouts/axi-ecdc900686449c15/src/axi_to_detailed_mem.sv:495` | 响应 join/fork 把 AXI BREADY 传回内部响应消费路径 |
| `/home/user06/work/xinkailai/cheshire/.bender/git/checkouts/common_cells-7f7ae0f5e6bf7fb5/src/stream_to_mem.sv:77` | 本拍响应消费允许本拍释放容量，进而影响新请求 ready |
| `/home/user06/work/xinkailai/cheshire/.bender/git/checkouts/axi-ecdc900686449c15/src/axi_to_detailed_mem.sv:262` | 写侧 wr_ready 组合地产生 AXI AWREADY/WREADY |

降宽器的 B 控制逻辑可概括为：

```systemverilog
downstream_b_ready = forward_b_beat_o ? upstream_b_ready : 1'b1;
```

桥接器内部的容量前瞻直接来自源码：

```systemverilog
req_ready = (cnt_q < BufDepth) | (resp_valid_o & resp_ready_i);
req_ready_o = mem_req_ready_i & req_ready;
```

因此不能认为“包含 FIFO/计数器/时钟输入”就已经隔断组合路径。
这里的路径经过 FIFO 的空队列旁路和本拍响应释放容量逻辑，而不是等待计数器下一拍更新。

## 为什么现有 cut 没有消除环

`/home/user06/work/xinkailai/cheshire/hw/cheshire_soc.sv:398` 的外设 AXI cut
以及第 1254 行的 Debug AXI cut，均在降宽器之前。
闭环位于降宽器内部及其下游桥之间，所以前面的 cut 不在这个环上。

`RegAdaptMemCut=1` 对应的是 `axi_to_reg_v2` 内部、AXI 转换之后的 memory 请求切分，
不是降宽器与 AXI 桥边界上的五通道切分，也没有移除 `stream_to_mem` 的响应容量前瞻。

## 仿真与物理检查的区别

依赖弧生效有条件：例如筛选 FIFO 为空、最后一拍 W 握手、上游 BREADY 为 0，
以及桥接器响应有效、选择 B 通道、容量受限等。
协议状态间还可能有相关性。因此常规 VCS 程序通过不代表结构环不存在；
反过来，结构环也不能单独证明软件流量必然触发振荡。

临时最小连接检查位于 `/tmp/cheshire-dw-loop-analysis-20261021/`，使用实际依赖源码；
探针及驱动为 `/tmp/cheshire_dw_loop_probe.sv`、`/tmp/cheshire_check_dw_loops.py`。
Verilator UNOPTFLAT 还包含按 always 块或结构体传播的调度依赖，不能将其告警数量等同于
Vivado 的 LUT 环数量，也不能依据临时 cut 对照宣称完整 FPGA DRC 已修复。
检查前后硬件状态一致。

## 后续修复方向

优先验证在两个降宽器的 64 位输出与下游 AXI 桥之间加入完整 AXI register slice/cut，
从实际环路经过的位置隔开 W/B 依赖；仅扩大 FIFO、降低时钟或屏蔽 LUTLP-1 不能证明问题消除。
这只是本轮分析得到的修复方向，工程 RTL 尚未实施该修改，需以回归和 Vivado DRC 验证。
