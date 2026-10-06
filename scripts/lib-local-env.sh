# Sourced by scripts that need machine-specific settings. Loads scripts/local.env (git-ignored;
# template in scripts/local.env.example) without overriding anything already set in the
# environment, so `FD_UITEST_HOST=… ./scripts/smoke.sh` still wins over the file.
fd_load_local_env() {
  local file
  file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/local.env"
  [ -f "$file" ] || return 0
  local line name value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    name=${line%%=*}; value=${line#*=}
    [[ "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    [ -n "${!name+x}" ] && continue
    export "$name=$value"
  done < "$file"
}
