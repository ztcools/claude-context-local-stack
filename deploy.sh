#!/usr/bin/env bash
# =============================================================================
# claude-context 一键部署脚本(四服务: milvus / ollama / git-index / phigent)
#   1. 检查 docker / compose
#   2. 准备 .env 与数据目录
#   3. 加载自建镜像(./images/*.tar.gz)
#   4. 启动全部服务(基础镜像用本机已有,不联网拉取)
#   5. 确认 Ollama 嵌入模型存在(缺失才拉)
# 用法:  ./deploy.sh            # 一键部署
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

if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  err "未找到 docker compose,请先安装 Docker + Compose 插件。"; exit 1
fi
command -v docker >/dev/null 2>&1 || { err "未找到 docker 命令。"; exit 1; }

case "${1:-up}" in
  down)   exec $DC down ;;
  logs)   exec $DC logs -f --tail=100 ;;
  status) exec $DC ps ;;
  up|"")  : ;;
  *) err "未知子命令: $1 (支持: up/down/logs/status)"; exit 1 ;;
esac

# ---- 1. 准备 .env -----------------------------------------------------------
if [[ ! -f .env ]]; then
  warn ".env 不存在,已从 .env.example 复制。请编辑 .env 后重新运行!"
  cp .env.example .env
  exit 1
fi
# shellcheck disable=SC1091
set -a; source .env; set +a

# ---- 2. 创建数据目录(复用现有数据时为已存在目录,mkdir -p 幂等)-------------
DATA_DIR="${DATA_DIR:-./data}"
OLLAMA_DATA="${OLLAMA_DATA:-./data/ollama}"
GIT_INDEX_DATA="${GIT_INDEX_DATA:-./data/git-index}"
mkdir -p "$DATA_DIR/etcd" "$DATA_DIR/minio" "$DATA_DIR/milvus" "$OLLAMA_DATA" "$GIT_INDEX_DATA/repos" 2>/dev/null || true
info "数据目录就绪 (milvus: $DATA_DIR, ollama: $OLLAMA_DATA, git-index: $GIT_INDEX_DATA)"

# ---- 3. 加载自建镜像 --------------------------------------------------------
load_image() {
  local name="$1" tar="images/$2"
  if [[ -f "$tar" ]]; then
    info "加载镜像: $tar"
    gunzip -c "$tar" | docker load
  elif docker image inspect "$name" >/dev/null 2>&1; then
    info "镜像已存在(无 tar,沿用本机): $name"
  else
    err "缺少镜像 $name,且未找到 $tar。请先构建并放入 ./images/。"; exit 1
  fi
}
load_image "claude-phigent:latest"            "claude-phigent.tar.gz"
load_image "claude-context-git-index:latest"  "claude-git-index.tar.gz"

# ---- 4. 启动(基础镜像用本机已有;compose 已设 pull_policy: never)----------
# 挂载给容器执行的脚本需可执行权限(bind mount 会覆盖镜像内权限)。
chmod +x assets/phigent-env.sh 2>/dev/null || true
info "启动服务..."
$DC up -d

# ---- 5. 确认 Ollama 嵌入模型 ------------------------------------------------
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"
OLLAMA_CT="${PROJECT_PREFIX:-claude}-ollama"
info "等待 Ollama 就绪..."
for i in $(seq 1 30); do
  docker exec "$OLLAMA_CT" ollama list >/dev/null 2>&1 && break
  sleep 2
  [[ $i -eq 30 ]] && warn "Ollama 未及时就绪,稍后手动: docker exec $OLLAMA_CT ollama pull $EMBED_MODEL"
done
if docker exec "$OLLAMA_CT" ollama list 2>/dev/null | grep -q "$EMBED_MODEL"; then
  info "嵌入模型已存在: $EMBED_MODEL"
else
  info "拉取嵌入模型: $EMBED_MODEL ..."
  docker exec "$OLLAMA_CT" ollama pull "$EMBED_MODEL" || \
    warn "模型拉取失败,请手动: docker exec $OLLAMA_CT ollama pull $EMBED_MODEL"
fi

echo
info "部署完成!服务状态:"
$DC ps
cat <<EOF

访问入口(将 <宿主机IP> 换成本机地址):
  - PhiGent 控制台 : http://<宿主机IP>:${PHIGENT_PORT:-18000}
  - GitLab 索引管理 : PhiGent 内“GitLab 仓库”页(直连 :${GIT_INDEX_PORT:-8795})
  - Milvus gRPC    : <宿主机IP>:${MILVUS_PORT:-19530}
  - Ollama API     : http://<宿主机IP>:${OLLAMA_PORT:-11435}
EOF
