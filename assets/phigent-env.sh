#!/bin/bash
# PhiGent 启动脚本(覆盖容器内 /app/build/env.sh)。
# 生成 env-config.js:注入前端运行时配置。GIT_INDEX_PORT 供“GitLab 仓库管理”页
# 直连 git-index 服务(浏览器用 当前主机名:该端口 访问)。

rm -rf ./build/env-config.js
touch ./build/env-config.js

echo "window._env_ = {" >> ./build/env-config.js

if [[ -f ./build/.env ]]; then
  while read -r line || [[ -n "$line" ]]; do
    if printf '%s\n' "$line" | grep -q -e '='; then
      varname=$(printf '%s\n' "$line" | sed -e 's/=.*//')
      varvalue=$(printf '%s\n' "$line" | sed -e 's/^[^=]*=//')
      value=$(printf '%s\n' "${!varname}")
      [[ -z $value ]] && value=${varvalue}
      echo "  $varname: \"$value\"," >> ./build/env-config.js
    fi
  done < ./build/.env
fi

# 显式注入 git-index 管理服务端口(前端 GitLab 仓库管理页直连使用)
echo "  GIT_INDEX_PORT: \"${GIT_INDEX_PORT:-8795}\"," >> ./build/env-config.js

echo "}" >> ./build/env-config.js
