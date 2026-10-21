# 分层总线位宽 RTL 实施与验证记录

日期：2026-10-19，Asia/Shanghai。

服务器工程：`/home/user06/work/xinkailai/cheshire`，基线提交 `5838a51`。
FFT原始生成器：`/home/user06/work/dblclockfft`，保留其已有工作区修改并扩展 `sw/fftgen.cpp`。

本次已修改RTL、生成器及验证入口，没有运行FPGA综合/实现、生成新bitstream或实际上板。
设计合约见 [总线设计](superpowers/specs/2026-10-19-mixed-width-bus-design.md)。

## 1. 已实施结构

| 部分 | 位宽/配置 |
| --- | --- |
| CPU/cache原生AXI | 64，ID映射后64→128 |
| Ara | 4lane，VLEN2048，AXI128 |
| FFT | 双采样软乘法4096点，输入每实虚分量16位，输出各23位，自然顺序 |
| FFT AXI | 128，保留64位legacy工作模式 |
| Tile/SPM AXI | 128，SPM容量131072字节 |
| SPM几何 | 8ways ×256lines ×4blocks ×16bytes |
| iDMA | 128，控制口宽度独立于engine数据宽度 |
| Shared fabric | 256，各Tile/engine独立转换后进入xbar |
| Debug/SBA | 64，主从路径分别适配 |
| 外设桥/Reg/ROM | 局部AXI64，Reg32，ROM32 |
| VCU118 DDR wrapper | Shared256→MIG512，原ID转换及CDC保留 |

新增Core/Ara/FFT/Debug宽度配置，保留旧64位profile；统一仿真默认wide，
使用 `--bus-profile legacy` 可显式选择旧profile。

## 2. FFT来源与接口

原始生成器现支持 `-U -2 -f 4096 -n 16 -p 0 -S`。
方向按任务锁存，在该任务全部输入和排流水线期间保持稳定；任务之间复位。
历史 `fft-core/fftifft-4096` 生成目录没有被覆盖。
生成来源、源码hash及前后工作区diff记录见
[FFT provenance](../util/tests/fft_dual_runtime_provenance.md)。

软件START/WAIT、方向编码、实数int16输入和64位复数结果布局保持不变。
固定数值参考为FFT/32，IFFT为NumPy IFFT×4096/32。

FFT不再使用 `axi_from_mem` 的AXI-Lite单拍路径，而是原生INCR burst，最大16拍，
按4KiB拆分，支持源/目的模16偏移0或8。首尾64位访问与中间128位访问按真实byte lane打包。
完成必须等待最后B；错误后保留已置VALID和已接受的事务，排空后再报告并允许下一任务。

本次采用保守并发：最多一个读burst和一个写burst在途；输入16拍缓冲、输出64个结果对。
没有实现原设计候选的四读/四写并发，也没有宣称系统达到裸核吞吐上限。

## 3. 测试结果

### 原始算术核

`bash util/tests/run_fft_dual_runtime_numeric.sh /home/user06/work/dblclockfft`

- 16帧通过：DC、复数偏移冲激、实数多音、复数随机输入，FFT/IFFT及连续/暂停CE。
- 全4096个自然顺序复数结果与独立浮点参考比较。
- 最大分量绝对误差4.58595；CE暂停与连续结果逐位一致。
- 新生成模块和20份even/odd系数与导入版本一致；顶层系数路径宏lint通过。

### FFT AXI传输

```bash
python3 util/run_fft_burst_adapter_test.py --build-root /tmp/fft-burst-final-20261019
python3 util/run_fft_burst_adapter_test.py --real-core --build-root /tmp/fft-burst-real-20261019
```

- 21个传输/错误场景通过，包括64/128位、源/目的四种偏移组合、随机AR/AW/R/W停顿及延迟B。
- 9个错误后恢复场景通过：错误后不复位，继续成功执行相反方向任务。
- 16个实际FFT核传输数值场景通过，固定/32参考，分量误差门限8。
- 覆盖AR/AW VALID阻塞时错误、AW已接受但W被阻塞、读错误和写错误，以及最终B前不得完成。

### 共享DMA/fabric

`SHARED_WIDTH_BUILD_ROOT=/tmp/shared-width-complete-20261019 bash util/run_shared_dma_widths.sh`

| Tile/DMA/Shared宽度 | 结果 |
| --- | --- |
| 128/128/256 | PASS |
| 128/64/256 | PASS |
| 64/64/64，零值继承参数 | PASS |

覆盖CSR全部32位lane、窄/完整burst、随机停顿、非对齐长度1/7/8/15/16/17/33、6000字节跨页、
2D stride、保护字节、最后B延迟及R/B错误。Shared拍各位置的AMO.W/D、LR/SC和DMA干扰均通过。

### 真实CVA6系统

输出根目录：`target/sim/build/wide_bus/`。

| 输出子目录 | 配置/工作负载 | 结果 |
| --- | --- | --- |
| `spm_1x1` | wide，1Tile/1DMA，外部AXI加载，Ara4 Hello和64字节buf读回 | PASS |
| `spm_2x2` | wide，2Tile/2DMA，每Tile UART和buf检查 | PASS |
| `spm_4x2` | wide，4Tile/2DMA，每Tile UART和buf检查 | PASS |
| `rom_2x1` | wide，2Tile/1DMA，ROM复制/校验/跳SPM，无外部程序写入 | PASS |
| `legacy_memory` | legacy64，1Tile/1DMA，Ara2 Hello | PASS |
| `integrated_memory` | wide，CPU/Ara/原子/DMA/PLIC综合工作负载 | PASS |
| `fft_ddr/fft` | wide，2Tile/2DMA，每Tile三组4096点实数FFT DDR回读 | PASS |
| `fft_ddr/ifft` | 同上，IFFT | PASS |

