# claude-context 本地向量检索后端 · 一键部署

为 [claude-context] 语义代码检索提供本地后端的一体化部署包。`git clone` 下来、
填好配置、跑一条命令即可拉起全部服务。

## 一、包含哪些服务

| 服务 | 容器 | 作用 | 默认端口(宿主机) |
|------|------|------|------------------|
| Milvus | `*-milvus-etcd` / `*-milvus-minio` / `*-milvus-standalone` | 向量数据库 | 19530(gRPC)、9091(metrics)、9000/9001(MinIO) |
| Ollama | `*-ollama` | 向量化(embedding)推理,模型 `nomic-embed-text` | 11435 |
| Attu | `*-attu` | Milvus 的 Web 控制台 | 18000 |

> 容器名前缀 `*` 由 `.env` 里的 `PROJECT_PREFIX` 决定(默认 `claude`)。

## 二、环境要求

- Docker 20.10+ 与 Docker Compose v2(`docker compose version` 可用)
- 当前用户有 docker 权限(在 `docker` 用户组,无需 sudo)
- **GPU 部署**:需安装 NVIDIA 驱动 + [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html),确保 `docker run --gpus all ...` 可用
- **纯 CPU 部署**:删除 `docker-compose.yml` 中 `ollama` 服务下的整个 `deploy:` 段即可(速度较慢)

## 三、部署步骤

```bash
# 1. 拉取仓库
git clone <本仓库地址> && cd <仓库目录>

# 2. 生成并编辑配置(至少改 MinIO 凭据)
cp .env.example .env
vi .env

# 3. 一键部署(自动:拉镜像 → 启动 → 拉嵌入模型)
./deploy.sh
```

`./deploy.sh` 会:校验环境与 `.env` → 创建数据目录 → `docker compose pull` 拉取官方镜像 →
`docker compose up -d` 启动 → 等待 Ollama 就绪后 `ollama pull nomic-embed-text`。

## 四、必须配置的地方(`.env`)

| 变量 | 说明 | 是否必改 |
|------|------|----------|
| `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` | MinIO 对象存储凭据,默认占位符 `CHANGE_ME`,不改则脚本拒绝部署 | ✅ 必改 |
| `PROJECT_PREFIX` | 容器/网络名前缀,多套环境共存时区分 | 可选 |
| `DATA_DIR` | 数据持久化根目录,建议改为绝对路径 | 建议 |
| `ATTU_PORT` / `MILVUS_PORT` / `OLLAMA_PORT` 等 | 各服务对外端口,端口冲突时修改 | 按需 |
| `OLLAMA_GPU_COUNT` | 用几张 GPU:`all` 或具体数字(如 `1`) | 按需 |
| `MILVUS_URL` | Attu 连接的 Milvus 地址;同机部署保持默认,连外部 Milvus 改为 `宿主机IP:19530` | 按需 |
| `EMBED_MODEL` | 嵌入模型名,默认 `nomic-embed-text` | 一般不改 |

## 五、常用命令

```bash
./deploy.sh            # 部署 / 更新
./deploy.sh status     # 查看容器状态
./deploy.sh logs       # 跟踪日志
./deploy.sh down       # 停止并移除容器(数据保留在 DATA_DIR)
```

## 六、验证

```bash
# Milvus 健康
curl http://localhost:9091/healthz          # 返回 OK
# Ollama 模型已就绪
docker exec claude-ollama ollama list        # 列出 nomic-embed-text
# 浏览器打开 Attu 控制台
http://<宿主机IP>:18000
```

在 claude-context 客户端侧,将 Milvus 地址指向 `<宿主机IP>:19530`、
Ollama 地址指向 `http://<宿主机IP>:11435` 即可。

## 七、目录结构

```
.
├── docker-compose.yml   # 一体化编排模板(全部用 .env 注入变量)
├── .env.example         # 配置模板(复制为 .env 使用)
├── deploy.sh            # 一键部署脚本
├── assets/
│   └── attu-env.sh      # Attu 界面美化脚本(汉化标题、隐藏官方推广,纯界面无业务信息)
└── README.md
```

## 八、说明

- 本仓库为**通用模板**,不含任何具体服务器地址、主机名或真实密钥。
- `.env` 含密钥,已被 `.gitignore` 忽略,请勿提交。
- 镜像版本已在 `docker-compose.yml` 中固定(pin),保证可复现;如需升级自行调整 tag。
