#!/usr/bin/env bash
# hanyan-fan v9.0 — N100 it8628 生产环境版
# 核心思想：永不停转，完全避开 it87 0→启动状态机问题
# 实测校准 (2026-06-14):
#   PWM=0→0  10→277  15→609  20→931  30→1391  45→1979
#   60→2436  75→2777  90→3096  120→3688  150→4166  255→5314 RPM
set -e

# --- 动态路径（通过 name 确认硬件，不怕编号漂移） ---
IT87_BASE=$(for h in /sys/class/hwmon/hwmon*; do
  [[ $(cat "$h/name" 2>/dev/null) == "it8628" ]] && echo "$h" && break
done)
CORETEMP_BASE=$(for h in /sys/class/hwmon/hwmon*; do
  [[ $(cat "$h/name" 2>/dev/null) == "coretemp" ]] && echo "$h" && break
done)

PWM="${IT87_BASE}/pwm2"
FAN="${IT87_BASE}/fan2_input"
TEMP="${CORETEMP_BASE}/temp1_input"

# --- 参数 ---
MIN_PWM=20         # 最低转速（永不停止，~931 RPM）
MAX_PWM=255        # 全速
TEMP_MIN=50        # 最低转速对应的温度
TEMP_MAX=85        # 全速温度阈值
HYSTERESIS=3       # 降温滞后 3°C
EMERGENCY_TEMP=85  # 进入紧急全速阈值
EMERGENCY_RELEASE=80 # 退出紧急全速阈值
STEP_MAX_UP=40     # 升速步进（快速响应）
STEP_MAX_DOWN=15   # 降速步进（平滑过渡）
SLEEP_INTERVAL=5   # 主循环间隔（秒）
ABNORMAL_LIMIT=3   # 异常次数阈值，连续 N 次才记录日志
RECOVERY_LIMIT=6   # 异常连续 N 次触发自恢复

# --- 状态变量 ---
LAST_TEMP=0
ABNORMAL_COUNT=0

# --- 函数 ---

enable_manual() {
  local current
  current=$(cat "${PWM}_enable" 2>/dev/null)
  if [[ "$current" != "1" ]]; then
    logger -t hanyan-fan "Re-enabling manual mode (was ${current})"
    echo 1 > "${PWM}_enable"
  fi
}

disable_manual() {
  echo 255 > "$PWM"
  sleep 0.5
  echo 2 > "${PWM}_enable"
}

# 紧急模式：跳过所有平滑，直接全速
emergency_on() {
  logger -t hanyan-fan "EMERGENCY ON — temp=${1}°C, force PWM=255"
  echo 255 > "$PWM"
}

# 退出紧急模式
emergency_off() {
  logger -t hanyan-fan "EMERGENCY OFF — temp=${1}°C, resume normal control"
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
    if (( diff <= STEP_MAX_UP )); then
      echo "$target" > "$PWM"
    else
      echo "$(( current + STEP_MAX_UP ))" > "$PWM"
    fi
  else
    local abs_diff=$(( -diff ))
    if (( abs_diff <= STEP_MAX_DOWN )); then
      echo "$target" > "$PWM"
    else
      echo "$(( current - STEP_MAX_DOWN ))" > "$PWM"
    fi
  fi
}

# 异常检测（使用实际读回值，有去抖）
check_abnormal() {
  local real_pwm=$1
  local fan_rpm=$2
  local temp_val=$3

  if (( fan_rpm > 2800 && real_pwm < 100 )); then
    ABNORMAL_COUNT=$(( ABNORMAL_COUNT + 1 ))
    if (( ABNORMAL_COUNT == ABNORMAL_LIMIT )); then
      logger -t hanyan-fan "ABNORMAL (#${ABNORMAL_COUNT}): fan=${fan_rpm}RPM at PWM=${real_pwm} temp=${temp_val}°C"
    elif (( ABNORMAL_COUNT >= RECOVERY_LIMIT )); then
      logger -t hanyan-fan "RECOVERY: resetting PWM channel (abnormal x${ABNORMAL_COUNT})"
      echo 2 > "${PWM}_enable"
      sleep 0.5
      echo 1 > "${PWM}_enable"
      echo 255 > "$PWM"
      sleep 0.5
      ABNORMAL_COUNT=0
    fi
  else
    # 恢复正常则清零
    if (( ABNORMAL_COUNT > 0 )); then
      ABNORMAL_COUNT=0
    fi
  fi
}

# --- 陷阱 ---
trap 'disable_manual; exit 0' SIGTERM SIGQUIT SIGINT

# --- 启动检查 ---
if [[ -z "$IT87_BASE" || ! -f "$PWM" ]]; then
  logger -t hanyan-fan "FATAL: it87 hwmon not found!"
  exit 1
fi
if [[ -z "$CORETEMP_BASE" || ! -f "$TEMP" ]]; then
  logger -t hanyan-fan "FATAL: coretemp hwmon not found!"
  exit 1
fi

logger -t hanyan-fan "Starting v9.0 — MIN_PWM=${MIN_PWM} TEMP_MIN=${TEMP_MIN} TEMP_MAX=${TEMP_MAX}"
logger -t hanyan-fan "Paths: PWM=${PWM} FAN=${FAN} TEMP=${TEMP}"

# --- 主循环 ---
enable_manual

# 初始温度初始化
LAST_TEMP=$(( $(cat "$TEMP") / 1000 ))
echo $MIN_PWM > "$PWM"
sleep 0.5

# 紧急模式状态
EMERGENCY_ACTIVE=0

while true; do
  TEMP_VAL=$(( $(cat "$TEMP") / 1000 ))

  # --- 紧急保护：85°C 进入 / 80°C 退出（5°C 滞回）---
  if (( EMERGENCY_ACTIVE == 0 && TEMP_VAL >= EMERGENCY_TEMP )); then
    EMERGENCY_ACTIVE=1
    emergency_on "$TEMP_VAL"
    sleep $SLEEP_INTERVAL
    continue
  fi
  if (( EMERGENCY_ACTIVE == 1 && TEMP_VAL < EMERGENCY_RELEASE )); then
    EMERGENCY_ACTIVE=0
    emergency_off "$TEMP_VAL"
  fi
  if (( EMERGENCY_ACTIVE == 1 )); then
    echo 255 > "$PWM"
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

  # --- 异常检测（用实际读回值） ---
  REAL_PWM=$(cat "$PWM")
  FAN_RPM=$(cat "$FAN")
  check_abnormal "$REAL_PWM" "$FAN_RPM" "$TEMP_VAL"

  sleep $SLEEP_INTERVAL
done
