# claude-context · 本地后端一键部署

为 [claude-context](https://github.com/ztcools/claude-context) 语义代码检索提供后端一体化部署包。

## 包含服务

| 服务 | 端口 | 说明 |
|------|------|------|
| **Milvus** (etcd + MinIO + standalone) | 19530 | 向量数据库 |
| **Ollama** | 11435 | embedding 推理 |
| **git-index** | 8795 | 定时拉取仓库 → 增量索引 |
| **PhiGent** | 18000 | Web 控制台：Milvus 管理 + 仓库配置 + 索引树 |

## 前置条件

- Docker 20.10+，当前用户有 docker 权限
- GPU 部署需安装 [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)；纯 CPU 删掉 compose 中 ollama 的 `deploy` 段即可

## 部署

```bash
git clone https://github.com/ztcools/claude-context-local-stack.git
cd claude-context-local-stack
cp .env.example .env
# 编辑 .env，至少修改 MINIO_ACCESS_KEY / MINIO_SECRET_KEY
./deploy.sh
```

`deploy.sh` 自动完成：环境校验 → 创建数据目录 → 加载镜像 → 启动服务 → 拉取 embedding 模型。

## 验证

```bash
curl http://localhost:9091/healthz          # Milvus → OK
curl http://localhost:8795/health           # git-index → {"status":"ok"}
docker exec claude-ollama ollama list        # 应有 nomic-embed-text
open http://<宿主机IP>:18000                # PhiGent 控制台
```

## 配置

编辑 `.env`，完整模板见 `.env.example`。关键项：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `MINIO_ACCESS_KEY` | MinIO 凭据 | `minioadmin` |
| `MINIO_SECRET_KEY` | MinIO 凭据 | `minioadmin` |
| `EMBED_MODEL` | embedding 模型 | `nomic-embed-text` |
| `GIT_INDEX_RELEASE_AFTER` | 索引后保持 LOADED | `false` |
| `GIT_INDEX_CONCURRENCY` | 并行索引数 | `6` |
| `GIT_SSL_NO_VERIFY` | 自签证书跳过 TLS | `false` |
| `MILVUS_URL` | PhiGent 连 Milvus 地址 | `standalone:19530` |

## 仓库管理

打开 PhiGent（`:18000`）→ 连接 Milvus → 「代码仓库」页面添加仓库。支持华为云 CodeHub / GitLab / GitHub，按 URL 自动识别平台和认证方式。git-index 每日定时拉取配置的分支并增量索引入 Milvus。

## 常用命令

```bash
./deploy.sh          # 部署/更新
./deploy.sh status   # 容器状态
./deploy.sh logs     # 跟踪日志
./deploy.sh down     # 停止并移除容器（数据保留）
```

## 目录结构

```
.
├── docker-compose.yml    # 6 容器编排
├── .env.example          # 配置模板
├── deploy.sh             # 部署脚本
├── assets/               # Milvus 配置 + PhiGent 启动钩子
├── images/               # 自建镜像（gitignore）
└── README.md
```
