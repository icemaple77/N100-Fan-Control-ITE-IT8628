#!/usr/bin/env bash
# hanyan-fan v8.0 — N100 it8628 稳定优先版
# 核心思想：永不停转，完全避开 it87 0→启动状态机问题
# 实测校准 (2026-06-14):
#   PWM=0→0  10→277  15→609  20→931  30→1391  45→1979
#   60→2436  75→2777  90→3096  120→3688  150→4166  255→5314 RPM
set -e

# --- 动态路径 ---
IT87_BASE=$(echo /sys/devices/platform/it87.*/hwmon/hwmon*)
PWM="${IT87_BASE}/pwm2"
FAN="${IT87_BASE}/fan2_input"
TEMP=$(echo /sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input)

# --- 参数 ---
MIN_PWM=20         # 最低转速（永不停止，~931 RPM）
MAX_PWM=255        # 全速
TEMP_MIN=50        # 最低转速对应的温度
TEMP_MAX=85        # 全速温度阈值
HYSTERESIS=3       # 降温滞后 3°C
EMERGENCY_TEMP=85  # 紧急全速温度
STEP_MAX_UP=40     # 升速步进（快速响应）
STEP_MAX_DOWN=15   # 降速步进（平滑过渡）
SLEEP_INTERVAL=5   # 主循环间隔（秒）

# 状态变量
LAST_TEMP=0

# --- 函数 ---

enable_manual() {
  local current
  current=$(cat "${PWM}_enable")
  if [[ "$current" != "1" ]]; then
    echo 1 > "${PWM}_enable"
  fi
}

disable_manual() {
  echo 255 > "$PWM"
  sleep 0.5
  echo 2 > "${PWM}_enable"
}

# 紧急模式：跳过所有平滑，直接全速
emergency() {
  local reason=$1
  logger -t hanyan-fan "EMERGENCY: $reason — force PWM=255"
  echo 255 > "$PWM"
}

# 连续线性插值：温度 → PWM（映射到 MIN_PWM ~ MAX_PWM）
linear_pwm() {
  local temp=$1
  if (( temp >= TEMP_MAX )); then
    echo $MAX_PWM
    return
  fi
  if (( temp <= TEMP_MIN )); then
    echo $MIN_PWM
    return
  fi
  # PWM = MIN_PWM + (temp - TEMP_MIN) / (TEMP_MAX - TEMP_MIN) * (MAX_PWM - MIN_PWM)
  local range=$(( TEMP_MAX - TEMP_MIN ))
  local pwm_range=$(( MAX_PWM - MIN_PWM ))
  local offset=$(( temp - TEMP_MIN ))
  echo $(( MIN_PWM + offset * pwm_range / range ))
}

# 平滑写入：升速快，降速缓
smooth_write() {
  local current=$1
  local target=$2
  local diff=$(( target - current ))

  if (( diff == 0 )); then return; fi

  if (( diff > 0 )); then
    # 升速：大步
    if (( diff <= STEP_MAX_UP )); then
      echo "$target" > "$PWM"
    else
      echo "$(( current + STEP_MAX_UP ))" > "$PWM"
    fi
  else
    # 降速：小步
    local abs_diff=$(( -diff ))
    if (( abs_diff <= STEP_MAX_DOWN )); then
      echo "$target" > "$PWM"
    else
      echo "$(( current - STEP_MAX_DOWN ))" > "$PWM"
    fi
  fi
}

# 异常检测
check_abnormal() {
  local pwm_val=$1
  local fan_rpm=$2
  local temp_val=$3

  if (( fan_rpm > 2800 && pwm_val < 100 )); then
    logger -t hanyan-fan "ABNORMAL: fan=${fan_rpm}RPM at PWM=${pwm_val} temp=${temp_val}°C"
  fi
}

# --- 陷阱 ---
trap 'disable_manual; exit 0' SIGTERM SIGQUIT SIGINT

# --- 启动 ---
logger -t hanyan-fan "Starting v8.0 — MIN_PWM=${MIN_PWM} TEMP_MIN=${TEMP_MIN} TEMP_MAX=${TEMP_MAX}"

# --- 主循环 ---
enable_manual

# 初始快速写入：确保风扇立刻转动
echo $MIN_PWM > "$PWM"
sleep 0.5

while true; do
  TEMP_VAL=$(( $(cat "$TEMP") / 1000 ))

  # --- 紧急保护：85°C 直接全速 ---
  if (( TEMP_VAL >= EMERGENCY_TEMP )); then
    emergency "temp=${TEMP_VAL}°C >= ${EMERGENCY_TEMP}°C"
    sleep $SLEEP_INTERVAL
    continue
  fi

  # --- 每轮确保 manual 模式 ---
  enable_manual

  # --- 滞后逻辑 ---
  if (( TEMP_VAL > LAST_TEMP )); then
    USE_TEMP=$TEMP_VAL
  else
    if (( LAST_TEMP - TEMP_VAL >= HYSTERESIS )); then
      USE_TEMP=$TEMP_VAL
    else
      USE_TEMP=$LAST_TEMP
    fi
  fi
  LAST_TEMP=$USE_TEMP

  # --- 计算并写入 PWM ---
  TARGET_PWM=$(linear_pwm "$USE_TEMP")
  CURRENT_PWM=$(cat "$PWM")

  smooth_write "$CURRENT_PWM" "$TARGET_PWM"

  # --- 异常检测 ---
  FAN_RPM=$(cat "$FAN")
  check_abnormal "$TARGET_PWM" "$FAN_RPM" "$TEMP_VAL"

  sleep $SLEEP_INTERVAL
done