`integrated_memory`是从共用硬件缓存运行后复制保存的结果和固件；源程序为
`sw/tests/wide_bus_memory.c`。该测试通过SEW8/16/32/64单位步长、stride、CPU各32位SPM lane
AMO.W、SPM两别名LR.D/SC.D，以及CPU提交ND DMA、PLIC claim58/第二次claim0、完成POP与数据/间隙检查。
该测试有意关闭D-cache，不声称覆盖所有缓存一致性或M-mode trap handler情形。

FFT/IFFT六组SNR约78.49～83.09dB，FFT最大复数绝对误差约5.754。
每Tile三任务实际观测：读长burst96笔、写长burst384笔、B384笔、写有效字节98304。
DDR回读从128位Tile端口按地址提取64位结果，不截断高半拍。

当前默认Hello固件自身包含 `ni hao a, 1017!` 前缀；UART期望更新为完整38字节，
buf期望仍是Hello字符串及零填充。没有修改该应用来回避检查。

### VCU118顶层RTL模型/JTAG

`python3 util/run_wide_board_smoke.py`

`target/sim/build/wide_bus/board/report.json`记录：

- 1x1真实JTAG ROM读、hart停核、SPM ELF下载、恢复执行与EOC通过。
- 全38字节UART及64字节buf检查通过。
- CPU64/Debug64、Tile128、DMA128、Shared256及MIG512类型断言通过。
- Debug SBA读写经过真实转换器；DMA DDR复制及PLIC source58通过。
- 2x2 JTAG串链和UART连接检查通过。

这使用时钟/MIG仿真模型，不是物理DDR或板级结果。

### 主机/构建检查

- 系统Python：41项测试完成，34通过、7项因无NumPy跳过。
- Anaconda NumPy Python：上述7项FFT参考/解析测试全部通过。
- 新混合配置SV断言通过：CPU64、Ara4/128、FFT128、Tile128、SPM128KiB、Debug64。
- 旧RTL上已先复现缺少宽度参数/64位限定导致的失败，再实现对应功能。
- 只读独立RTL审查未发现确认的目标配置协议或类型缺陷。

## 4. Ara VID 历史停顿与修复

新增的连续mask序列 `vid/vand/vmsne → masked vle64 → masked vadd → masked vse64`
曾在修复前的Ara依赖中停顿。wide4lane/128与legacy2lane/64均在同一序列位置超时，
且无同步异常；因此不是已证明的128位改宽独有回归。
源对齐到4KiB或插入fence也未消除停顿。后续确认是 VID 多余 ALU 数据与 MASKU 消费不匹配。

2026-10-20 已修复 VID 的 VALU 接收及全局 ALU 队列记账。原始程序在两个 profile 均通过，
各完成 91 次 Ara 请求并返回 0；另有 217 个 VID 场景及内部断言通过。
详见 [VID修复记录](ara_vid_fix_verification.md) 和主仓库保存的 Ara 补丁。

复现源：`target/sim/sw/ara_mask_overlap_repro.c`。
原始失败证据：`target/sim/build/wide_bus/mask_overlap_repro/{wide,legacy}/`。

```bash
python3 util/run_multitile_sim.py --boot spm --tiles 1 --dmas 1 \
  --app target/sim/sw/ara_mask_overlap_repro.c --require-ara \
  --sim-timeout-ns 5000000 --out target/sim/build/wide_bus/mask_repro_new
# 加 --bus-profile legacy 可比较旧宽度profile；已修复的 Ara 下两者均应通过。
```

2026-10-19 最初记录未修改依赖、未将该序列计为通过；2026-10-20 的修复已修改准备好的 Ara
两处条件并保存精确补丁。不宣称所有RVV指令、mask重叠调度、indexed访问或Linux工作负载均已验证。

## 5. 复现主要系统检查

```bash
cd /home/user06/work/xinkailai/cheshire
python3 util/run_multitile_sim.py --boot spm --tiles 2 --dmas 2 --uart-tiles all \
  --out target/sim/build/wide_bus/spm_2x2
python3 util/run_multitile_sim.py --boot rom --tiles 2 --dmas 1 --uart-tiles all \
  --out target/sim/build/wide_bus/rom_2x1
python3 util/run_multitile_sim.py --boot spm --app sw/tests/wide_bus_memory.c \
  --require-ara --out target/sim/build/wide_bus/memory_fresh
/opt/anaconda3/bin/python util/run_fft_ddr_test.py --tiles 2 --dmas 2 \
  --out target/sim/build/wide_bus/fft_ddr
/opt/anaconda3/bin/python util/run_fft_ddr_test.py --tiles 2 --dmas 2 --mode ifft \
  --reuse-build --out target/sim/build/wide_bus/fft_ddr
```

始终使用受保护的 `util/rom_bender.py`，不要运行历史raw bender或依赖patch/regenerate脚本。
系统报告包含工具、固件hash、宽度profile和依赖HEAD，要求仿真过程中hardware_unchanged为true。

## 6. 交付与限制

服务器为实际RTL交付位置。本地编辑副本位于
`C:/Users/C/AppData/Local/Temp/cheshire-wide-20261019`；没有用服务器版本覆盖Windows旧工作区的RTL改动。
原始FFT生成器原有修改保留，仅在既有 `sw/fftgen.cpp` 上追加双采样方向支持。

没有提交Git、重置依赖、覆盖历史生成目录、构建新bitstream或进行FPGA时序/资源签核。
现存bitstream仍是旧硬件；新设计的综合频率、面积、物理DDR吞吐和板级启动需后续验证。
