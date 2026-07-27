# claude-context-local-stack — 本地向量检索后端一键部署

> 为 claude-context 语义代码检索提供本地后端的 Docker Compose 一体化部署包。
> 目标：`git clone` → 填配置 → `./deploy.sh` 一条命令拉起全部服务。

## 项目定位

这是一个**纯部署工程**，不含业务代码。它是 claude-context（[../context](../context)）的后端基础设施部署包，将 Milvus + Ollama + git-index-service + PhiGent 四个服务编排为一个 docker-compose 栈，一键启动。

本项目本身是一个 git 仓库模板——克隆后改 `.env` 即可部署到任意机器（开发本机、公司服务器等）。

## 架构：六容器编排

```
┌──────────────────────────────────────────────────┐
│  docker-compose (bridge: claude-net)              │
│                                                   │
│  ┌──────────┐  ┌──────────┐  ┌───────────────┐  │
│  │  etcd    │  │  minio   │  │  standalone    │  │
│  │  v3.5.25 │  │  S3 存储 │  │  milvus v2.6  │  │
│  │  :2379   │  │  :9000   │  │  :19530        │  │
│  └────┬─────┘  └────┬─────┘  └───┬───────┬───┘  │
│       │             │            │       │       │
│       └─────────────┴────────────┘       │       │
│         Milvus 依赖（depends_on          │       │
│         healthcheck）                    │       │
│                                          │       │
│  ┌──────────────────┐  ┌────────────────────────┐│
│  │  ollama          │  │  git-index             ││
│  │  embedding 推理   │  │  定时索引服务            ││
│  │  :11434→11435    │  │  :8790→GIT_INDEX_PORT  ││
│  │  GPU(nvidia)     │  │  depends_on: standalone ││
│  └──────────────────┘  └────────────────────────┘│
│                                                   │
│  ┌──────────────────────────────────────────────┐│
│  │  phigent (Web 控制台)                         ││
│  │  :3000→PHIGENT_PORT (默认18000)              ││
│  │  → MILVUS_URL (standalone:19530)             ││
│  │  → git-index 管理页直连 :GIT_INDEX_PORT       ││
│  └──────────────────────────────────────────────┘│
└──────────────────────────────────────────────────┘
```

### 服务依赖链

```
etcd ──(healthy)──┐
                  ├──→ standalone ──(healthy)──→ git-index
minio ─(healthy)─┘                              phigent
```

- **etcd**：Milvus 元数据存储（coordinator 协调）
- **minio**：Milvus 对象存储（S3 兼容，存 segment 数据）
- **standalone**：Milvus 单机版向量数据库，hybrid search（dense + sparse/BM25）
- **ollama**：本地 embedding 推理，模型 `nomic-embed-text`（768 维），GPU 加速
- **git-index**：定时索引服务，从 GitLab 拉取仓库 → 增量索引 main 分支到 Milvus
- **phigent**：Web 控制台（Milvus 管理 + 索引树 + GitLab 仓库配置）

## 关键设计决策

### 离线部署策略
- **基础镜像**（milvus/etcd/minio/ollama）：`pull_policy: never`，依赖本机已有镜像，不联网拉取
- **自建镜像**（phigent/git-index）：从 `./images/*.tar.gz` 加载（`gunzip -c | docker load`），不在目标机器构建
- 镜像 tag 全部固定（pin），保证可复现

### 自建镜像来源
- `claude-phigent:latest` — PhiGent Web 控制台前端
- `claude-context-git-index:latest` — git-index-service（来自 [../context](../context) 的 `packages/git-index-service`）
- 构建在开发机完成（带美国代理），`docker save|gzip` → sftp 到目标机器 → `docker load`

### 数据持久化
- 所有数据在 `DATA_DIR`（默认 `./data`），包含 etcd/minio/milvus/git-index
- Ollama 模型数据独立目录 `OLLAMA_DATA`（默认 `./data/ollama`）
- **重建容器绝不动 data 目录**——这是运维铁律

### 安全约束
- `.env` 含 MinIO 凭据等密钥，`.gitignore` 已排除，禁止提交
- `.env.example` 为模板，可安全提交（占位符值）
- `deploy.sh` 检测 `MINIO_ACCESS_KEY/SECRET_KEY` 为占位符 `CHANGE_ME` 时拒绝部署

## 文件结构

```
.
├── docker-compose.yml   # 六容器编排（用 .env 变量注入）
├── .env.example         # 配置模板（可提交）
├── .env                 # 实际配置（gitignore，含密钥）
├── deploy.sh            # 一键部署脚本（唯一入口）
├── assets/
│   └── phigent-env.sh   # PhiGent 启动钩子：注入前端运行时配置
│                         #   → 生成 /app/build/env-config.js
│                         #   → 注入 GIT_INDEX_PORT 等浏览器端需要的变量
├── images/              # 自建镜像 tar.gz（gitignore，不提交）
│   ├── claude-phigent.tar.gz
│   └── claude-git-index.tar.gz
├── data/                # 运行时数据（gitignore）
└── README.md
```

