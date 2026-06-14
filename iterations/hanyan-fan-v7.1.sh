#!/usr/bin/env bash
# hanyan-fan v7.1 — N100 it8628 平滑曲线 + 滞后 + 软启停
# 实测校准 (2026-06-14):
#   PWM 0→0  10→277  15→609  30→1391  45→1979  60→2436
#   75→2777  90→3096  120→3688  150→4166  255→5314 RPM
set -e

# --- 动态路径 ---
IT87_BASE=$(echo /sys/devices/platform/it87.*/hwmon/hwmon*)
PWM="${IT87_BASE}/pwm2"
TEMP=$(echo /sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input)

# --- 参数 ---
MIN_PWM=0         # 停转
MAX_PWM=255       # 全速
TEMP_MIN=50       # 停转温度阈值（<50°C 停转）
TEMP_MAX=75       # 全速温度阈值
HYSTERESIS=3      # 降温滞后 3°C
BUFFER_PWM=5      # 从 0 启动时的缓冲值
STEP_MAX=15       # 单次调速最大步进（平滑）
RAMP_DELAY=0.3    # 平滑启动每步间隔（秒）
SLEEP_INTERVAL=5  # 主循环间隔（秒）

# 状态变量（跨循环保持）
LAST_TEMP=0
LAST_PWM=-1       # -1 表示未初始化

# --- 函数 ---

enable_manual() {
  echo 1 > "${PWM}_enable"
}

disable_manual() {
  echo 2 > "${PWM}_enable"
}

# 连续线性插值：温度 → PWM
linear_pwm() {
  local temp=$1
  if   (( temp <= TEMP_MIN )); then echo 0
  elif (( temp >= TEMP_MAX )); then echo $MAX_PWM
  else
    # 线性：PWM = (temp - TEMP_MIN) / (TEMP_MAX - TEMP_MIN) * MAX_PWM
    local range=$(( TEMP_MAX - TEMP_MIN ))
    local offset=$(( temp - TEMP_MIN ))
    echo $(( offset * MAX_PWM / range ))
  fi
}

# 平滑写入目标值：逐步逼近，不跳变
smooth_write() {
  local current=$1
  local target=$2
  local diff=$(( target - current ))

  # 绝对值
  local abs_diff=${diff#-}
  if (( abs_diff <= STEP_MAX )); then
    # 一步到位
    if (( target != current )); then
      echo "$target" > "$PWM"
    fi
    return
  fi

  # 大步进：分步走
  local step
  if (( diff > 0 )); then
    step=$STEP_MAX
  else
    step=$(( - STEP_MAX ))
  fi

  local next=$(( current + step ))
  echo "$next" > "$PWM"
}

# --- 陷阱 ---
trap 'disable_manual; exit 0' SIGTERM SIGQUIT SIGINT

# --- 主循环 ---
enable_manual

while true; do
  TEMP_VAL=$(( $(cat "$TEMP") / 1000 ))
  LAST_TEMP=${LAST_TEMP:-$TEMP_VAL}

  # 滞后逻辑：升温立即响应，降温等 HYSTERESIS
  if (( TEMP_VAL > LAST_TEMP )); then
    USE_TEMP=$TEMP_VAL
  else
    # 降温：滞后处理
    if (( LAST_TEMP - TEMP_VAL >= HYSTERESIS )); then
      USE_TEMP=$TEMP_VAL
    else
      USE_TEMP=$LAST_TEMP
    fi
  fi
  LAST_TEMP=$USE_TEMP

  # 计算目标 PWM
  TARGET_PWM=$(linear_pwm "$USE_TEMP")
  CURRENT_PWM=$(cat "$PWM")

  if (( TARGET_PWM == 0 )); then
    # --- 停转 ---
    if (( CURRENT_PWM > 0 )); then
      # 先降再关
      if (( CURRENT_PWM > 10 )); then
        echo 10 > "$PWM"
        sleep 0.5
      fi
      echo 0 > "$PWM"
    fi
  elif (( CURRENT_PWM == 0 )); then
    # --- 从停转启动：缓冲 + 软启 ---
    echo "$BUFFER_PWM" > "$PWM"
    sleep "$RAMP_DELAY"
    # 分步软启到目标
    p_val=$BUFFER_PWM
    while (( p_val < TARGET_PWM )); do
      nxt=$(( p_val + STEP_MAX ))
      if (( nxt > TARGET_PWM )); then nxt=$TARGET_PWM; fi
      echo "$nxt" > "$PWM"
      p_val=$nxt
      sleep "$RAMP_DELAY"
    done
  else
    # --- 正常调速 ---
    smooth_write "$CURRENT_PWM" "$TARGET_PWM"
  fi

  sleep $SLEEP_INTERVAL
done
