#!/bin/bash
# ==========================================
# Agent2IM 远程部署脚本
#
# 流程：同步代码 -> 构建镜像 -> 重启容器 -> 健康检查
# ==========================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[90m'
NC='\033[0m'

# ==================== 配置 ====================
SERVER_IP="${AGENT2IM_SERVER:-45.78.224.30}"
SERVER_USER="${AGENT2IM_USER:-root}"
SERVER_PORT="${AGENT2IM_PORT:-22}"
SERVER_PASS="${AGENT2IM_PASS:-autoagents@2023}"
REMOTE_DIR="${AGENT2IM_REMOTE_DIR:-/root/frank/Agent2IM}"
CONTAINER_NAME="agent2im-app"
APP_PORT=9000

HEALTH_CHECK_RETRIES=20
HEALTH_CHECK_INTERVAL=3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ==================== 帮助信息 ====================
show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "Agent2IM 远程部署脚本"
    echo ""
    echo "选项:"
    echo "  -h, --help          显示帮助信息"
    echo "  -s, --server IP     服务器 IP 地址"
    echo "  -u, --user USER     SSH 用户名 (默认: root)"
    echo "  -p, --port PORT     SSH 端口 (默认: 22)"
    echo "  -P, --password PASS SSH 密码"
    echo "  -d, --dir DIR       远程目录"
    echo "  --skip-sync         跳过代码同步（仅重建）"
    echo "  --logs              部署后查看日志"
    echo "  --status            查看当前容器状态"
    echo ""
    echo "环境变量:"
    echo "  AGENT2IM_SERVER     服务器 IP"
    echo "  AGENT2IM_USER       SSH 用户名"
    echo "  AGENT2IM_PORT       SSH 端口"
    echo "  AGENT2IM_PASS       SSH 密码"
    echo "  AGENT2IM_REMOTE_DIR 远程目录"
    echo ""
    echo "示例:"
    echo "  $0                                # 正常部署"
    echo "  $0 --status                       # 查看状态"
    echo "  $0 --skip-sync                    # 跳过同步，仅重建"
    echo "  $0 -s 192.168.1.100 -P password   # 指定服务器"
    echo ""
}

# ==================== 参数解析 ====================
SKIP_SYNC=false
SHOW_LOGS=false
SHOW_STATUS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)     show_help; exit 0 ;;
        -s|--server)   SERVER_IP="$2"; shift 2 ;;
        -u|--user)     SERVER_USER="$2"; shift 2 ;;
        -p|--port)     SERVER_PORT="$2"; shift 2 ;;
        -P|--password) SERVER_PASS="$2"; shift 2 ;;
        -d|--dir)      REMOTE_DIR="$2"; shift 2 ;;
        --skip-sync)   SKIP_SYNC=true; shift ;;
        --logs)        SHOW_LOGS=true; shift ;;
        --status)      SHOW_STATUS=true; shift ;;
        *)
            echo -e "${RED}未知选项: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

# ==================== SSH 设置 ====================
if [ -n "$SERVER_PASS" ]; then
    if ! command -v sshpass &> /dev/null; then
        echo -e "${YELLOW}sshpass 未安装，正在安装...${NC}"
        if [[ "$(uname -s)" == "Darwin" ]]; then
            brew install hudochenkov/sshpass/sshpass
        else
            apt-get install -y sshpass 2>/dev/null || yum install -y sshpass 2>/dev/null
        fi
    fi
    export SSHPASS="$SERVER_PASS"
    USE_SSHPASS=true
else
    USE_SSHPASS=false
fi

run_ssh() {
    if [ "$USE_SSHPASS" = true ]; then
        sshpass -e ssh -o StrictHostKeyChecking=no -p "$SERVER_PORT" "$SERVER_USER@$SERVER_IP" "$@"
    else
        ssh -o StrictHostKeyChecking=no -p "$SERVER_PORT" "$SERVER_USER@$SERVER_IP" "$@"
    fi
}

# ==================== --status ====================
if [ "$SHOW_STATUS" = true ]; then
    echo ""
    echo -e "  ${GRAY}┌─ ${YELLOW}Agent2IM 容器状态${GRAY} ─────────────────────────┐${NC}"
    run_ssh "
        if docker ps -q -f name=$CONTAINER_NAME | grep -q .; then
            echo '  容器运行中'
            docker ps -f name=$CONTAINER_NAME --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
            echo ''
            docker stats $CONTAINER_NAME --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null || true
        else
            echo '  容器未运行'
        fi
    "
    echo -e "  ${GRAY}└──────────────────────────────────────────────┘${NC}"
    echo ""
    exit 0
