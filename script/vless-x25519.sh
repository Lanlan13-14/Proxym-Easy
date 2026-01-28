#!/usr/bin/env bash
# vless-x25519.sh
# 作用：交互式添加 VLESS + x25519 入站（写入 /etc/xray 顶层 JSON 文件）
set -euo pipefail
export LC_ALL=C.UTF-8

XRAY_DIR="/etc/xray"
URI_DIR="/etc/proxym-easy"
URI_FILE="${URI_DIR}/uri.json"
VLESS_JSON="/etc/proxym/vless.json"
PROTOCOL="x25519"

declare -A FLAGS=([CN]="🇨🇳" [US]="🇺🇸")

ensure_dirs(){
  sudo mkdir -p "$XRAY_DIR" "$URI_DIR" "$(dirname "$VLESS_JSON")"
  sudo touch "$URI_FILE" "$VLESS_JSON" 2>/dev/null || true
  if [ ! -s "$URI_FILE" ]; then echo "[]" | sudo tee "$URI_FILE" >/dev/null; fi
  if [ ! -s "$VLESS_JSON" ]; then echo "[]" | sudo tee "$VLESS_JSON" >/dev/null; fi
}

generate_uuid(){
  if command -v xray >/dev/null 2>&1; then xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid; else cat /proc/sys/kernel/random/uuid; fi
}

list_used_numbers(){
  find "$XRAY_DIR" -maxdepth 1 -type f -name '[0-9]*' -printf '%f\n' 2>/dev/null | sed -n 's/^\([0-9]\+\).*/\1/p' | sort -u
}

tag_exists(){
  local tag="$1"
  for f in "$XRAY_DIR"/*.json; do
    [ -e "$f" ] || continue
    if grep -q "\"tag\"[[:space:]]*:[[:space:]]*\"${tag}\"" "$f" 2>/dev/null; then return 0; fi
  done
  return 1
}

append_uri(){
  local name="$1"
  local uri="$2"
  local tmp
  tmp=$(mktemp)
  sudo jq --arg name "$name" --arg uri "$uri" '. += [{"name":$name,"uri":$uri}]' "$URI_FILE" > "$tmp" && sudo mv "$tmp" "$URI_FILE"
}

write_inbound_file(){
  local prefix="$1" proto="$2" port="$3" uuid="$4" network="$5" path="$6" host="$7"
  local tag="${prefix}-${proto}-${port}"
  local fname="${prefix}-${proto}-${port}.json"
  local json
  if [ "$network" = "ws" ]; then
    json=$(jq -n --arg tag "$tag" --arg port "$port" --arg uuid "$uuid" --arg path "$path" --arg host "$host" '{
      "inbounds":[
        {
          "tag": $tag,
          "port": ($port|tonumber),
          "protocol": "vless",
          "settings": { "clients":[{"id":$uuid}], "decryption":"none" },
          "streamSettings": { "network":"ws", "wsSettings": {"path": $path, "headers":{"Host": $host}} }
        }
      ]
    }')
  else
    json=$(jq -n --arg tag "$tag" --arg port "$port" --arg uuid "$uuid" '{
      "inbounds":[
        {
          "tag": $tag,
          "port": ($port|tonumber),
          "protocol": "vless",
          "settings": { "clients":[{"id":$uuid}], "decryption":"none" },
          "streamSettings": { "network":"tcp" }
        }
      ]
    }')
  fi
  echo "$json" | sudo tee "${XRAY_DIR}/${fname}" >/dev/null
  echo "${fname}"
}

main(){
  ensure_dirs
  echo "添加 VLESS + x25519 节点"

  echo "当前已用数字前缀："
  list_used_numbers || true

  read -r -p "输入数字前缀（例如 02）: " prefix
  prefix=${prefix:-02}
  if ! echo "$prefix" | grep -qE '^[0-9]+$'; then echo "前缀必须为数字"; exit 1; fi

  read -r -p "端口 (默认 随机 10000-60000，回车使用随机): " port
  if [ -z "$port" ]; then
    port=$(( (RANDOM % 50000) + 10000 ))
  fi

  read -r -p "网络类型 (tcp/ws) [tcp]: " network
  network=${network:-tcp}
  path=""; host=""
  if [ "$network" = "ws" ]; then
    read -r -p "Path (留空自动生成): " path
    if [ -z "$path" ]; then path="/$(head -c6 /dev/urandom | xxd -p -c6)"; fi
    read -r -p "Host (留空使用主机名): " host
    host=${host:-$(hostname -f 2>/dev/null || hostname)}
  fi

  tag="${prefix}-${PROTOCOL}-${port}"
  if tag_exists "$tag"; then echo "检测到相同 tag 已存在: $tag，请更换前缀或端口"; exit 1; fi

  uuid=$(generate_uuid)
  name="${FLAGS[US]:-🌍} ${prefix}-${PROTOCOL}-${port}"
  name_enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$name" 2>/dev/null || printf '%s' "$name")

  fname=$(write_inbound_file "$prefix" "$PROTOCOL" "$port" "$uuid" "$network" "$path" "$host")

  server=$(hostname -f 2>/dev/null || hostname)
  if [ "$network" = "ws" ]; then
    uri="vless://${uuid}@${server}:${port}?type=ws&security=none&encryption=x25519&path=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$path")#${name_enc}"
  else
    uri="vless://${uuid}@${server}:${port}?type=tcp&security=none&encryption=x25519#${name_enc}"
  fi

  append_uri "$name" "$uri"

  tmp=$(mktemp)
  jq -n --arg uuid "$uuid" --arg port "$port" --arg tag "$name" --arg uri "$uri" --arg proto "$PROTOCOL" --arg prefix "$prefix" \
    '{uuid:$uuid,port:($port|tonumber),tag:$tag,uri:$uri,protocol:$proto,prefix:$prefix}' > "$tmp"
  tmp2=$(mktemp)
  sudo jq --argfile n "$tmp" '. += [$n]' "$VLESS_JSON" > "$tmp2" 2>/dev/null || (cat "$tmp" > "$VLESS_JSON" && tmp2="$VLESS_JSON")
  sudo mv "$tmp2" "$VLESS_JSON" 2>/dev/null || true
  rm -f "$tmp"

  echo "已写入入站文件: ${XRAY_DIR}/${fname}"
  echo "URI: $uri"
  echo "提示：请运行 'sudo xray test -confdir /etc/xray' 验证配置，或重启 Xray：sudo systemctl restart xray"
}

main "$@"