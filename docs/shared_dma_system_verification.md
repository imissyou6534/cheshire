# 真实 CVA6 共享 DMA 系统验证

本文件记录 `/home/user06/work/xinkailai/cheshire` 中的系统级 RTL 仿真。测试包含实际 CVA6 执行裸机 ELF，DDR 使用 AXI 内存模型；不是 FPGA 或物理 DDR 验证。

## 系统组成与启动

- `multi_tile_top` 实例化所有 Cheshire/CVA6、私有 CSR/PLIC 和共享 DMA。
- 系统配置使用 CVA6 标准 WB cache，32 KiB D-cache、16 字节 cache line；所有 tile 和 DMA 共用同一 RTL 时钟。
- LLC bypass 不提供旧 LLC 内 SPM，因此程序、栈和缓冲均位于 DDR。
- 每个程序入口为 `0x80000000 + tile * 0x100000`，每个 ELF 的代码、数据和栈使用独立 256 KiB 区间。
- `TileBootStride` 默认 0；系统测试配置关闭 Bootrom、设置 DDR PlatformRom，并使用 1 MiB 入口步长。生产默认启动方式不变。
- 测试台在复位期间用项目原有 `elfloader.cpp` 装载各 ELF；释放复位后由 CPU 自行取指。测试台不强制 PC、不提交 DMA 命令、不注入完成或中断。
- 项目 CRT 保存 24 字节上下文；专用 linker 将初始 SP 设为区间末端减 8，使进入 C 和 trap wrapper 时保持 16 字节对齐。

## 已验证结果

| 场景 | 结果 | 硬件/软件证据 |
| --- | --- | --- |
| 四个 CVA6 独立启动 | PASS | 各 tile 身份、入口 PC、97/96/96/97 条退休指令及正常退出 |
| 4 tile × 2 engine 完整工作负载 | PASS | 20 个 Job、同时活动 engine 峰值 2、每 tile 5 个接受及消费事件 |
| 2 tile × 1 engine 完整工作负载 | PASS | 10 个 Job、活动 engine 峰值 1 |
| 缺少 post-DMA cache 失效的反例 | PASS，成功检出错误 | tile0 返回 `0x74`；DDR 正确，CPU 仍读到旧 `0xA5` |
| CPU MEIE 关闭的反例 | PASS，成功检出选择性屏蔽 | 全局 MIE=1、MEIE=0；DMA 数据正确且机器 PLIC 中断 pending，tile0 返回 `0x75` |

4×2 正向验证中，各 tile 均实际完成两次 PLIC claim(58)/complete(58)。采样到 30 次 flush-ack、约 17,000 个 phase-4 cache-enable 周期，以及 74 个 phase-4 cache 写回事务。各 CPU 退休约 367,700 条指令。

严格复测还检查了每条已退休 load 写回结果不含 X。4×2 每 tile 校验约 15,970 条退休 load，实际使用字节和退休结果中的未知值为 0。

测试台另外独立检查每 tile 的源和目标共 32 KiB DDR 内容、二维间隙和保护字节、五个提交/完成 ID、engine/status、软件结果元数据及所有阶段的共享 barrier 计数。软件退出码不是唯一通过条件。

## 工作负载

每个 CPU 使用 `B=0x84000000+tile*0x10000` 的独立缓冲区，执行五个 Job：

| 阶段 | 操作 |
| --- | --- |
| 1 | 启动、准备缓冲与同步状态 |
| 2 | 所有 CPU 通过 AMO barrier 后并发提交 4096 字节复制，轮询完成 |
| 3 | 非对齐 ND：每行 67 字节、4 行、源 stride 128、目标 stride 256；提交后改写 Shadow CSR，验证旧快照不变 |
| 4 | 启用真实 WB cache，写脏 source/destination，执行 clean/drain；预先缓存目标旧值，DMA 512 字节后执行失效并校验 |
| 5 | 配置 PLIC/MIE，两次 512 字节 Job 经实际 CPU trap handler 消费完成，验证 IRQ 清除和 PLIC rearm |
| 6 | AMO barrier 与各 CPU 读取其他 tile 的结果元数据，验证提交顺序、完成 ID、IRQ、cache 和发布状态 |
| 7 | 写最终状态并正常退出 |

同步区为 `0x88000000`；所有同步字通过实际 RISC-V AMO 访问，每个阶段使用独立的单调 barrier 计数。不能以 `volatile` 普通缓存 load 代替这些同步操作。

## PLIC 接入修正

原生成文件只有 32 源、1 target；原 Cheshire 配置要求 58 源、2 targets。共享 DMA 的外部源编号为 58，因此必须至少 59 源。

本次将 `hw/rv_plic.cfg.hjson` 改为 64 源、2 targets，并新增定向、可重复的 PLIC 生成检查脚本。SoC 使用显式零扩展将中断向量连接到生成 PLIC，避免取超出 packed vector 的位而产生 X。

各 tile 的本地 `mhartid` 都为 0，因此各自使用 M-context 0：

| 寄存器 | 地址/内容 |
| --- | --- |
| DMA source 58 priority | `0x040000E8 = 1` |
| M-context enable word 1 | `0x04002004`，bit 26 |
| M-context threshold | `0x04200000 = 0` |
| M-context claim/complete | `0x04200004`，claim 返回 58，complete 写回 58 |

Handler 覆盖普通 C `trap_vector`，由项目 CRT 保存整数寄存器并执行 `mret`。先消费/POP DMA 完成，再 complete PLIC。外部 IRQ 为电平信号，仅 complete PLIC 不能清除 DMA 队列非空状态。

