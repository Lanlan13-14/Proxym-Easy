#!/bin/bash

# --- 检查环境 (仅在必要时运行) ---
check_env() {
    if ! command -v wget &> /dev/null || ! command -v bc &> /dev/null; then
        echo "正在初始化必要环境..."
        apt-get update -qq && apt-get install -y wget bc -qq > /dev/null 2>&1
    fi
}

# --- 核心执行函数 (包含变量和逻辑) ---
run_wasting() {
    # 局部变量定义，确保后台运行能获取到
    local THREADS=$1
    local SPEED=$2
    local LIMIT_MB=$3
    local URLS=(
        "https://speed.cloudflare.com/__down?bytes=1000000000"
        "https://mirrors.edge.kernel.org/pub/linux/kernel/v5.x/linux-5.15.tar.gz"
        "https://img.alicdn.com/imgextra/i1/O1CN01xA4P9S1JsW2WEg0e1_!!6000000001084-2-tps-2880-560.png"
    )

    for ((i=1; i<=THREADS; i++)); do
        (
            while true; do
                local TARGET=${URLS[$RANDOM % ${#URLS[@]}]}
                # 增加 --tries 确保失败重试，增加标记以便 status 识别
                wget -q -U "Mozilla/5.0" -O /dev/null --limit-rate=$SPEED --tries=3 "$TARGET" > /dev/null 2>&1
                sleep 0.2
            done
        ) &
    done

    # 自动停止逻辑
    if [ "$LIMIT_MB" -gt 0 ]; then
        # 提取速度数字
        local S_NUM=$(echo $SPEED | sed 's/[^0-9.]//g')
        # 如果是 K，换算成 M
        [[ $SPEED == *k* ]] && S_NUM=$(echo "scale=4; $S_NUM / 1024" | bc)
        
        # 计算总速度和持续时间
        local TOTAL_SPEED=$(echo "$S_NUM * $THREADS" | bc)
        local DURATION=$(echo "$LIMIT_MB / $TOTAL_SPEED" | bc)
        
        sleep $DURATION
        pkill -P $$
    else
        wait
    fi
}

# --- 指令入口 ---
case "$1" in
    start)
        check_env
        THREADS=${2:-4}
        SPEED=${3:-1M}
        LIMIT_MB=${4:-0}
        
        echo "正在启动：$THREADS 线程，限速 $SPEED..."
        
        # 修复点：直接在当前 shell 的后台运行，不重新开 bash -c 避免丢失变量
        # 使用 setsid 确保退出 SSH 后任务不被杀死
        setsid "$0" _internal_run "$THREADS" "$SPEED" "$LIMIT_MB" > /dev/null 2>&1 &
        
        # 稍微等一下让进程起来
        sleep 1
        $0 status
        ;;
        
    _internal_run)
        # 内部引导，外部请勿调用
        run_wasting "$2" "$3" "$4"
        ;;
        
    stop)
        # 停止所有相关 wget 进程和本脚本启动的进程
        pkill -f "wget -q -U Mozilla/5.0 -O /dev/null"
        pkill -f "_internal_run"
        echo "所有任务已停止。"
        ;;

    status)
        # 统计 wget 进程数量
        COUNT=$(pgrep -f "wget -q -U Mozilla/5.0 -O /dev/null" | wc -l)
        if [ "$COUNT" -gt 0 ]; then
            echo "运行状态：正在运行中"
            echo "活跃下载线程：$COUNT"
            echo "实时网速参考：$(echo "$COUNT * ${2:-1}" | sed 's/[^0-9.]//g') MB/s (估算)"
        else
            echo "运行状态：未在运行"
            echo "提示：如果刚启动就停止，请检查网络是否能访问 Cloudflare 或 阿里 CDN。"
        fi
        ;;

    *)
        echo "用法: $0 {start|stop|status} [线程] [限速] [总量MB]"
        ;;
esac