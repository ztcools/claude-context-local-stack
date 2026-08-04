#!/usr/bin/env bash
# =============================================================================
# 把本机构建好的栈推到服务器并重建容器（在**本机**运行，不是服务器）
#
#   ./push-to-server.sh                # 传文件 → 补 .env → load 镜像 → 重建 → 验证
#   ./push-to-server.sh --verify-only  # 只跑只读验证，不改服务器任何东西
#   ./push-to-server.sh --dry-run      # 只打印会做什么
#   ./push-to-server.sh --yes          # 跳过确认（CI 用）
#
# 环境变量（必设）：
#   REMOTE_USER=yourname  REMOTE_HOST=1.2.3.4  REMOTE_DIR=/path/to/stack
# 密码只需输一次：脚本用 SSH 连接复用（ControlMaster），后续所有 ssh/scp 走同一条连接。
# 若已配公钥则完全免密。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

REMOTE_USER="${REMOTE_USER:?请设置 REMOTE_USER 环境变量}"
REMOTE_HOST="${REMOTE_HOST:?请设置 REMOTE_HOST 环境变量}"
REMOTE_DIR="${REMOTE_DIR:?请设置 REMOTE_DIR 环境变量}"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; BLU='\033[0;34m'; NC='\033[0m'
info() { echo -e "${GRN}[INFO]${NC} $*"; }
warn() { echo -e "${YLW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR ]${NC} $*" >&2; }
step() { echo -e "\n${BLU}━━━ $* ━━━${NC}"; }

DRY=0; ASSUME_YES=0; VERIFY_ONLY=0
for a in "$@"; do
  case "$a" in
    --dry-run)     DRY=1 ;;
    --yes|-y)      ASSUME_YES=1 ;;
    --verify-only) VERIFY_ONLY=1 ;;
    -h|--help)     sed -n '2,17p' "$0"; exit 0 ;;
    *) err "未知参数: $a"; exit 1 ;;
  esac
done

# ---- SSH 连接复用：一次密码，全程共用 --------------------------------------
# 优先公钥；没配公钥时，若 SSHPASS 环境变量存在且装了 sshpass 则用它（非交互，
# 适合脚本/CI）。两者都没有时 ssh 会在终端上正常提示输密码。
CTL="${TMPDIR:-/tmp}/cc-push-$$"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new
          -o ControlMaster=auto -o "ControlPath=$CTL" -o ControlPersist=600
          -o ConnectTimeout=15)
PASS_WRAP=()
if [[ -n "${SSHPASS:-}" ]] && command -v sshpass >/dev/null 2>&1; then
  PASS_WRAP=(sshpass -e)
  info "使用 SSHPASS 环境变量认证（密码不进命令行）"
fi
cleanup() { ssh -O exit -o "ControlPath=$CTL" "$REMOTE_USER@$REMOTE_HOST" 2>/dev/null || true; }
trap cleanup EXIT

