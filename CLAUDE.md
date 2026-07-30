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

### 内存控制（几百个仓库时的防崩前提）
访问模式是「**集合极多、单集合不大、同一时刻只搜少数几个**」：一个仓库 × 一个保护分支 = 一个 collection，
几百个仓库 → 上千个 collection。而 Milvus 里 collection 必须 load 才能搜、**默认永不卸载**——
实测 15 个 collection / 约 12 万行就占 1.19 GiB，线性外推是上百 GB 常驻内存。三层同时做：

1. **服务端 mmap**（`assets/milvus-user.yaml`）：标量数据/标量索引/growing segment 全 mmap，
   冷数据回落 NVMe；**向量索引（HNSW）刻意留内存**——它决定搜索延迟，mmap 化会让 P99 明显变差。
   `lazyload` 也刻意关闭：省内存但首查要等 segment 换入（默认 30s 超时），交互式 search 不可接受。
2. **客户端写后 release**（`GIT_INDEX_RELEASE_AFTER=true`）：索引任务不把所有 collection 钉在内存里。
   代价是冷 collection 首查多约 900ms（load），warm 后 ~220ms。
3. **容器硬上限**（`*_MEM_LIMIT` / `*_CPU_LIMIT`）：任何一个服务失控也压不垮宿主机——
   这台机器与他人共用（其他容器已占近 140 GiB）。

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
│   ├── milvus-user.yaml # Milvus 覆盖配置 → /milvus/configs/user.yaml
│   │                     #   Milvus 先读 milvus.yaml 再深合并 user.yaml，
│   │                     #   所以这里只写要偏离默认的键（mmap 相关）
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
6. 校验挂载文件存在：`assets/phigent-env.sh`、`assets/milvus-user.yaml`
   —— bind-mount 源文件缺失时 Docker 会在该路径**建空目录**，Milvus 把
   `/milvus/configs/user.yaml` 当目录读会直接起不来，所以缺文件就明确报错
7. `docker compose up -d`（pull_policy: never，不联网）
8. 等待 Ollama 就绪 → 检查 `nomic-embed-text` 模型 → 缺失才 `ollama pull`
9. 打印服务状态 + 访问入口

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
| `GIT_INDEX_CONCURRENCY` | `6` | 同时索引几个仓库。瓶颈是 Ollama 向量化不是 CPU；6 是实测饱和点（1/3/6/8/12 流 → 27/75/136/140/142 embed/s） |
| `GIT_INDEX_RELEASE_AFTER` | `true` | 每个 collection 写完即从 Milvus 内存 release |
| `MILVUS_MEM_LIMIT` / `MILVUS_CPU_LIMIT` | `64g` / `24` | 最大消耗方；配 mmap 后实际远低于上限 |
| `OLLAMA_MEM_LIMIT` / `OLLAMA_CPU_LIMIT` | `32g` / `16` | 向量化推理 |
| `GIT_INDEX_MEM_LIMIT` / `GIT_INDEX_CPU_LIMIT` | `16g` / `12` | 实测单 worker 峰值 ~1 GiB（956 MiB 在堆外，V8 heap 仅 55 MiB），并发 6 最坏 ~6 GiB |
| `MINIO_MEM_LIMIT` / `MINIO_CPU_LIMIT` | `8g` / `4` | |
| `ETCD_MEM_LIMIT` / `ETCD_CPU_LIMIT` | `4g` / `2` | |
| `PHIGENT_MEM_LIMIT` / `PHIGENT_CPU_LIMIT` | `2g` / `2` | |

> 资源上限与 `milvus-user.yaml` 都要**重建容器**才生效：`docker compose up -d standalone`。
> 验证：`docker inspect claude-milvus-standalone --format '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}}'`。

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

# 只重建改了配置的那几个容器（共用机器上优先用这个，不要 down 整栈）
docker compose up -d standalone                  # 改了 milvus-user.yaml / MILVUS_*_LIMIT
docker compose up -d git-index phigent           # 只换了自建镜像

# 验证
curl http://localhost:9091/healthz              # Milvus → OK
docker exec claude-ollama ollama list            # → nomic-embed-text
docker inspect claude-milvus-standalone --format '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}}'
docker stats --no-stream claude-milvus-standalone # mmap 生效后内存不随 collection 数线性涨
```

## 开发约定

- 本项目是**纯配置+脚本工程**，无编译/构建步骤
- 修改只涉及：docker-compose.yml、deploy.sh、.env.example、assets/
- 镜像版本固定（pin），升级需显式改 tag
- `.env` 永远不提交；新增变量同步更新 `.env.example`
- deploy.sh 遵循 `set -euo pipefail`，用 `info/warn/err` 彩色日志函数
- 兼容 `docker compose`（插件）和 `docker-compose`（独立二进制）
