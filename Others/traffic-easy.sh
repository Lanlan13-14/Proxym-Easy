#!/bin/bash

TRAFFIC="./traffic.sh"
CONF="$HOME/.traffic-easy.conf"
STATE="$HOME/.traffic-easy.state"
LOGDIR="$HOME/logs"
LOGFILE="$LOGDIR/traffic-easy.log"
PIDFILE="$HOME/.traffic-easy.pid"
SYSTEMD_NAME="teasy.service"

mkdir -p "$LOGDIR"

log() {
  [[ "$LOG_ENABLED" == "yes" ]] && echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"
}

rand() { echo $((RANDOM % ($2 - $1 + 1) + $1)); }
rand_float() { awk -v min=$1 -v max=$2 'BEGIN{srand(); print min+rand()*(max-min)}'; }

load_conf() { [[ -f "$CONF" ]] && source "$CONF"; }
save_conf() {
cat > "$CONF" <<EOF
INTERVAL=$INTERVAL
DAY_START=$DAY_START
DAY_END=$DAY_END
DAY_THREAD_MIN=$DAY_THREAD_MIN
DAY_THREAD_MAX=$DAY_THREAD_MAX
DAY_RATE_MIN=$DAY_RATE_MIN
DAY_RATE_MAX=$DAY_RATE_MAX
DAY_TOTAL_MIN=$DAY_TOTAL_MIN
DAY_TOTAL_MAX=$DAY_TOTAL_MAX
NIGHT_THREAD_MIN=$NIGHT_THREAD_MIN
NIGHT_THREAD_MAX=$NIGHT_THREAD_MAX
NIGHT_RATE_MIN=$NIGHT_RATE_MIN
NIGHT_RATE_MAX=$NIGHT_RATE_MAX
NIGHT_TOTAL_MIN=$NIGHT_TOTAL_MIN
NIGHT_TOTAL_MAX=$NIGHT_TOTAL_MAX
DAILY_LIMIT_MB=$DAILY_LIMIT_MB
LOG_ENABLED=$LOG_ENABLED
LOG_RETENTION_HOURS=$LOG_RETENTION_HOURS
EOF
}

load_state() {
  TODAY=$(date +%F)
  [[ -f "$STATE" ]] && source "$STATE"
  [[ "$STATE_DATE" != "$TODAY" ]] && DAILY_USED_MB=0
}

save_state() { cat > "$STATE" <<EOF
STATE_DATE=$(date +%F)
DAILY_USED_MB=$DAILY_USED_MB
EOF
}

time_profile() {
  HOUR=$(date +%H)
  if (( HOUR >= DAY_START && HOUR < DAY_END )); then
    PROFILE="DAY"
    THREAD_MIN=$DAY_THREAD_MIN
    THREAD_MAX=$DAY_THREAD_MAX
    RATE_MIN=$DAY_RATE_MIN
    RATE_MAX=$DAY_RATE_MAX
    TOTAL_MIN=$DAY_TOTAL_MIN
    TOTAL_MAX=$DAY_TOTAL_MAX
  else
    PROFILE="NIGHT"
    THREAD_MIN=$NIGHT_THREAD_MIN
    THREAD_MAX=$NIGHT_THREAD_MAX
    RATE_MIN=$NIGHT_RATE_MIN
    RATE_MAX=$NIGHT_RATE_MAX
    TOTAL_MIN=$NIGHT_TOTAL_MIN
    TOTAL_MAX=$NIGHT_TOTAL_MAX
  fi
}

# ----------------- 删除函数 -----------------
delete_all() {
  echo "⚠️ 即将彻底删除 Traffic Easy"
  read -rp "请输入 yes 确认删除: " confirm
  [[ "$confirm" != "yes" ]] && { echo "已取消"; exit 0; }

  echo "停止服务..."
  systemctl stop "$SYSTEMD_NAME" 2>/dev/null
  systemctl disable "$SYSTEMD_NAME" 2>/dev/null

  echo "删除 systemd 服务..."
  rm -f /etc/systemd/system/$SYSTEMD_NAME
  systemctl daemon-reload

  echo "删除运行文件..."
  rm -f "$PIDFILE"
  rm -f "$CONF"
  rm -f "$STATE"

  [[ -d "$LOGDIR" ]] && rm -rf "$LOGDIR"

  echo "删除脚本本身..."
  SCRIPT_PATH="$(realpath "$0")"
  rm -f "$SCRIPT_PATH"

  echo "✅ Traffic Easy 已彻底删除"
  exit 0
}

# ----------------- systemd 自动生成 -----------------
setup_systemd() {
cat >/etc/systemd/system/$SYSTEMD_NAME <<EOF
[Unit]
Description=TEasy Traffic Scheduler
After=network.target

[Service]
Type=simple
ExecStart=$0 start
Restart=always
RestartSec=5
WorkingDirectory=$HOME
User=$USER

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $SYSTEMD_NAME
systemctl start $SYSTEMD_NAME
echo "✅ systemd 已设置为开机自启"
}

