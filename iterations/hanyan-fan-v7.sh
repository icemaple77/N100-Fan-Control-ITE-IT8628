#!/usr/bin/env bash
# hanyan-fan v7 — N100 it8628 实测校准 + Beelink 官方方案
# 校准数据 (2026-06-14 实测 it8628, fan2):
#   PWM=0→0RPM  PWM=10→277  PWM=15→609  PWM=30→1391
#   PWM=45→1979  PWM=60→2436  PWM=75→2777  PWM=90→3096
#   PWM=120→3688  PWM=150→4166  PWM=180→4591  PWM=210→4891  PWM=255→5314
#   注意: 此 N100 的 fan2 RPM 远超 Beelink 官方参考值 (PWM=90→1146 vs 我们 3096)
set -e

# 动态路径解析 — 不依赖 hwmon 编号
IT87_BASE=$(echo /sys/devices/platform/it87.*/hwmon/hwmon*)
PWM="${IT87_BASE}/pwm2"
FAN="${IT87_BASE}/fan2_input"
TEMP=$(echo /sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input)

MINSTOP=10
MINSTART=15
INTERVAL=10

enable_manual() {
  echo 1 > ${PWM}_enable
}

disable_manual() {
  echo 2 > ${PWM}_enable
  # 恢复为自动模式，EC 接管
}

calculate_pwm() {
  local temp=$1
  if   (( temp < 40 )); then echo 0    # 停转，彻底静音
  elif (( temp < 45 )); then echo 15   # ~609 RPM 近无声
  elif (( temp < 50 )); then echo 30   # ~1391 RPM 安静
  elif (( temp < 55 )); then echo 45   # ~1979 RPM 可闻不吵
  elif (( temp < 60 )); then echo 60   # ~2436 RPM 清晰可闻
  elif (( temp < 65 )); then echo 90   # ~3096 RPM 偏高转速
  elif (( temp < 70 )); then echo 120  # ~3688 RPM 比较响
  else echo 255                        # ~5314 RPM 全速
  fi
}

# 优雅退出：恢复 EC 自动控制
trap 'disable_manual; exit 0' SIGTERM SIGQUIT SIGINT

enable_manual

while true; do
  TEMP_VAL=$(( $(cat "$TEMP") / 1000 ))
  PWM_VAL=$(calculate_pwm "$TEMP_VAL")

  if (( PWM_VAL == 0 )); then
    # 停转：先降到最低稳定转速再关
    CURRENT=$(cat "$PWM")
    if (( CURRENT > 0 )); then
      echo $MINSTOP > "$PWM"
      sleep 0.5
      echo 0 > "$PWM"
    fi
  else
    # 启动或调速
    CURRENT=$(cat "$PWM")
    if (( CURRENT == 0 )); then
      # 从停转启动：先 kick-start
      echo $MINSTART > "$PWM"
      sleep 0.5
    fi
    echo $PWM_VAL > "$PWM"
  fi

  sleep $INTERVAL
done
