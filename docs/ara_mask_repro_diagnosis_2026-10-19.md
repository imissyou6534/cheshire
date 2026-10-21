# Ara mask 复现程序停顿诊断

后续状态：2026-10-20 已实施并验证修复，见 [VID修复记录](ara_vid_fix_verification.md)。
本文保留修复前的定位过程和证据，以下“没有修复”等描述指 2026-10-19 的诊断阶段。

日期：2026-10-19。实际仿真在服务器 `/home/user06/work/xinkailai/cheshire` 上执行。
本轮没有修改项目 RTL 或 `.bender` 依赖；观测模块、测试变体和驱动脚本均位于 `/tmp`。

## 结论

已确认当前 Ara 版本的 `VID` 指令存在 ALU 到 MASKU 的结果生成与消费不匹配：
ALU 为 `vid.v` 生成额外的 mask operand，而 MASKU 自己生成索引，不消费这份 ALU 数据。
额外数据占据未携带指令 ID 的数据通道，被后续 `VMSNE` 当作比较输入使用，
并使剩余数据逐次累积，最终阻塞 ALU 结果队列和后续向量指令。

该问题在改宽前原始工程、修改后的 legacy64 和 wide128 配置中都存在。
不能将这次停顿归因于 128 位总线，也不能将结果概括成所有 mask 指令均不支持。
本轮仅定位原因，没有实施 RTL 修复。

## 基线和仿真对照

改宽前快照 `/tmp/cheshire-wide-red-20261019` 的 81 个受跟踪源文件已逐字节核对提交
`5838a512d569e1034be133ffd1502dc9e6755648`，并重新编译仿真。
该快照使用当前准备好的依赖，因此这里的“原版”指该工程基线及其依赖组合。
Ara 依赖提交为 `4e3c586776654a035df9023015e57122f468c433`；本轮检查其 Git diff 为空。

该 Ara 仓库包含已有定制，不能把“工作区干净”等同于“未经修改的最新上游”。
提交 `4e3c5867` 为 FFT 支持修改了 `hardware/src/cva6_accel_first_pass_decoder.sv`，
没有修改 `ara_dispatcher.sv`、`lane_sequencer.sv`、`valu.sv` 或 `masku.sv`。
其中 VALU 接收范围包含 VID 的代码可追溯到 `03cc28ae6`（排列指令支持），
MASKU 不消费 VID 的 ALU 输入可追溯到 `e8c59e3ff`（MASKU 重构）。
当前 VALU、MASKU 文件与该 FFT 定制提交之前的版本逐字节一致。
这里确认的是当前所用 Ara 内部实现的问题，未测试最新上游版本是否仍存在同样缺陷。

| 程序 | 原始工程，2 lane/64 | 修改后 legacy，2 lane/64 | 修改后 wide，4 lane/128 |
| --- | --- | --- | --- |
| 原始连续 VID/比较/mask 序列 | 超时 | 超时 | 超时 |
| 相同 mask，替换 VID 为读取已有 source 数据 | PASS，返回 0 | PASS，返回 0 | PASS，返回 0 |
| 仅重复 VID、无 mask 加法和存储 | 超时，12 次 Ara 请求 | 超时，12 次 Ara 请求 | 超时，12 次 Ara 请求 |
| 同样最小程序，用 VMV 初始化替代 VID | PASS，32 次 Ara 请求 | PASS，32 次 Ara 请求 | PASS，32 次 Ara 请求 |

后三行共执行了 9 次实际仿真。每个程序的同一份二进制分别运行于三个硬件版本。
原始工程 Hello 控制程序也已通过 UART 和输出缓冲区检查。
超时用例没有同步 trap；判定同时检查日志和结果 CSV，不能只看 VCS 退出码。

相同 mask 对照仅把原程序中的 `vid.v v9` 改成 `vle64.v v9,(%2)`，保留随后的
`vand.vi v9,v9,1`、`vmsne.vi` 及所有 masked load/add/store。
source 元素为 `100+i`，每次 VL 最大 32、各块起点为偶数，所以该替换生成完全相同的奇偶 mask。
程序完成全部输出校验，以及其后的原子操作、DMA 和中断检查。

## 源码机制

以下路径均以服务器 Ara 根目录为起点：
`/home/user06/work/xinkailai/cheshire/.bender/git/checkouts/ara-2c7b103275a16c87/hardware`。

