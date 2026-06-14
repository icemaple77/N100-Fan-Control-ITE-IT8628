# N100 迷你主机风扇控制 (ITE IT8628)

适用于 Intel N100 (Alder Lake-N) 迷你主机的 Linux 风扇控制脚本。
驱动 ITE IT8628 Super I/O 芯片，通过 `/sys/class/hwmon` sysfs 接口手动控制 PWM。

## 适用机型

- Intel N100 / N95 / N150 迷你主机（白牌 / Beelink / GMKtec / 零刻等）
- Super I/O 芯片: ITE IT8628 / IT8613 / IT87 系列
- 系统: Ubuntu / Debian / Fedora / Proxmox 等 Linux 发行版
- 内核: 6.x（主线内核自带 it87 驱动，无需额外 DKMS 模块）

## 背景

这类 N100 小主机的 BIOS/EC（嵌入式控制器）默认风扇策略偏保守，
待机温度不高时风扇转速也偏高（49°C 可达 3100+ RPM），噪音明显。

手动控制 PWM 可以显著降低待机噪音，同时保留高负载时的散热能力。

### 注意事项

**IT87 芯片存在已知的 0→non-0 状态机问题：**
PWM 完全停转（写入 0）后重新启动，有概率导致芯片状态异常，
风扇会锁死在 3000+ RPM 并忽略后续写入。

**解决方案：最低 PWM 设为 20（~931 RPM），永不彻底停转。**
931 RPM 几乎听不见，且完全避开状态机 bug。

## 实测 PWM-RPM 校准 (IT8628)

| PWM | RPM   | 噪音感受     |
|-----|-------|------------|
| 0   | 0     | 停转（不推荐）|
| 10  | 277   | 近无声     |
| 15  | 609   | 近无声     |
| 20  | 931   | 几乎听不见 |
| 30  | 1391  | 安静       |
| 45  | 1979  | 可闻       |
| 60  | 2436  | 清晰       |
| 75  | 2777  | 明显       |
| 90  | 3096  | 较响       |
| 120 | 3688  | 很响       |
| 150 | 4166  | 吵         |
| 180 | 4591  | 很吵       |
| 255 | 5314  | 全速       |

> 注：此 RPM 值是 IT8628 + N100 的实测结果。
> 不同机型/风扇的 PWM-RPM 映射可能不同。建议在自己的机器上校准。

## 温度曲线

当前脚本采用线性连续曲线：

```
50°C → PWM=20  (~931 RPM)    最低转速
55°C → PWM=53  (~1104 RPM)   近静音
60°C → PWM=87  (~1813 RPM)   安静
65°C → PWM=120 (~2500 RPM)   可接受
70°C → PWM=154 (~3209 RPM)   充分散热
75°C → PWM=187 (~3896 RPM)   强力散热
80°C → PWM=221 (~4605 RPM)   全速逼近
85°C → PWM=255 (5314 RPM)    紧急全速
```

### 特性

- **永不停转**：最低 PWM=20，完全避开 IT87 状态机 bug
- **线性连续**：PWM 随温度连续变化，无阶梯跳变
- **3°C 滞后**：降温时滞后 3°C 才降档，防止边界振荡
- **双步进**：升温 40 PWM/步（快速响应），降温 15 PWM/步（平滑过渡）
- **85°C 紧急**：温度 ≥85°C 直接全速，<80°C 恢复正常
- **自恢复**：检测到异常转速（>2800 RPM 且 PWM<100）连续 6 次则自动重置 PWM 通道
- **安全退出**：收到 SIGTERM 时先写全速再释放 EC 控制权，防止闷烧

## 安装

### 1. 确认驱动已加载

```bash
lsmod | grep it87
sensors
```

如果 `sensors` 没有显示 it8628/it8613/it87，加载驱动：

```bash
sudo modprobe it87 force_id=0x8628
```

持久化：

```bash
echo "options it87 force_id=0x8628" | sudo tee /etc/modprobe.d/it87.conf
echo "it87" | sudo tee /etc/modules-load.d/it87.conf
```

### 2. 安装脚本

```bash
sudo cp hanyan-fan.sh /usr/local/bin/hanyan-fan
sudo chmod 755 /usr/local/bin/hanyan-fan
```

### 3. 安装 systemd 服务

```bash
sudo tee /etc/systemd/system/hanyan-fan.service << 'EOF'
[Unit]
Description=N100 Fan Control (ITE IT8628)
After=sysinit.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hanyan-fan
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now hanyan-fan
```

### 4. 验证

```bash
systemctl status hanyan-fan
journalctl -u hanyan-fan --no-pager -n 10
```

## 自定义校准

如果你的机器 PWM-RPM 映射不同，可以自行获取校准数据：

```bash
sudo bash -c '
for p in 0 15 30 45 60 75 90 120 150 180 210 255; do
  echo $p > /sys/class/hwmon/hwmon2/pwm2
  sleep 10
  rpm=$(cat /sys/class/hwmon/hwmon2/fan2_input)
  echo "PWM=$p → ${rpm} RPM"
done
'
```

然后修改脚本中的 `linear_pwm()` 或直接调整 `TEMP_MIN`、`TEMP_MAX` 参数。

## 文件结构

```
├── hanyan-fan.sh      # 风扇控制脚本
├── README.md          # 本文件
└── pwm-calibration.md # 校准数据记录
```

## License

MIT
