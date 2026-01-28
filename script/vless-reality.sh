#!/usr/bin/env bash
# vless-reality.sh
# 作用：交互式添加 VLESS+Reality 入站（写入 /etc/xray 顶层 JSON 文件）
set -euo pipefail
export LC_ALL=C.UTF-8

XRAY_DIR="/etc/xray"
URI_DIR="/etc/proxym-easy"
URI_FILE="${URI_DIR}/uri.json"
VLESS_JSON="/etc/proxym/vless.json"
PROTOCOL="reality"

# 简略国家映射（可后续扩展）
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
  # search for tag in existing json files
  for f in "$XRAY_DIR"/*.json; do
    [ -e "$f" ] || continue
    if grep -q "\"tag\"[[:space:]]*:[[:space:]]*\"${tag}\"" "$f" 2>/dev/null; then
      return 0
    fi
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
  local prefix="$1" proto="$2" port="$3" uuid="$4" dest="$5" sni="$6" privateKey="$7" shortId="$8" fp="$9"
  local tag="${prefix}-${proto}-${port}"
  local fname="${prefix}-${proto}-${port}.json"
  # build inbound JSON
  local json
  json=$(jq -n \
    --arg tag "$tag" \
    --arg port "$port" \
    --arg uuid "$uuid" \
    --arg dest "$dest" \
    --arg sni "$sni" \
    --arg privateKey "$privateKey" \
    --arg shortId "$shortId" \
    --arg fp "$fp" \
    '{
      "inbounds":[
        {
          "tag": $tag,
          "port": ($port|tonumber),
          "protocol": "vless",
          "settings": { "clients":[{"id":$uuid}], "decryption":"none" },
          "streamSettings": { "network":"tcp", "security":"reality", "realitySettings": { "dest": $dest, "serverNames": [$sni], "privateKey": $privateKey, "shortIds": [$shortId], "fingerprint": $fp } }
        }
      ]
    }')
  echo "$json" | sudo tee "${XRAY_DIR}/${fname}" >/dev/null
  echo "${fname}"
}

main(){
  ensure_dirs
  echo "添加 VLESS+Reality 节点"

  echo "当前已用数字前缀："
  list_used_numbers || true

  read -r -p "输入数字前缀（例如 01）: " prefix
  prefix=${prefix:-01}
  # validate numeric
  if ! echo "$prefix" | grep -qE '^[0-9]+$'; then
    echo "前缀必须为数字"
    exit 1
  fi

  read -r -p "端口 (默认 443): " port
  port=${port:-443}

  read -r -p "dest (host:port) [默认 127.0.0.1:443]: " dest
  dest=${dest:-127.0.0.1:443}

  read -r -p "SNI（留空使用 dest 主机）: " sni
  if [ -z "$sni" ]; then sni=$(echo "$dest" | cut -d: -f1); fi

  read -r -p "fingerprint (默认 chrome): " fp
  fp=${fp:-chrome}

  tag="${prefix}-${PROTOCOL}-${port}"
  if tag_exists "$tag"; then
    echo "检测到相同 tag 已存在: $tag，请更换前缀或端口"
    exit 1
  fi

  uuid=$(generate_uuid)
  shortid=$(head -c6 /dev/urandom | xxd -p -c6 2>/dev/null || date +%s)

  # try to get privateKey via xray if available
  privateKey=""
  if command -v xray >/dev/null 2>&1; then
    out=$(xray x25519 2>/dev/null || true)
    privateKey=$(echo "$out" | sed -n 's/.*PrivateKey: *//p' | tr -d '\r\n' || true)
  fi

  fname=$(write_inbound_file "$prefix" "$PROTOCOL" "$port" "$uuid" "$dest" "$sni" "$privateKey" "$shortid" "$fp")
  # build URI
  server=$(hostname -f 2>/dev/null || hostname)
  name="${FLAGS[CN]:-🌍} ${prefix}-${PROTOCOL}-${port}"
  name_enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$name" 2>/dev/null || printf '%s' "$name")
  sni_enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$sni" 2>/dev/null || printf '%s' "$sni")
  uri="vless://${uuid}@${server}:${port}?type=tcp&security=reality&encryption=none&sni=${sni_enc}&fp=${fp}&sid=${shortid}#${name_enc}"

  # append to /etc/proxym-easy/uri.json
  append_uri "$name" "$uri"

  # append to /etc/proxym/vless.json (metadata)
  tmp=$(mktemp)
  jq -n --arg uuid "$uuid" --arg port "$port" --arg tag "$name" --arg uri "$uri" --arg proto "$PROTOCOL" --arg prefix "$prefix" \
    '{uuid:$uuid,port:($port|tonumber),tag:$tag,uri:$uri,protocol:$proto,prefix:$prefix}' > "$tmp"
  # merge into vless.json
  tmp2=$(mktemp)
  sudo jq --argfile n "$tmp" '. += [$n]' "$VLESS_JSON" > "$tmp2" 2>/dev/null || (cat "$tmp" > "$VLESS_JSON" && tmp2="$VLESS_JSON")
  sudo mv "$tmp2" "$VLESS_JSON" 2>/dev/null || true
  rm -f "$tmp"

  echo "已写入入站文件: ${XRAY_DIR}/${fname}"
  echo "URI: $uri"
  echo "提示：请运行 'sudo xray test -confdir /etc/xray' 验证配置，或重启 Xray：sudo systemctl restart xray"
}

main "$@"