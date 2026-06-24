#!/bin/bash
# Attu 启动脚本(覆盖容器内 /app/build/env.sh)。
# 在生成 env-config.js 时追加一段前端脚本:汉化标题、隐藏官方推广侧栏与版本号。
# 纯界面美化,不含任何业务/公司信息。如不需要可删除 compose 中 attu 的该卷挂载。

# Recreate config file
rm -rf ./build/env-config.js
touch ./build/env-config.js

# Add assignment
echo "window._env_ = {" >> ./build/env-config.js

# Read each line in .env file
while read -r line || [[ -n "$line" ]];
do
  if printf '%s\n' "$line" | grep -q -e '='; then
    varname=$(printf '%s\n' "$line" | sed -e 's/=.*//')
    varvalue=$(printf '%s\n' "$line" | sed -e 's/^[^=]*=//')
  fi
  value=$(printf '%s\n' "${!varname}")
  [[ -z $value ]] && value=${varvalue}
  echo "  $varname: \"$value\"," >> ./build/env-config.js
done < ./build/.env

echo "}" >> ./build/env-config.js

# ===== 自定义:精简左侧 + 隐藏官方推广侧栏 =====
cat >> ./build/env-config.js <<'PROMOJS'
;(function(){
  var LABELS=['试用 Zilliz Cloud','给我一颗小星星','提交 Issue','Discord','联系专家',
              'Try Zilliz Cloud','Star us','Report Issue','Contact Us'];
  var HREFS=['cloud.zilliz.com','github.com/zilliztech/attu','milvus.io/discord',
             'support.zilliz.com','docs.zilliz.com'];
  function hidePromo(){
    document.querySelectorAll('a[href]').forEach(function(a){
      for(var i=0;i<HREFS.length;i++){
        if(a.href.indexOf(HREFS[i])>=0){ (a.closest('li')||a).style.display='none'; break; }
      }
    });
    document.querySelectorAll('a,button,li,[role="button"]').forEach(function(el){
      if(LABELS.indexOf((el.textContent||'').trim())>=0){ (el.closest('li')||el).style.display='none'; }
    });
  }
  function tidy(){
    // 1) 标题 Attu -> Milvus 控制台
    var titleEl=null;
    var w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,null),n;
    while(n=w.nextNode()){
      var t=(n.nodeValue||'').trim();
      if(t==='Attu'){ n.nodeValue='Milvus 控制台'; titleEl=n.parentElement; }
    }
    // 2) 隐藏左上角图标(标题左侧的那个 img/svg,不动主题/语言按钮)
    if(titleEl){
      var box=titleEl, done=false;
      for(var i=0;i<5 && box && !done;i++){
        var cands=box.querySelectorAll('img,svg');
        for(var k=0;k<cands.length;k++){
          var c=cands[k];
          if(c.closest('button')) continue;           // 排除右侧主题/语言按钮
          if(c.getAttribute('data-promo-done')) continue;
          if(c.compareDocumentPosition(titleEl) & 4){  // c 在标题之前 => 就是 logo
            c.style.display='none'; c.setAttribute('data-promo-done','1'); done=true; break;
          }
        }
        box=box.parentElement;
      }
    }
    // 3) 删除版本号行("版本: x.y.z"),按元素整体文本匹配,长度限制避免误伤大容器
    var all=document.querySelectorAll('div,span,p,li');
    for(var x=0;x<all.length;x++){
      var tt=(all[x].textContent||'').trim();
      if(tt.length<=20 && /^版本\s*[:：]?\s*v?\d/.test(tt)){
        all[x].style.display='none';
      }
    }
  }
  function run(){ try{hidePromo();}catch(e){} try{tidy();}catch(e){} }
  var obs=new MutationObserver(run);
  function start(){ obs.observe(document.documentElement,{childList:true,subtree:true}); run(); }
  if(document.readyState!=='loading'){ start(); } else { document.addEventListener('DOMContentLoaded',start); }
})();
PROMOJS