| 文件和行号 | 行为及影响 |
| --- | --- |
| `include/ara_pkg.sv:158` | 操作枚举中的 VID 位于 VMSEQ 至 VCOMPRESS 范围内，也位于 VMSBF 至 VMXNOR 范围内 |
| `src/ara_dispatcher.sv:1562` | VID 不需要 vs2 操作数 |
| `src/lane/lane_sequencer.sv:348` | MASKU 指令仍向 lane VFU 发出请求 |
| `src/lane/valu.sv:803` | ALU 以 `[VMSEQ:VCOMPRESS]` 范围接收指令，包含 VID |
| `src/lane/valu.sv:460` | VID 按每次 ELEN=64 个元素的 mask 操作计算 issue 数量；本例每 lane 16 个元素，因此一次产生一份数据 |
| `src/lane/valu.sv:499` | MASKU 指令生成的结果被标记为 mask，进入 ALU 到 MASKU 的通道 |
| `src/masku/masku.sv:1266` | VID 在 MASKU 内执行，不要求 ALU 输入有效 |
| `src/masku/masku.sv:1309` | VID 明确不对 ALU 输入置 ready，额外数据无法在该指令中消费 |
| `src/lane/valu.sv:189` | ALU 到 MASKU 的 spill register 只传送数据，不带指令身份 |
| `src/lane/valu.sv:734` | mask 类型的队首不能通过普通 ALU 到 VRF 写回路径退出 |

## 动态证据

补充检查了 CVA6 到 Ara 的实际握手：CVA6 成功提交 3 次 `vid.v v9`，Ara 入口接受 3 次，
Ara dispatcher 向后端发出 3 次 VID；没有重复或丢失。
三个入口指令编码均为 `0x5208a4d7`，事务 ID 分别为 0、5、2，
每次 Ara 接受时完整 accelerator request 与 CVA6 端逐位相同。
译码结果均为 `vm=1, vl=32, use_vs1=0, use_vs2=0, use_vd_op=0, vd=9`，符合该程序。
因此本例已将故障定位在 Ara 后端内部，未发现 CVA6 或路由器将 VID 请求送错的证据。

使用独立 `mask_observer` 顶层连接原始编译环境，通过层次引用只读观测内部信号。
观察器用影子 FIFO 记录 ALU 提交指令和数据进入 spill 的顺序，再对应 MASKU 消费握手。
它没有驱动 DUT 信号，也没有替换项目模块。

日志记录到：

```text
VID_GENERATE id=0 vl=16 issue=16
PRODUCE op=VID id=0 count=1
CONSUME producer=VID producer_id=0 owner=VMSNE owner_id=0 count=1
```

数值 ID 可被不同指令复用；这里同时记录操作名，所以即使两者 ID 相同也能识别错配。
后续两次 VID 同样产生额外数据，并被 VMSNE 消费。

原始配置 SEW64、VL32、2 lane 下，每轮每 lane 产生 1 份 VID 数据和 16 份 VMSNE 数据，
但 MASKU 只消费 16 份，故每轮留下 1 份。第三轮后，2 份占据 spill，另 1 份比较结果留在 ALU 队列。
后续 VADD 又产生 1 份结果，填满深度为 2 的 ALU 结果队列。

2.2 ms 与 2.7 ms 的快照相同：

- PC 固定于 `0x10000598`，MASKU 正在处理 masked VADD。
- 每 lane 的 ALU 队首为 VMSNE，尚有 1 个元素未提交；队首 mask 标记为 1。
- 每 lane 的结果队列计数为 2，full=1；VADD 尚余 15 个元素未 issue。
- lane0 向 spill 成功送入 50 份、MASKU 消费 48 份，spill 中剩 2 份。
- 加载队列为空，issue/commit 字节计数均为 0；没有待完成 AXI 读写事务。
- 没有观察到 load/store 错误领取其他指令 mask 的握手。

因此当前停顿链条为：VID 多余数据 → 比较输入错位和残留 → spill 满 → ALU 队首无法退出
→ VADD 无法继续 → 当前 mask 指令无法完成。

## 证据位置与复现

- 原始工程对照报告：`/tmp/cheshire-original-mask-check-ljs25g2g/report.json`。
- 内部握手日志：`/tmp/cheshire-original-mask-check-ljs25g2g/diagnostic.log`。
- 只读观察器：`/tmp/cheshire_mask_observer.sv`。
- 原始工程三个软件对照、固件、日志：`/tmp/ara-vid-controls-yzz9zdee/`，汇总 `report.json`。
- legacy/wide 六个软件对照：同一目录下 `legacy/`、`wide/`，汇总 `profiles.json`。
- 临时驱动：`/tmp/cheshire_run_mask_diag.py`、`/tmp/cheshire_run_vid_controls.py`、`/tmp/cheshire_run_vid_profiles.py`。

这些驱动直接复用已编译的仿真环境；不要以 raw bender 或依赖再生成脚本替代。
`report.json`、`profiles.json` 和 `diagnostic_state.json` 均记录硬件状态核对结果。
仿真前后 RTL/依赖指纹一致：

```text
8d6f7e47fec2d65c0b1c470c9c15cf1e39745ffae538b01321ed3818cf3a1239
```

软件替换只是诊断对照，不是项目修复。后续修复应使 VID 在 lane 侧的发射、结果生成和完成记账
与 MASKU 的消费约定一致，不能仅扩大队列来推迟停顿；修复本身及相关指令回归尚未执行。
