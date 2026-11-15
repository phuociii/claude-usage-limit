#!/bin/bash
# <xbar.title>Claude Usage</xbar.title>
# <xbar.version>1.0</xbar.version>
# <xbar.desc>Hiển thị % giới hạn 5 giờ / 7 ngày của Claude (dùng token đăng nhập của Claude Code).</xbar.desc>
# <xbar.dependencies>curl, Claude Code đã đăng nhập</xbar.dependencies>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
#
# Tên file ".5m." = SwiftBar/xbar chạy lại mỗi 5 phút.

get() { plutil -extract "$1" raw -o - - 2>/dev/null <<<"$2"; }

token="${CLAUDE_CODE_OAUTH_TOKEN:-}"
if [[ -z "$token" ]]; then
  creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  [[ -z "$creds" && -f "$HOME/.claude/.credentials.json" ]] && creds=$(cat "$HOME/.claude/.credentials.json")
  token=$(get claudeAiOauth.accessToken "$creds")
fi

if [[ -z "$token" ]]; then
  echo "✳︎ ?"
  echo "---"
  echo "Không tìm thấy token Claude Code — chạy \`claude\` để đăng nhập | color=red"
  exit 0
fi

resp=$(curl -s -m 20 -w '\n%{http_code}' https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer $token" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "Accept: application/json" \
  -H "User-Agent: claude-usage-bar/1.0")
code=${resp##*$'\n'}
body=${resp%$'\n'*}

if [[ "$code" != 2* ]]; then
  echo "✳︎ !"
  echo "---"
  if [[ "$code" == 401 || "$code" == 403 ]]; then
    echo "Token hết hạn — chạy \`claude\` một lần để làm mới | color=red"
  else
    echo "Lỗi HTTP $code | color=red"
  fi
  echo "Thử lại | refresh=true"
  exit 0
fi

pct() { local v; v=$(get "$1.utilization" "$body"); [[ -n "$v" ]] && printf '%.0f' "$v"; }

remaining() {
  local r ts now s d h m
  r=$(get "$1.resets_at" "$body"); [[ -z "$r" ]] && return
  ts=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${r:0:19}" +%s 2>/dev/null) || return
  now=$(date +%s); s=$((ts - now)); (( s < 0 )) && s=0
  d=$((s / 86400)); h=$((s % 86400 / 3600)); m=$((s % 3600 / 60))
  if (( d > 0 )); then echo "reset sau ${d}n ${h}g"
  elif (( h > 0 )); then echo "reset sau ${h}g ${m}p"
  else echo "reset sau ${m}p"; fi
}

colorfor() { local p=${1:-0}; if (( p >= 90 )); then echo red; elif (( p >= 70 )); then echo orange; fi; }

bar() { local p=${1:-0} n i out=""; n=$(( (p * 20 + 50) / 100 )); (( n > 20 )) && n=20
  for ((i=0;i<20;i++)); do (( i < n )) && out+="█" || out+="░"; done; echo "$out"; }

five=$(pct five_hour); seven=$(pct seven_day)

title="✳︎ ${five:-–}% · ${seven:-–}%"
c=$(colorfor "$(( ${five:-0} > ${seven:-0} ? ${five:-0} : ${seven:-0} ))")
echo "$title${c:+ | color=$c}"
echo "---"

section() {
  local key=$1 label=$2 p; p=$(pct "$key"); [[ -z "$p" ]] && return
  local c; c=$(colorfor "$p")
  echo "$label"
  echo "$(bar "$p")  ${p}% | font=Menlo size=11${c:+ color=$c}"
  echo "$(remaining "$key") | size=11 color=gray"
}
section five_hour "Phiên hiện tại (5 giờ)"
section seven_day "Tuần (7 ngày, mọi model)"
section seven_day_opus "Tuần – Opus"
section seven_day_sonnet "Tuần – Sonnet"
echo "---"
echo "Cập nhật lúc $(date +%H:%M) | size=11 color=gray"
echo "Làm mới | refresh=true"
echo "Mở trang usage trên claude.ai | href=https://claude.ai/settings/usage"
