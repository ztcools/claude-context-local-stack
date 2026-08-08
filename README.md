# claude-context · One-click local backend deployment

All-in-one backend deployment package for [claude-context](https://github.com/ztcools/claude-context) semantic code search.

## Included services

| Service | Port | Description |
|---------|------|-------------|
| **Milvus** (etcd + MinIO + standalone) | 19530 | Vector database |
| **Ollama** | 11435 | Embedding inference |
| **git-index** | 8795 | Scheduled repo pulls → incremental indexing |
| **PhiGent** | 18000 | Web console: Milvus management + repo config + index tree |

## Prerequisites

- Docker 20.10+, and the current user has docker permission
- GPU deployments require [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html); for CPU-only, remove the `deploy` block for ollama in the compose file

## Deploy

```bash
git clone https://github.com/ztcools/claude-context-local-stack.git
cd claude-context-local-stack
cp .env.example .env
# edit .env — at least update MINIO_ACCESS_KEY / MINIO_SECRET_KEY
./deploy.sh
```

`deploy.sh` automates: environment checks → data directory creation → image loading → service startup → embedding model pull.

## Verification

```bash
curl http://localhost:9091/healthz          # Milvus → OK
curl http://localhost:8795/health           # git-index → {"status":"ok"}
docker exec claude-ollama ollama list        # should list nomic-embed-text
open http://<host-ip>:18000                # PhiGent console
```

## Configuration

Edit `.env`; full template in `.env.example`. Key items:

| Variable | Description | Default |
|----------|-------------|---------|
| `MINIO_ACCESS_KEY` | MinIO credentials | `minioadmin` |
| `MINIO_SECRET_KEY` | MinIO credentials | `minioadmin` |
| `EMBED_MODEL` | Embedding model | `nomic-embed-text` |
| `GIT_INDEX_RELEASE_AFTER` | Keep LOADED after indexing | `false` |
| `GIT_INDEX_CONCURRENCY` | Parallel index count | `6` |
| `GIT_SSL_NO_VERIFY` | Skip TLS for self-signed certs | `false` |
| `MILVUS_URL` | Milvus address used by PhiGent | `standalone:19530` |

## Repo management

Open PhiGent (`:18000`) → connect Milvus → add repos on the "Code Repos" page. Supports Huawei Cloud CodeHub / GitLab / GitHub, auto-detecting platform and auth from the URL. git-index pulls configured branches on a daily schedule and incrementally indexes them into Milvus.

## Common commands

```bash
./deploy.sh          # deploy/update
./deploy.sh status   # container status
./deploy.sh logs     # tail logs
./deploy.sh down     # stop and remove containers (data kept)
```

## Directory structure

```
.
├── docker-compose.yml    # 6-container orchestration
├── .env.example          # config template
├── deploy.sh             # deploy script
├── assets/               # Milvus config + PhiGent startup hook
├── images/               # self-built images (gitignored)
└── README.md
```
