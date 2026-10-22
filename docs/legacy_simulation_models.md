# 旧单 SoC 平台的外部仿真模型

## 使用范围

`target/sim/src/vip_cheshire_soc.sv` 实例化 SPI Flash `s25fs512s` 和 I2C EEPROM `M24FC1025`，由旧 `tb_cheshire_soc` / `fixture_cheshire_soc` 使用。

当前多 tile 平台使用 `tb_multitile` / `vip_multitile`，配置函数 `tile_cfg()` 将 `I2c` 和 `SpiHost` 设为 0，不实例化上述模型。FPGA 综合也不使用这两个行为模型。

但 `Bender.yml` 的 `any(simulation, test)` 文件组仍同时包含这两个模型和旧 VIP；多 tile runner 选择 simulation/test target 后会带入它们。因此，在源码清单尚未拆分前，模型文件仍是源列表生成的前置条件。这是清单耦合，不是当前多 tile 工作负载的功能依赖。

本次只调整文档，没有修改 Bender target 或删除旧平台。

## 自动获取

`cheshire.mk` 保留了上游模型下载规则，当前没有修改。首次仿真前在仓库根目录执行：

```bash
make chs-sim-all
```

Make 按需调用 wget 获取 Flash 文件和 EEPROM ZIP，再用 unzip 提取 EEPROM 模型，同时生成传统仿真编译脚本。Python 多 tile runner 不会自动调用此 Make 入口。

EEPROM 规则中的 `wget -o` 指定日志文件，ZIP 默认下载到当前目录，随后解压输出覆盖该日志文件。这个写法不直观，但仅凭 `-o` 不能认定自动下载有误；需要根据真实下载和解压结果判断。

## 手动获取：下载异常时的补救

两个文件不由 Bender 获取，也未提交主仓库。文件已存在且校验正确时不需要重新下载。
遇到实际网络、证书或解压错误时，可使用以下显式下载过程。需要 curl 和 Python 标准库 zipfile。
FMF 在当前服务器上存在证书链兼容问题，`-k` 仅用于这个下载，随后必须通过固定 SHA-256 校验；不关闭其他连接的证书或 SSH 主机身份验证。

在仓库根目录执行：

```bash
mkdir -p target/sim/models
curl -k -fL --retry 3 --connect-timeout 20 \
  https://freemodelfoundry.com/fmf_vlog_models/flash/s25fs512s.v \
  -o target/sim/models/s25fs512s.v
curl -fL --retry 3 --connect-timeout 20 \
  https://ww1.microchip.com/downloads/en/DeviceDoc/24xx1025_Verilog_Model.zip \
  -o target/sim/models/24xx1025_Verilog_Model.zip

python3 - <<'PY'
from pathlib import Path
from zipfile import ZipFile
models = Path('target/sim/models')
with ZipFile(models / '24xx1025_Verilog_Model.zip') as archive:
    files = [name for name in archive.namelist() if Path(name).name == '24FC1025.v']
    assert len(files) == 1, files
    (models / '24FC1025.v').write_bytes(archive.read(files[0]))
PY

printf '%s\n' \
  '067dbb37a2b44816441af6da698b96ab8587ee5a645800604702f731ea9172ea  target/sim/models/s25fs512s.v' \
  'a81600ee6afb2ee9c4e0d67b6ab640136c7cef5f250d911d5f3bacaca80c009e  target/sim/models/24FC1025.v' \
  | sha256sum -c -
```

模型保留各自许可证。若校验失败，应核对供应商版本或下载错误，不应将 HTML 错误页、空文件或临时 stub 当作真实模型。
