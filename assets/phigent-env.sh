#!/bin/bash
# PhiGent 启动脚本(覆盖容器内 /app/build/env.sh)。
# 生成 env-config.js:注入前端运行时配置。GIT_INDEX_PORT 供“GitLab 仓库管理”页
# 直连 git-index 服务(浏览器用 当前主机名:该端口 访问)。

rm -rf ./build/env-config.js
touch ./build/env-config.js

echo "window._env_ = {" >> ./build/env-config.js

if [[ -f ./build/.env ]]; then
  while read -r line || [[ -n "$line" ]]; do
    # 跳过空行和注释。注释本身可能带 '='（"# 留空 = 默认"），照原样写进对象字面量
    # 会让 env-config.js 变成语法错误的 JS —— window._env_ 拿不到，整个控制台白屏。
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" != *=* ]] && continue
    varname=${line%%=*}
    varvalue=${line#*=}
    # 只有合法标识符才能当 JS 对象的键。
    [[ "$varname" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    value=$(printf '%s\n' "${!varname}")
    [[ -z $value ]] && value=${varvalue}
    echo "  $varname: \"$value\"," >> ./build/env-config.js
  done < ./build/.env
fi

# GIT_INDEX_PORT 由 build/.env 提供默认值、可被容器环境变量覆盖；
# .env 缺这一项时（旧前端构建）才在这里兜底补上。
if ! grep -q '^  GIT_INDEX_PORT:' ./build/env-config.js; then
  echo "  GIT_INDEX_PORT: \"${GIT_INDEX_PORT:-8795}\"," >> ./build/env-config.js
fi

echo "}" >> ./build/env-config.js