fi

# ==================== 开始部署 ====================
echo ""
echo -e "  ${CYAN}Agent2IM 远程部署${NC}"
echo -e "  ${GRAY}────────────────────────────────────────────${NC}"
echo -e "  服务器      ${CYAN}$SERVER_USER@$SERVER_IP:$SERVER_PORT${NC}"
echo -e "  远程目录    ${CYAN}$REMOTE_DIR${NC}"
echo ""

# ==================== 步骤 1: 测试连接 ====================
echo -e "  ${GRAY}[1/4]${NC} 测试 SSH 连接..."

if ! run_ssh "echo ok" > /dev/null 2>&1; then
    echo -e "  ${RED}SSH 连接失败，请检查服务器配置${NC}"
    exit 1
fi
echo -e "  ${GREEN}SSH 连接成功${NC}"
echo ""

# ==================== 步骤 2: 同步代码 ====================
if [ "$SKIP_SYNC" = false ]; then
    echo -e "  ${GRAY}[2/4]${NC} 同步代码..."

    run_ssh "mkdir -p $REMOTE_DIR"
    cd "$PROJECT_ROOT"

    if [ "$USE_SSHPASS" = true ]; then
        RSYNC_RSH="sshpass -e ssh -o StrictHostKeyChecking=no -p $SERVER_PORT"
    else
        RSYNC_RSH="ssh -o StrictHostKeyChecking=no -p $SERVER_PORT"
    fi

    rsync -avz --progress \
        -e "$RSYNC_RSH" \
        --exclude '__pycache__' \
        --exclude '.git' \
        --exclude '*.log' \
        --exclude '.env' \
        --exclude 'logs' \
        --exclude 'playground' \
        --exclude '.venv' \
        --delete \
        ./ "$SERVER_USER@$SERVER_IP:$REMOTE_DIR/"

    echo -e "  ${GREEN}代码同步完成${NC}"
else
    echo -e "  ${GRAY}[2/4]${NC} 跳过代码同步"
fi
echo ""

# ==================== 步骤 3: 构建并重启 ====================
echo -e "  ${GRAY}[3/4]${NC} 构建镜像并重启容器..."

run_ssh "
    cd $REMOTE_DIR/docker

    docker compose build --no-cache
    docker compose up -d --force-recreate

    docker image prune -f 2>/dev/null || true
"

echo -e "  ${GREEN}容器已重启${NC}"
echo ""

# ==================== 步骤 4: 健康检查 ====================
echo -e "  ${GRAY}[4/4]${NC} 健康检查..."

for i in $(seq 1 $HEALTH_CHECK_RETRIES); do
    STATUS=$(run_ssh "curl -s -o /dev/null -w '%{http_code}' http://localhost:$APP_PORT/health 2>/dev/null" || echo "000")

    if [ "$STATUS" = "200" ]; then
        echo -e "  ${GREEN}健康检查通过 (HTTP $STATUS)${NC}"
        break
    fi

    if [ "$i" -eq "$HEALTH_CHECK_RETRIES" ]; then
        echo -e "  ${RED}健康检查失败，请检查日志: docker logs $CONTAINER_NAME${NC}"
        exit 1
    fi

    echo -e "  ${GRAY}[$i/$HEALTH_CHECK_RETRIES] HTTP $STATUS - 等待 ${HEALTH_CHECK_INTERVAL}s...${NC}"
    sleep $HEALTH_CHECK_INTERVAL
done

echo ""
echo -e "  ${GRAY}────────────────────────────────────────────${NC}"
echo -e "  ${GREEN}部署完成${NC}"
echo -e "  API      http://$SERVER_IP:$APP_PORT"
echo -e "  健康检查  http://$SERVER_IP:$APP_PORT/health"
echo -e "  API 文档  http://$SERVER_IP:$APP_PORT/docs"
echo ""

# ==================== 可选: 显示日志 ====================
if [ "$SHOW_LOGS" = true ]; then
    echo -e "${CYAN}实时日志 (Ctrl+C 退出):${NC}"
    run_ssh "docker logs -f $CONTAINER_NAME"
fi
