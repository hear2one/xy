# Shared by generated installers; keep this file free of side effects.
validate_domain() {
  local domain="$1" label
  local -a labels
  [[ ${#domain} -le 253 && "$domain" == *.* && "$domain" != *. ]] || return 1
  IFS='.' read -r -a labels <<< "$domain"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

normalize_proxy_origin() {
  local url="$1" scheme authority host port
  [[ "$url" =~ [[:space:]] ]] && return 1
  [[ "$url" =~ ^https?:// ]] || url="https://${url}"
  [[ "$url" =~ ^(https?)://([^/?#]+)([/?#].*)?$ ]] || return 1
  scheme="${BASH_REMATCH[1]}"
  authority="${BASH_REMATCH[2]}"
  host="${authority%%:*}"
  validate_domain "$host" || return 1
  if [[ "$authority" == *:* ]]; then
    port="${authority#*:}"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
  fi
  printf '%s://%s' "$scheme" "${authority,,}"
}
