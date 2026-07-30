# claude-context 本地向量检索后端 · 一键部署

为 [claude-context](https://github.com/ztcools/claude-context) 语义代码检索提供本地后端的一体化部署包。`git clone` 下来、填好配置、跑一条命令即可拉起全部服务。

## 一、包含哪些服务

| 服务 | 容器 | 作用 | 默认端口(宿主机) |
|------|------|------|------------------|
| Milvus | `*-milvus-etcd` / `*-milvus-minio` / `*-milvus-standalone` | 向量数据库(etcd元数据+MinIO对象存储+standalone) | 19530(gRPC)、9091(metrics)、9000/9001(MinIO) |
| Ollama | `*-ollama` | 向量化(embedding)推理，模型 `nomic-embed-text` | 11435 |
| git-index | `*-git-index` | 定时索引服务：拉取仓库 → 增量索引保护分支(支持华为云 CodeHub / GitLab / GitHub，按 URL 自动区分认证) | 8795(HTTP 管理口) |
| PhiGent | `*-phigent` | Web 控制台：Milvus 管理 + 索引树 + 仓库配置 | 18000 |

> 容器名前缀 `*` 由 `.env` 里的 `PROJECT_PREFIX` 决定(默认 `claude`)。

## 二、环境要求

- Docker 20.10+ 与 Docker Compose v2(`docker compose version` 可用)
- 当前用户有 docker 权限(在 `docker` 用户组，无需 sudo)
- **GPU 部署**：需安装 NVIDIA 驱动 + [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)，确保 `docker run --gpus all ...` 可用
- **纯 CPU 部署**：删除 `docker-compose.yml` 中 `ollama` 服务下的整个 `deploy:` 段即可(速度较慢)
- **与他人共用的机器**：所有服务都设了内存/CPU 上限(见第五节)，不封上限时 Milvus 会随 collection 数
  线性吃内存直到把机器占满

## 三、部署步骤

```bash
# 1. 拉取仓库
git clone https://github.com/ztcools/claude-context-local-stack.git && cd claude-context-local-stack

# 2. 生成并编辑配置(至少改 MinIO 凭据)
cp .env.example .env
vi .env

# 3. 一键部署(自动：加载镜像 → 启动 → 拉嵌入模型)
./deploy.sh
```

`./deploy.sh` 会：校验环境与 `.env` → 创建数据目录 → 加载自建镜像(`./images/*.tar.gz`) →
`docker compose up -d` 启动 → 等待 Ollama 就绪后确保 `nomic-embed-text` 模型存在。

## 四、必须配置的地方(`.env`)

| 变量 | 说明 | 是否必改 |
|------|------|----------|
| `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` | MinIO 对象存储凭据，默认占位符 `CHANGE_ME`，不改则脚本拒绝部署 | ✅ 必改 |
| `PROJECT_PREFIX` | 容器/网络名前缀，多套环境共存时区分 | 可选 |
| `DATA_DIR` | 数据持久化根目录，建议改为绝对路径 | 建议 |
| `GIT_INDEX_DATA` | git-index 工作目录(仓库克隆 + 配置文件持久化) | 建议 |
| `ATTU_PORT` / `MILVUS_PORT` / `OLLAMA_PORT` 等 | 各服务对外端口，端口冲突时修改 | 按需 |
| `OLLAMA_GPU_COUNT` | 用几张 GPU：`all` 或具体数字(如 `1`) | 按需 |
| `GIT_INDEX_DAILY_HOUR` | 每日定时拉取小时(0-23)，默认凌晨 3 点 | 按需 |
| `GIT_SSL_NO_VERIFY` | 内网 GitLab 自签证书时设为 `true` | 按需 |
| `MILVUS_URL` | PhiGent 连接的 Milvus 地址；同机部署保持默认，连外部 Milvus 改为 `宿主机IP:19530` | 按需 |
| `EMBED_MODEL` | 嵌入模型名，默认 `nomic-embed-text` | 一般不改 |

## 五、资源与内存控制（几百个仓库时的防崩关键）

访问模式是「**集合极多、单集合不大、同一时刻只搜少数几个**」：一个仓库 × 一个保护分支 = 一个 collection，
几百个仓库会有上千个 collection。而 Milvus 里 collection 必须 load 才能搜，**默认永不卸载**——
实测 15 个 collection / 约 12 万行就占 1.19 GiB，按上千 collection 线性外推是上百 GB 常驻内存。

三层措施同时生效：

| 层 | 措施 | 在哪配 |
|----|------|--------|
| Milvus 服务端 | 标量数据/标量索引/growing segment 全走 **mmap**，冷数据回落磁盘(NVMe 随机读代价低)；向量索引(HNSW)仍留内存以保延迟 | `assets/milvus-user.yaml`（挂载为 `/milvus/configs/user.yaml`） |
| 索引客户端 | 每写完一个 collection 立刻 `releaseCollection`，索引任务不把所有 collection 钉在内存里 | `.env` 的 `GIT_INDEX_RELEASE_AFTER=true` |
| 容器层 | 每个服务硬上限，任何一个失控也压不垮宿主机 | `.env` 的 `*_MEM_LIMIT` / `*_CPU_LIMIT` |

默认上限（按 64 核 / 256G 且与他人共用的机器给的，按自己机器调）：

| 服务 | 内存 | CPU | 说明 |
|------|------|-----|------|
| Milvus standalone | 64g | 24 | 最大消耗方；配 mmap 后实际远低于上限 |
| Ollama | 32g | 16 | 向量化推理 |
| git-index | 16g | 12 | 约每个并发 worker 4~5 GiB |
| MinIO | 8g | 4 | |
| etcd | 4g | 2 | |
| PhiGent | 2g | 2 | |

`GIT_INDEX_CONCURRENCY`（默认 3）= 同时索引几个仓库。**瓶颈是 Ollama 向量化而不是 CPU**，
超过 `OLLAMA_NUM_PARALLEL` 之后只会互相排队、总时长不降反升；调大它要同步上调 `GIT_INDEX_MEM_LIMIT`。

> **改了上限或 `milvus-user.yaml` 必须重建对应容器才生效**：
> `docker compose up -d standalone`（不需要 `down`，只重建配置变了的容器）。
> 验证：`docker inspect claude-milvus-standalone --format '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}}'`。

## 六、常用命令

```bash
./deploy.sh            # 部署 / 更新
./deploy.sh status     # 查看容器状态
./deploy.sh logs       # 跟踪日志
./deploy.sh down       # 停止并移除容器(数据保留在 DATA_DIR)
```

## 七、验证

```bash
# Milvus 健康
curl http://localhost:9091/healthz          # 返回 OK
# Ollama 模型已就绪
docker exec claude-ollama ollama list        # 列出 nomic-embed-text
# git-index 健康
curl http://localhost:8795/health
# 浏览器打开 PhiGent 控制台
http://<宿主机IP>:18000
```

在 claude-context 客户端侧，将 Milvus 地址指向 `<宿主机IP>:19530`、
Ollama 地址指向 `http://<宿主机IP>:11435` 即可。

### 开发者侧工作流（link → search，全自动）

开发者在要开发的仓库里打开 Claude，只需一次 `link` 绑定云端保护分支（如 `main`），
之后**无需任何手动索引**——本地禁止向量索引（`index` 工具已移除），一切自动：

1. **link**：绑定云端 collection（向量）+ **后台自动构建本地调用图索引**（图索引随 link 一并执行，用户无感知）。
2. **开发**：写代码、改文件。本地**图索引实时**（工作区变更自动增量重建），
   新增符号改完即可被 search 命中；向量索引按设计**不实时**（仅保护分支每日更新），
   开发者本地 diff 代码 LLM 本就清楚，无需实时向量化。
3. **search**：agent 按**触发规则**自行判断（用户无感知），search 输出头会标注
   仓库规模 `[repo: N files, small/medium/large]` 辅助决策：
   - **关系问题**（谁调用/影响面/死代码/入口）→ `graph`（任意规模，~200 tok，grep 答不了）。
   - **大库**（>2000 文件）且不知位置 → `both`（向量+图）。
   - **只知概念不知标识符** → `vector`。
   - **小库**（<300 文件）/已知符号 → 直接 Grep/Read（search 输出头会提示"grep/read 更省"）。

> search 是"定位 + 结构导航"的第一跳，**不是** Read/Grep 的替代品：
> 大库/陌生库/关系问题优先 search；小库/已知符号优先 Grep/Read。
> 成本从低到高：graph(~300t) < compact(~340t) < vector(~1700t) < both(~2200t)。
> 文档/测试类查询用 `docs:true` / `tests:true` 关闭降权。详见 claude-context 评估报告。

**实测（2026-07-30，两个真实 C++ 仓库，36 个期望符号，warm）**：

| mode | 召回 | token | 延迟 |
|------|------|-------|------|
| `graph` | 86% | ~300 | 60–105ms |
| `both` | 93% | ~2200 | 128–220ms |
| `vector` | 83% | ~1700 | ~50ms |

> Milvus 冷 collection 首查约 900ms（load 开销），warm 后回到 ~220ms —— 这是
> `GIT_INDEX_RELEASE_AFTER=true` 换来内存的代价，交互式使用可接受。

### git-index 服务端仓库配置

在 PhiGent 控制台的「代码仓库」页面（或直接调 `:8795` 管理 API）配置索引仓库列表。
仓库地址支持**华为云 CodeHub / GitLab / GitHub**，按填入的 URL 自动选择认证方式（token 或 SSH）。
git-index 服务会：
- 每日定时(默认凌晨 3 点)拉取配置的仓库
- 只索引保护分支（main/master 及 `protectedBranches`），写入 Milvus collection
- 开发者 `link` 即绑定该 collection 只读检索；本地不产生向量写操作

## 八、目录结构

```
.
├── docker-compose.yml   # 一体化编排模板(6 容器，全部用 .env 注入变量)
├── .env.example         # 配置模板(复制为 .env 使用)
├── .env                 # 实际配置(gitignore，含密钥)
├── deploy.sh            # 一键部署脚本
├── assets/
│   ├── milvus-user.yaml # Milvus 覆盖配置(mmap；挂载为 /milvus/configs/user.yaml)
│   └── phigent-env.sh   # PhiGent 启动钩子(注入前端运行时配置)
├── images/              # 自建镜像 tar.gz(gitignore)
│   ├── claude-phigent.tar.gz
│   └── claude-git-index.tar.gz
└── README.md
```

## 九、说明

- 本仓库为**通用模板**，不含任何具体服务器地址、主机名或真实密钥。
- `.env` 含密钥，已被 `.gitignore` 忽略，请勿提交。
- 镜像版本已在 `docker-compose.yml` 中固定(pin)，保证可复现；如需升级自行调整 tag。
- 基础镜像(milvus/etcd/minio/ollama)使用本机已有，不联网拉取；自建镜像(phigent/git-index)从 `./images/*.tar.gz` 加载。