## deploy.sh 执行流程

```
./deploy.sh [up|down|logs|status]
```

**`up`（默认）流程**：
1. 检查 docker + docker compose 可用
2. `.env` 不存在 → 从 `.env.example` 复制并提示用户编辑 → exit
3. `source .env` → 创建数据目录（`mkdir -p`，幂等）
4. 加载自建镜像：`gunzip -c images/*.tar.gz | docker load`（已存在则跳过）
5. `chmod +x assets/phigent-env.sh`（bind mount 会覆盖镜像内权限）
6. `docker compose up -d`（pull_policy: never，不联网）
7. 等待 Ollama 就绪 → 检查 `nomic-embed-text` 模型 → 缺失才 `ollama pull`
8. 打印服务状态 + 访问入口

**其他子命令**：`down`（停止+移除容器）、`logs`（跟踪日志）、`status`（容器状态）

## 环境变量速查

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PROJECT_PREFIX` | `claude` | 容器名/网络名前缀 |
| `DATA_DIR` | `./data` | Milvus 数据持久化根目录 |
| `MINIO_ACCESS_KEY` | `minioadmin` | MinIO 凭据（**生产必改**） |
| `MINIO_SECRET_KEY` | `minioadmin` | MinIO 凭据（**生产必改**） |
| `MILVUS_PORT` | `19530` | Milvus gRPC 端口 |
| `OLLAMA_PORT` | `11435` | Ollama API 端口 |
| `OLLAMA_DATA` | `./data/ollama` | Ollama 模型数据目录 |
| `EMBED_MODEL` | `nomic-embed-text` | Embedding 模型名 |
| `EMBED_DIMENSION` | `768` | 向量维度 |
| `OLLAMA_GPU_COUNT` | `all` | GPU 数量（纯 CPU 部署删 deploy 段） |
| `GIT_INDEX_PORT` | `8795` | git-index HTTP 端口 |
| `GIT_INDEX_DATA` | `./data/git-index` | git-index 工作目录 |
| `GIT_INDEX_DAILY_HOUR` | `3` | 每日定时拉取小时 |
| `GIT_SSL_NO_VERIFY` | `false` | 自签 GitLab 证书时设 true |
| `GIT_INDEX_UID/GID` | `1015` | git-index 运行用户 |
| `PHIGENT_PORT` | `18000` | PhiGent Web 控制台端口 |
| `MILVUS_URL` | `standalone:19530` | PhiGent 连接 Milvus 地址 |

## 与 claude-context 主项目的关系

```
claude-context (../context)              本仓库 (claude-context-local-stack)
─────────────────────────────           ──────────────────────────────────
packages/core         索引引擎          docker-compose.yml   编排部署
packages/graph        知识图谱          deploy.sh            部署脚本
packages/mcp          MCP 服务端        .env.example         配置模板
packages/git-index-service  定时索引 ──→ images/claude-git-index.tar.gz
                                        assets/phigent-env.sh  PhiGent 启动钩子
```

- 本仓库**不包含** claude-context 的任何业务代码
- 本仓库的 git-index 镜像是从 claude-context 的 `packages/git-index-service` 构建的
- PhiGent 是独立项目（不在 claude-context monorepo 中）
- MCP 客户端（开发者本机 Cursor/Claude Code）直连本栈的 Milvus + Ollama

## 部署场景

### 公司服务器（10.50.4.149）
- 目录：`/data1/users/haoming.ju/claude-context/stack/`
- 该机另有 30+ 用户容器，运维时**绝不 `docker image prune`**（会误删他人悬空镜像）
- git-index 以 uid `1015:1015` 运行，SSH 部署公钥已配置到 GitLab
- 详见 memory：[[git-index-service-deploy]]

### 开发者本机
- clone 本仓库 → 配 `.env` → `./deploy.sh`
- 纯 CPU 部署：删除 `docker-compose.yml` 中 ollama 的 `deploy:` 段
- 然后在 claude-context MCP 客户端侧指向 `localhost:19530` + `localhost:11435`

## 常见操作

```bash
./deploy.sh            # 部署/更新（镜像变更后重新 up）
./deploy.sh status     # 查看容器状态
./deploy.sh logs       # 跟踪全部容器日志
./deploy.sh down       # 停止并移除容器（数据保留）

# 更新自建镜像
# 1. 替换 ./images/claude-*.tar.gz
# 2. ./deploy.sh   （deploy.sh 会重新 load + up）

# 验证
curl http://localhost:9091/healthz              # Milvus → OK
docker exec claude-ollama ollama list            # → nomic-embed-text
```

## 开发约定

- 本项目是**纯配置+脚本工程**，无编译/构建步骤
- 修改只涉及：docker-compose.yml、deploy.sh、.env.example、assets/
- 镜像版本固定（pin），升级需显式改 tag
- `.env` 永远不提交；新增变量同步更新 `.env.example`
- deploy.sh 遵循 `set -euo pipefail`，用 `info/warn/err` 彩色日志函数
- 兼容 `docker compose`（插件）和 `docker-compose`（独立二进制）