# 服务器 OpenSSH 版本较老，每条连接都会打后量子握手警告，滤掉以免淹没真实输出
FILTER='post-quantum|store now, decrypt later|openssh.com/pq|^\*\*$'
rsh() { "${PASS_WRAP[@]}" ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" "$@" 2> >(grep -Ev "$FILTER" >&2); }
rcp() { "${PASS_WRAP[@]}" scp "${SSH_OPTS[@]}" "$@" 2> >(grep -Ev "$FILTER" >&2); }

R="$REMOTE_USER@$REMOTE_HOST"

# =============================================================================
# 0. 本机产物自检（服务器上 docker load 失败很难查，宁可在本机就拦住）
# =============================================================================
step "0/6 本机产物自检"
PUSH_FILES=(images/claude-git-index.tar.gz images/claude-phigent.tar.gz
            docker-compose.yml assets/milvus-user.yaml deploy.sh)
missing=0
for f in "${PUSH_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    printf '  %-40s %s\n' "$f" "$(du -h "$f" | cut -f1)"
  else
    err "缺失: $f"; missing=1
  fi
done
[[ $missing -eq 0 ]] || { err "先构建/导出镜像，见 ../context/DEPLOY.md 第一节"; exit 1; }

if [[ $VERIFY_ONLY -eq 0 ]]; then
  for t in images/claude-git-index.tar.gz images/claude-phigent.tar.gz; do
    gunzip -c "$t" | tar -tf - manifest.json >/dev/null 2>&1 \
      || { err "$t 不是完整的 docker save 产物（gzip 或 tar 截断）"; exit 1; }
  done
  info "两个镜像 tar 的 manifest 校验通过"
fi

# ---- 需要补进服务器 .env 的键（缺失才追加，已有的绝不覆盖）------------------
ENV_KEYS=(
  "GIT_INDEX_CONCURRENCY=6"
  "GIT_INDEX_RELEASE_AFTER=false"
  "MILVUS_MEM_LIMIT=64g"      "MILVUS_CPU_LIMIT=24"
  "OLLAMA_MEM_LIMIT=32g"      "OLLAMA_CPU_LIMIT=16"
  "GIT_INDEX_MEM_LIMIT=16g"   "GIT_INDEX_CPU_LIMIT=12"
  "MINIO_MEM_LIMIT=8g"        "MINIO_CPU_LIMIT=4"
  "ETCD_MEM_LIMIT=4g"         "ETCD_CPU_LIMIT=2"
  "PHIGENT_MEM_LIMIT=2g"      "PHIGENT_CPU_LIMIT=2"
)

# =============================================================================
# 只读验证（--verify-only 与末尾复用同一段）
# =============================================================================
do_verify() {
  step "验证（只读）"
  rsh "cd '$REMOTE_DIR' 2>/dev/null || { echo '栈目录不存在: $REMOTE_DIR'; exit 1; }
    echo '--- 容器状态 ---'
    docker compose ps --format '  {{.Name}}\t{{.Status}}' 2>/dev/null || docker compose ps
    echo
    echo '--- 生效的资源上限（内存字节 / NanoCPU，0 = 未限制）---'
    for c in \$(docker compose ps -q 2>/dev/null); do
      printf '  %-32s %s\n' \
        \"\$(docker inspect \$c --format '{{.Name}}' | tr -d /)\" \
        \"\$(docker inspect \$c --format '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}}')\"
    done
    echo
    echo '--- Milvus user.yaml 是否被容器读到（mmap）---'
    docker exec \$(docker compose ps -q standalone) sh -c 'head -20 /milvus/configs/user.yaml' 2>&1 | sed 's/^/  /' | head -20
    echo
    echo '--- 实时占用 ---'
    docker stats --no-stream --format '  {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}' \$(docker compose ps -q 2>/dev/null) 2>/dev/null | head -10
  " || warn "远端验证命令部分失败（见上）"

  echo
  info "HTTP 侧自检（从本机发起）"
  for u in "http://$REMOTE_HOST:9091/healthz" "http://$REMOTE_HOST:8795/health"; do
    printf '  %-45s ' "$u"
    curl -s -m 10 "$u" 2>/dev/null | head -c 120 || true
    echo
  done
  printf '  %-45s ' "phigent lazy /collections 带 description?"
  python3 - <<PY 2>/dev/null || echo "(检测失败)"
import json, urllib.request
B = "http://$REMOTE_HOST:18000/api/v1"
def call(p, body=None, hdr=None):
    h = {"Content-Type": "application/json"}
    if hdr: h.update(hdr)
    d = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(B+p, data=d, headers=h, method="POST" if d else "GET")
    with urllib.request.urlopen(r, timeout=30) as f: return json.loads(f.read().decode())
cid = call("/milvus/connect", {"address":"standalone:19530","username":"","password":"","database":"default"})["data"]["clientId"]
rows = call("/collections", None, {"milvus-client-id": cid, "x-attu-database": "default"})["data"]
has = rows and "description" in rows[0]
print(("是 — 新镜像已生效" if has else "否 — 仍是旧镜像") + f"（{len(rows)} 个 collection）")
PY
}

if [[ $VERIFY_ONLY -eq 1 ]]; then
  do_verify
  exit 0
fi

# =============================================================================
# 确认
# =============================================================================
cat <<PLAN

将对 $R:$REMOTE_DIR 执行：
  1. mkdir -p images assets                         （服务器旧栈没有 assets/）
  2. scp 上面 5 个文件（覆盖同名）
  3. .env 同步 ${#ENV_KEYS[@]} 个键 —— 缺失则追加、值不同则原地更新、一致则不动；
     改前存 .env.bak-<日期>；人工加的其他键与注释不动
  4. docker tag 现有 git-index / phigent 为 backup-<日期>（回滚用）
  5. docker load 两个新镜像
  6. docker compose up -d  —— 只重建配置变了的容器；compose 只管本 project，
     同机其他 30+ 用户容器完全不受影响。不执行 down，数据目录不动。

PLAN
if [[ $DRY -eq 1 ]]; then info "--dry-run：到此为止"; exit 0; fi
if [[ $ASSUME_YES -eq 0 ]]; then
  read -rp "确认执行？输入 yes 继续: " ans
  [[ "$ans" == "yes" ]] || { warn "已取消"; exit 0; }
fi

# =============================================================================
# 1. 建目录
# =============================================================================
step "1/6 准备远端目录"
rsh "mkdir -p '$REMOTE_DIR/images' '$REMOTE_DIR/assets' && ls -d '$REMOTE_DIR'"

# =============================================================================
# 2. 传文件
# =============================================================================
step "2/6 上传（镜像较大，171M + 293M）"
rcp images/claude-git-index.tar.gz images/claude-phigent.tar.gz "$R:$REMOTE_DIR/images/"
rcp docker-compose.yml deploy.sh                                "$R:$REMOTE_DIR/"
rcp assets/milvus-user.yaml                                     "$R:$REMOTE_DIR/assets/"
rsh "chmod +x '$REMOTE_DIR/deploy.sh'"
info "上传完成"

# =============================================================================
# 3. 同步 .env（幂等）
#
# 三种情形分开处理 —— 早先只做"缺失才追加"，导致改了默认值（如
# GIT_INDEX_CONCURRENCY 3→6）永远推不上去：键已存在就被当成"已是期望值"跳过了。
#   缺失      → 追加
#   值相同    → 不动
#   值不同    → 原地替换（打印 旧→新，改前有 .env.bak-<日期>）
# 只碰 ENV_KEYS 里这几个键，人工加的其他键与注释一概不动。
# =============================================================================
step "3/6 同步 .env"
ENV_PATCH=$(printf '%s\n' "${ENV_KEYS[@]}")
rsh "cd '$REMOTE_DIR'
  [[ -f .env ]] || { echo '.env 不存在，从 .env.example 复制并检查后再跑'; exit 1; }
  cp -n .env \".env.bak-\$(date +%Y%m%d)\" 2>/dev/null || true
  added=0; updated=0
  while IFS= read -r kv; do
    [[ -z \"\$kv\" ]] && continue
    k=\${kv%%=*}; v=\${kv#*=}
    cur=\$(sed -nE \"s/^[[:space:]]*\$k=(.*)\\\$/\\1/p\" .env | tail -1)
    if [[ -z \"\$cur\" ]] && ! grep -qE \"^[[:space:]]*\$k=\" .env; then
      printf '\n%s\n' \"\$kv\" >> .env
      printf '  追加  %s\n' \"\$kv\"; added=\$((added+1))
    elif [[ \"\$cur\" == \"\$v\" ]]; then
      printf '  一致  %s\n' \"\$kv\"
    else
      # awk 逐行替换：只改首个匹配行，值里的 & / \\ 都不参与正则，避免 sed 转义坑
      awk -v k=\"\$k\" -v v=\"\$v\" '
        !done && \$0 ~ \"^[[:space:]]*\" k \"=\" { print k \"=\" v; done=1; next } { print }
      ' .env > .env.tmp\$\$ && mv .env.tmp\$\$ .env
      printf '  更新  %s: %s → %s\n' \"\$k\" \"\$cur\" \"\$v\"; updated=\$((updated+1))
    fi
  done <<'EOF_ENV'
$ENV_PATCH
EOF_ENV
  echo \"  → 追加 \$added 项，更新 \$updated 项\"
"

# =============================================================================
# 4+5. 留底 + load
# =============================================================================
step "4/6 备份当前镜像 tag（回滚用）"
rsh "d=\$(date +%Y%m%d)
  for img in claude-context-git-index claude-phigent; do
    if docker image inspect \$img:latest >/dev/null 2>&1; then
      docker tag \$img:latest \$img:backup-\$d && echo \"  \$img:backup-\$d\"
    else
      echo \"  \$img:latest 不存在，跳过\"
    fi
  done"

step "5/6 加载新镜像"
rsh "cd '$REMOTE_DIR'
  gunzip -c images/claude-git-index.tar.gz | docker load
  gunzip -c images/claude-phigent.tar.gz   | docker load"

# =============================================================================
# 6. 重建
# =============================================================================
step "6/6 重建配置变更的容器"
rsh "cd '$REMOTE_DIR' && docker compose up -d 2>&1 | tail -20"

# 冷 collection 首查要 load，等 Milvus 起稳再验证
info "等待服务就绪…"
rsh "for i in \$(seq 1 30); do
       curl -sf http://localhost:9091/healthz >/dev/null 2>&1 && { echo '  Milvus healthz OK'; break; }
       sleep 3
     done"

do_verify

echo
info "完成。回滚：docker tag <img>:backup-<日期> <img>:latest && docker compose up -d <service>"
