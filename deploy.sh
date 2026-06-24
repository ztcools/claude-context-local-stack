#!/usr/bin/env bash
# =============================================================================
# claude-context 一键部署脚本
#   1. 检查 docker / docker compose 环境
#   2. 准备 .env 与数据目录
#   3. 拉取官方镜像
#   4. 启动全部服务
#   5. 拉取 Ollama 嵌入模型
# 用法:  ./deploy.sh            # 一键部署(拉镜像 + 启动 + 拉模型)
#        ./deploy.sh down      # 停止并移除容器(数据保留)
#        ./deploy.sh logs      # 查看日志
#        ./deploy.sh status    # 查看状态
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; NC='\033[0m'
info() { echo -e "${GRN}[INFO]${NC} $*"; }
warn() { echo -e "${YLW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR ]${NC} $*" >&2; }

# ---- 选择 docker compose 命令 ----------------------------------------------
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  err "未找到 docker compose,请先安装 Docker + Compose 插件。"; exit 1
fi
command -v docker >/dev/null 2>&1 || { err "未找到 docker 命令。"; exit 1; }

# ---- 子命令 -----------------------------------------------------------------
case "${1:-up}" in
  down)   exec $DC down ;;
  logs)   exec $DC logs -f --tail=100 ;;
  status) exec $DC ps ;;
  up|"")  : ;;  # 继续往下执行部署
  *) err "未知子命令: $1 (支持: up/down/logs/status)"; exit 1 ;;
esac

# ---- 1. 准备 .env -----------------------------------------------------------
if [[ ! -f .env ]]; then
  warn ".env 不存在,已从 .env.example 复制一份。请编辑 .env 填写配置后重新运行!"
  cp .env.example .env
  exit 1
fi
# shellcheck disable=SC1091
set -a; source .env; set +a

# ---- 2. 校验必须修改的敏感项 -----------------------------------------------
if grep -qE '^(MINIO_ACCESS_KEY|MINIO_SECRET_KEY)=CHANGE_ME' .env; then
  err "检测到 MinIO 凭据仍为 CHANGE_ME,请在 .env 中改成自定义口令后再部署。"; exit 1
fi

# ---- 3. 创建数据目录 --------------------------------------------------------
DATA_DIR="${DATA_DIR:-./data}"
OLLAMA_DATA="${OLLAMA_DATA:-./data/ollama}"
mkdir -p "$DATA_DIR/etcd" "$DATA_DIR/minio" "$DATA_DIR/milvus" "$OLLAMA_DATA"
info "数据目录就绪: $DATA_DIR"

# ---- 4. 拉取镜像并启动 ------------------------------------------------------
info "拉取官方镜像(首次较慢)..."
$DC pull
info "启动服务..."
$DC up -d

# ---- 5. 拉取 Ollama 嵌入模型 ------------------------------------------------
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"
OLLAMA_CT="${PROJECT_PREFIX:-claude}-ollama"
info "等待 Ollama 就绪..."
for i in $(seq 1 30); do
  if docker exec "$OLLAMA_CT" ollama list >/dev/null 2>&1; then break; fi
  sleep 2
  [[ $i -eq 30 ]] && { warn "Ollama 未在预期时间内就绪,稍后请手动执行: docker exec $OLLAMA_CT ollama pull $EMBED_MODEL"; }
done
if docker exec "$OLLAMA_CT" ollama list 2>/dev/null | grep -q "$EMBED_MODEL"; then
  info "嵌入模型已存在: $EMBED_MODEL"
else
  info "拉取嵌入模型: $EMBED_MODEL ..."
  docker exec "$OLLAMA_CT" ollama pull "$EMBED_MODEL" || \
    warn "模型拉取失败,请检查网络后手动执行: docker exec $OLLAMA_CT ollama pull $EMBED_MODEL"
fi

# ---- 完成 -------------------------------------------------------------------
echo
info "部署完成!服务状态:"
$DC ps
cat <<EOF

访问入口(将 <宿主机IP> 换成本机地址):
  - Attu 控制台 : http://<宿主机IP>:${ATTU_PORT:-18000}
  - Milvus gRPC : <宿主机IP>:${MILVUS_PORT:-19530}
  - MinIO 控制台: http://<宿主机IP>:${MINIO_CONSOLE_PORT:-9001}
  - Ollama API  : http://<宿主机IP>:${OLLAMA_PORT:-11435}
EOF