# ----------------- 菜单 -----------------
menu() {
  clear
  echo "====== Traffic Easy ======"
  echo "1) 基础周期设置"
  echo "2) 白天参数"
  echo "3) 夜间参数"
  echo "4) 每日流量上限"
  echo "5) 日志设置"
  echo "6) 保存并启动 (守护 + 开机自启)"
  echo "7) 停止守护 & systemd"
  echo "8) 停止并彻底删除"
  echo "0) 退出"
  read -rp "选择: " o

  case "$o" in
    1)
      read -rp "周期(秒): " INTERVAL ;;
    2)
      read -rp "白天开始小时: " DAY_START
      read -rp "白天结束小时: " DAY_END
      read -rp "线程最小: " DAY_THREAD_MIN
      read -rp "线程最大: " DAY_THREAD_MAX
      read -rp "限速最小(MB/s): " DAY_RATE_MIN
      read -rp "限速最大(MB/s): " DAY_RATE_MAX
      read -rp "总量最小(MB): " DAY_TOTAL_MIN
      read -rp "总量最大(MB): " DAY_TOTAL_MAX ;;
    3)
      read -rp "线程最小: " NIGHT_THREAD_MIN
      read -rp "线程最大: " NIGHT_THREAD_MAX
      read -rp "限速最小(MB/s): " NIGHT_RATE_MIN
      read -rp "限速最大(MB/s): " NIGHT_RATE_MAX
      read -rp "总量最小(MB): " NIGHT_TOTAL_MIN
      read -rp "总量最大(MB): " NIGHT_TOTAL_MAX ;;
    4)
      read -rp "每日最大流量(MB): " DAILY_LIMIT_MB ;;
    5)
      read -rp "日志开启? (yes/no): " LOG_ENABLED
      read -rp "日志保存周期(小时, 默认24h): " LOG_RETENTION_HOURS
      [[ -z "$LOG_RETENTION_HOURS" ]] && LOG_RETENTION_HOURS=24
      [[ "$LOG_ENABLED" != "yes" ]] && [[ -d "$LOGDIR" ]] && rm -rf "$LOGDIR" ;;
    6)
      save_conf
      setup_systemd
      start_loop ;;
    7)
      stop_loop ;;
    8)
      delete_all ;;
    0)
      exit 0 ;;
  esac
  menu
}

# ----------------- 主循环 -----------------
start_loop() {
  echo $$ > "$PIDFILE"
  log "Traffic Easy 启动 (增强随机 + 日志周期 ${LOG_RETENTION_HOURS}h)"

  while true; do
    load_state
    time_profile

    # 检查每日流量
    [[ $DAILY_USED_MB -ge $DAILY_LIMIT_MB ]] && {
      log "达到每日流量上限(${DAILY_USED_MB}MB)，休眠到次日"
      sleep $(( (24 - 10#$(date +%H)) * 3600 ))
      continue
    }

    OFFSET=$(rand 0 "$INTERVAL")
    sleep "$OFFSET"

    # 单轮总量正态分布
    MEAN=$(( (TOTAL_MIN + TOTAL_MAX)/2 ))
    SD=$(( (TOTAL_MAX - TOTAL_MIN)/6 ))
    TOTAL=$(awk -v mean=$MEAN -v sd=$SD 'BEGIN{srand(); t=int(mean+sd*sqrt(-2*log(rand()))*cos(2*3.14159*rand())); print (t<0?0:t)}')
    [[ $TOTAL -lt $TOTAL_MIN ]] && TOTAL=$TOTAL_MIN
    [[ $TOTAL -gt $TOTAL_MAX ]] && TOTAL=$TOTAL_MAX

    [[ $((DAILY_USED_MB + TOTAL)) -gt $DAILY_LIMIT_MB ]] && TOTAL=$((DAILY_LIMIT_MB-DAILY_USED_MB))

    THREADS=$(rand "$THREAD_MIN" "$THREAD_MAX")
    RATE=$(rand "$RATE_MIN" "$RATE_MAX")

    log "模式=$PROFILE 延迟=${OFFSET}s 线程=$THREADS 初始限速=${RATE}MB/s 总量=${TOTAL}MB"

    REMAIN_MB=$TOTAL
    while [[ $REMAIN_MB -gt 0 ]]; do
      INTERVAL_SEC=$(rand 5 15)
      FLUCT=$(rand_float 0.8 1.2)
      CUR_RATE=$(awk -v r=$RATE -v f=$FLUCT 'BEGIN{printf "%d", r*f}')
      [[ $CUR_RATE -lt 1 ]] && CUR_RATE=1
      CHUNK_MB=$(( CUR_RATE * THREADS * INTERVAL_SEC ))
      [[ $CHUNK_MB -gt $REMAIN_MB ]] && CHUNK_MB=$REMAIN_MB

      log "下载 $CHUNK_MB MB (线程=$THREADS, 限速=$CUR_RATE MB/s, 时长=${INTERVAL_SEC}s)"
      $TRAFFIC "$THREADS" "$CUR_RATE" "$CHUNK_MB"
      while $TRAFFIC status >/dev/null 2>&1; do sleep 5; done

      REMAIN_MB=$(( REMAIN_MB-CHUNK_MB ))
      DAILY_USED_MB=$((DAILY_USED_MB+CHUNK_MB))
      save_state
    done

    REST=$((INTERVAL - OFFSET))
    [[ $REST -gt 0 ]] && sleep "$REST"

    # 删除过期日志
    if [[ "$LOG_ENABLED" == "yes" ]]; then
      find "$LOGDIR" -type f -mtime +$((LOG_RETENTION_HOURS/24)) -exec rm -f {} \;
    fi
  done
}

stop_loop() {
  [[ -f "$PIDFILE" ]] && kill "$(cat "$PIDFILE")" 2>/dev/null && rm -f "$PIDFILE"
  log "Traffic Easy 已停止"
  systemctl stop "$SYSTEMD_NAME" 2>/dev/null
}

status_loop() {
  [[ -f "$PIDFILE" ]] && ps -p "$(cat "$PIDFILE")" >/dev/null && echo "运行中 (PID $(cat "$PIDFILE"))" || echo "未运行"
}

# ---------------- 主入口 ----------------
case "$1" in
  start) load_conf; start_loop ;;
  stop) stop_loop ;;
  status) status_loop ;;
  delete) delete_all ;;
  *) load_conf; menu ;;
esac