只验证 M-context；没有验证 S-mode/多 context 软件 DIF。原 DIF 的非零 target stride 问题不在本次修改范围内。

## Cache 维护依据

所选 CVA6 WB 配置启用 `DcacheFlushOnFence=1`，实际 `fence iorw,iorw` 会 clean 并 invalidate 整个 D-cache。这是该目标的行为，不能泛化为所有 RISC-V fence 都支持 cache 维护。

Cache flush-ack 可能早于最后一个写回 B 响应，因此 `shared_dma_cva6_wb_handoff` 在 fence 后执行私有、只读、cacheable guard load。该 cache miss 经同一 cache adapter 等待在途写响应。测试台检查 cache 阶段 DMA 读取 source 前，CPU cache 写回 B 已排空。

CSR `0x7C1` 控制 D-cache enable，`0x7C0` 控制 I-cache enable。关闭 D-cache 本身不进行 clean，关闭前必须维护和排空。正向测试在 DMA 拥有 destination 期间不写目标 cache line。

缓存反例故意省略完成后的维护，不改 DMA RTL：DDR 目标已是新数据，CPU 的 clean-but-stale cache line 仍含 `0xA5`。测试台只在这个精确反例和正确 DDR 数据同时出现时报告负例 PASS。

## 原始读数据告警

上游 `axi_sim_mem` 在窄 AXI 访问中只填充请求字节，其余字节保持 X；`UninitializedData="zeros"` 只规定被请求但未初始化的内存字节，不会把未请求 lane 改为零。CVA6 WB 的 `a_invalid_read_data` 原始断言检查整个 64 位字，因此这些未请求 lane 会产生告警。

本次保留原始内存模型和上游告警，没有填零掩盖它们。新增检查使用 cache controller 保存的响应请求地址/size 选出有效字节，禁止其为 X；还要求每条非异常、写目的寄存器的退休 load 的完整结果不含 X。未请求 lane 的未知值单独计数，4×2 每 tile 为 15,275 次；killed unknown 为 0，live unknown 为 0。

因此结果是功能检查通过，不是原始上游全字宽断言日志无告警。`SYSTEM readcheck` 统计可用于区分这些情况。

## 复现命令

以下命令均在服务器项目目录执行：

```bash
cd /home/user06/work/xinkailai/cheshire

# 默认完整系统：4 个实际 CPU、2 个 DMA engine
bash util/run_shared_dma_system.sh

# 两个实际 CPU 共享一个 engine
DMA_SYSTEM_TILES=2 DMA_SYSTEM_ENGINES=1 \
  bash util/run_shared_dma_system.sh

# 保留独立 ELF 启动冒烟测试
DMA_SYSTEM_SMOKE=1 bash util/run_shared_dma_system.sh

# 应检出 CPU 旧 cache 数据
DMA_SYSTEM_NEGATIVE=cache bash util/run_shared_dma_system.sh

# 应检出未处理的外部中断，DMA/PLIC 仍 pending
DMA_SYSTEM_NEGATIVE=irq bash util/run_shared_dma_system.sh
```

脚本自动准备 DMA 依赖补丁、检查/生成正确 PLIC、编译每个裸机 ELF、生成分组 VCS 编译命令并运行系统仿真。编译需要 `riscv64-unknown-elf-gcc`、Bender、VCS，以及 PLIC generator 的 Python 依赖。

```bash
# 只检查 PLIC，不写生成文件
bash util/prepare_shared_dma_plic.sh --check

# 构建已停止且需要重新生成 PLIC 时
bash util/prepare_shared_dma_plic.sh --regenerate

# 原有 AXI 驱动的 DMA 单元回归仍保留
DMA_TEST_SHAPES=4:2 bash util/run_shared_dma_tests.sh
```

## 日志与通过判据

输出目录为 `target/shared_dma_system/<tiles>x<engines>/<mode>/`。mode 为 `none`、`boot`、`cache` 或 `irq`；每个目录含 `elf/tileN.elf`、`build.log`、`run.log` 和 `simv`。

```bash
tail -n 30 target/shared_dma_system/4x2/none/run.log
grep 'SYSTEM evidence\|PASS real CVA6' \
  target/shared_dma_system/4x2/none/run.log
```

正向应出现：

```text
PASS real CVA6 system 4 tiles x 2 engines peak=2 jobs=20
```

缓存负例应出现 `PASS real CVA6 negative cache`；中断负例应出现 `PASS real CVA6 negative IRQ`。普通软件错误、错误阶段、DDR 数据错误或 watchdog timeout 都不能当成预期负例通过。

脚本始终重新编译 RTL/测试台及 ELF；`DMA_SYSTEM_SKIP_BUILD=1` 已移除并会被拒绝，防止旧 simv 绕过新检查。默认 DMA/IRQ 等待期限为 200,000 个 CPU 周期，可用 `DMA_SYSTEM_TIMEOUT_CYCLES` 指定；系统仿真 watchdog 为 20 ms。

所有 tile 的本地 hart 编号为 0，原 CVA6 tracer 使用同名 `trace_hart_0.log`；不要把它当成单个 tile 的独立 trace。按 tile 区分的 PC、退休计数及验证统计位于 `run.log`。

## 边界

通过的是带实际 CPU、缓存、PLIC 和软件的 RTL 全系统仿真。没有验证物理 DDR、FPGA 综合时序、板级启动、Linux/S-mode、cache snoop 一致性、独立复位或超时取消。DDR 模型仍有既定复位限制。多个核保持非硬件一致性，缓冲的 cache-line 所有权仍由软件保证。
