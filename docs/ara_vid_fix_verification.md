# Ara VID 修复与验证

日期：2026-10-20。实际修改和仿真位置：`/home/user06/work/xinkailai/cheshire`。
主仓库起点 `6e0b4f8`，Ara 起点 `4e3c586776654a035df9023015e57122f468c433`。

## 根因与修复

官方 V 1.0 的 [VID 定义](https://docs.riscv.org/reference/isa/v20260120/unpriv/v-st-ext.html#30-1-15-9-vector-element-index-instruction)
要求活跃元素写入自身索引，mask 不改变索引编号。规范不限定 ALU/MASKU 的实现分工。
当前 Ara 由 MASKU 生成索引，并明确不消费 VID 的 ALU 输入；但 VALU 的指令范围包含 VID，
产生额外数据，破坏后续比较操作的输入对应关系并填满结果队列。
原始定位证据保留在 [诊断报告](ara_mask_repro_diagnosis_2026-10-19.md)。

本次仅改 Ara 两处条件，共 4 行新增、2 行替换：

| Ara 文件 | 修改 |
| --- | --- |
| `hardware/src/lane/valu.sv:804` | 接收条件排除 VID，避免产生没有消费者的 ALU 结果 |
| `hardware/src/ara_sequencer.sv:275` | VID 仅计入 MASKU 目标，不占用 ALU 指令队列、不等待 ALU 完成通知 |

必须同时修复发射和队列记账。仅禁止 VALU 执行而仍增加 ALU 队列计数，会留下无法完成的占用。
MASKU 的索引生成、mask/byte-enable、正常完成路径均保持不变。
CVA6、加速器路由器、总线、FFT 和其他依赖均未为此修改。

## 红绿验证

新测试 `sw/tests/ara_vid_regression.c` 在修改 RTL 前完成编译，并在旧 legacy/wide 模型上运行：
两者均在 12 次 Ara 请求后 watchdog 超时，没有同步 trap。
随后使用修复 RTL 重新编译两个完整系统模型，同一份测试二进制通过。
前后软件 SHA-256 比较、硬件指纹和结果汇总见 [机器记录](ara_vid_fix_verification.json)。

| 工作负载 | legacy：2 lane / AXI64 | wide：4 lane / AXI128 |
| --- | --- | --- |
| VID 指令与数据回读，217 个场景 | PASS | PASS |
| 原始 mask overlap 程序，不改变指令序列 | PASS，91 次 Ara 请求、返回 0 | PASS，91 次 Ara 请求、返回 0 |
| Hello，UART 38 字节及 64 字节缓冲读回 | PASS | PASS |
| 内部入队/issue/结果生成/计数断言 | PASS | PASS |

217 个场景包括：16 轮 VID→无 mask 加法→存储；五组 SEW/LMUL 配置各 40 个 masked VID 场景；
以及一组邻接 mask 指令检查。五组配置为 SEW8/16/32/64 的 LMUL1，以及 SEW64 的 LMUL2。
每组覆盖 VL=0/1/3/VLMAX-1/VLMAX、全零/全一/交替/跨字节边界 mask，以及 tu/mu、ta/ma。
严格检查活跃索引，undisturbed 元素保持初始值；agnostic 元素只接受初始值或全 1；VL0 不改任何元素。
邻接指令包括 VMSNE、VIOTA、VCPOP、VFIRST、VMSBF、VMSOF、VMSIF。

独立观察顶层 `target/sim/src/tb_ara_vid_monitor.sv` 不驱动 DUT，直接检查：

- VID 到达 lane 时，VALU 指令队列的接收指针不增加。
- 各 lane 的 ALU issue 头和结果生成路径不执行 VID。
- 全局指令队列不为 VID 增加 ALU 占用。
- 原始 overlap 程序完整执行 5 条 VID，结束时 ALU 指令占用为 0。

因此通过标准同时包括程序结果、进度及内部记账，不能仅以 VCS 退出码判断；VCS 的 fatal 即使返回 0，
验证入口仍会因日志/结果校验判失败。
另外，Python 工具测试完成 41 项，34 项通过、7 项因当前 Python 无 NumPy 跳过。
独立只读审查未发现待处理的修复缺陷。

## 复现入口

```bash
cd /home/user06/work/xinkailai/cheshire
python3 util/run_ara_vid_regression.py --out /tmp/ara-vid-recheck
```

该入口会新建 legacy/wide 模型，依次执行 VID、原始 overlap、Hello，以及内部观察器检查。
只测一种配置可加 `--profile legacy` 或 `--profile wide`。输出目录应使用新的路径。
它通过受保护的 `util/rom_bender.py` 构建，不重置或重新生成依赖。

本轮实际证据目录：

- `/tmp/ara-vid-fix-20261020/red/`：修复前失败，包含相同测试固件。
- `/tmp/ara-vid-fix-20261020/green_legacy/legacy/{vid,overlap,hello}/`：修复后结果。
- `/tmp/ara-vid-fix-20261020/green_wide/wide/{vid,overlap,hello}/`：修复后结果。
- 上述两个 profile 下的 `monitor_v2/`：最终严格入队观察器结果。

## 依赖修复保存

实际改动位于 `.bender/git/checkouts/ara-2c7b103275a16c87/`。
对应精确补丁保存在主仓库 [ara-4e3c5867-vid-masku-only.patch](../util/patches/ara-4e3c5867-vid-masku-only.patch)。
补丁内容已与 Ara 的实际 diff 逐字节核对。原 `deps/prepared/2026-10-20/` 是修复前快照，保留其历史内容。
在新建工程恢复该快照后，需要额外应用此补丁；当前服务器工作区已应用，不要重复执行。
未改写 Bender.lock，也未切换、重置或重新生成任何依赖。

## 范围

本次解决已复现的 VID 额外数据和 ALU 记账问题，不宣称验证完整 RVV 指令集。
非零 vstart、分数 LMUL、完整异常/上下文切换覆盖不在本轮范围内。
没有重新综合、生成 bitstream 或实际上板；物理 FPGA 中的旧 bitstream 不会因源码修复自动改变。
