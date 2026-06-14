#!/bin/bash
# hanyan-fan v6 — N100 积极散热曲线，不停转
# 参考 Beelink N100 方案，it8628/it8613 芯片，pwm2 控制 fan2
# 修正：边界用 -ge 代替 -gt，曲线更积极
set -e
P1=/sys/class/hwmon/hwmon2/pwm1
P2=/sys/class/hwmon/hwmon2/pwm2
TF=/sys/class/hwmon/hwmon4/temp1_input
echo 1 > ${P1}_enable
echo 1 > ${P2}_enable
while true; do
    T=$(awk '{print int($1/1000)}' $TF)
    if   [ $T -ge 70 ]; then P=255   # 70°C+ → 全速 2766 RPM
    elif [ $T -ge 65 ]; then P=165   # 65-69°C → ~1950 RPM
    elif [ $T -ge 60 ]; then P=120   # 60-64°C → ~1483 RPM
    elif [ $T -ge 55 ]; then P=90    # 55-59°C → ~1146 RPM
    elif [ $T -ge 50 ]; then P=60    # 50-54°C → ~783 RPM
    elif [ $T -ge 45 ]; then P=45    # 45-49°C → ~585 RPM
    elif [ $T -ge 40 ]; then P=30    # 40-44°C → ~371 RPM
    else P=0                          # <40°C → 停转
    fi
    echo $P > $P1
    echo $P > $P2
    sleep 5
done
