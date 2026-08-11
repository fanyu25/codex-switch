#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/bin/codex-switch"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

make_env() {
  HOME_DIR="$ROOT/home-$1"
  STATE_DIR="$ROOT/state-$1"
  BIN_DIR="$ROOT/bin-$1"
  mkdir -p "$HOME_DIR" "$STATE_DIR/profiles" "$BIN_DIR"
  cat >"$BIN_DIR/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == login && "${2:-}" == --with-api-key ]]; then
  IFS= read -r key
  printf '{"auth_mode":"apikey","token":"%s"}\n' "$key" > "$CODEX_HOME/auth.json"
elif [[ "${1:-}" == login ]]; then
  printf '{"auth_mode":"chatgpt","token":"chatgpt"}\n' > "$CODEX_HOME/auth.json"
fi
EOF
  cat >"$BIN_DIR/codex-provider" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$BIN_DIR/codex" "$BIN_DIR/codex-provider"
  export HOME="$ROOT/home-root-$1"
  export CODEX_HOME="$HOME_DIR"
  export CODEX_SWITCH_HOME="$STATE_DIR"
  export CODEX_PROVIDER_SYNC_BIN="$BIN_DIR/codex-provider"
  export PATH="$BIN_DIR:$PATH"
}

assert_file_contains() {
  local file="$1" text="$2"
  grep -Fq "$text" "$file" || { printf 'expected %s to contain %s\n' "$file" "$text" >&2; return 1; }
}

test_use_persists_outgoing_config() {
  make_env use
  printf '{"auth_mode":"apikey","token":"api1"}\n' > "$CODEX_HOME/auth.json"
  cat > "$CODEX_HOME/config.toml" <<'EOF'
model_provider = "codex-switch-api"
marker = "changed-before-switch"
[model_providers.codex-switch-api]
base_url = "https://example.test/v1"
EOF
  mkdir -p "$CODEX_SWITCH_HOME/profiles/api1" "$CODEX_SWITCH_HOME/profiles/api2"
  cp "$CODEX_HOME/auth.json" "$CODEX_SWITCH_HOME/profiles/api1/auth.json"
  printf 'marker = "old"\n' > "$CODEX_SWITCH_HOME/profiles/api1/config.toml"
  printf '{"auth_mode":"apikey","token":"api2"}\n' > "$CODEX_SWITCH_HOME/profiles/api2/auth.json"
  cp "$CODEX_HOME/config.toml" "$CODEX_SWITCH_HOME/profiles/api2/config.toml"

  "$SCRIPT" use api2 --no-reload-vscode >/dev/null
  assert_file_contains "$CODEX_SWITCH_HOME/profiles/api1/config.toml" 'changed-before-switch'
}

test_new_api_inherits_active_config() {
  make_env api
  printf '{"auth_mode":"apikey","token":"api1"}\n' > "$CODEX_HOME/auth.json"
  cat > "$CODEX_HOME/config.toml" <<'EOF'
model_provider = "codex-switch-api"
marker = "shared-tuning"
[model_providers.codex-switch-api]
base_url = "https://example.test/v1"
wire_api = "responses"
EOF
  mkdir -p "$CODEX_SWITCH_HOME/profiles/api1"
  cp "$CODEX_HOME/auth.json" "$CODEX_SWITCH_HOME/profiles/api1/auth.json"
  export TEST_API_KEY=api2

  "$SCRIPT" api api2 --url https://example.test/v1 --key-env TEST_API_KEY --no-reload-vscode >/dev/null
  assert_file_contains "$CODEX_SWITCH_HOME/profiles/api2/config.toml" 'shared-tuning'
  assert_file_contains "$CODEX_SWITCH_HOME/profiles/api2/config.toml" 'https://example.test/v1'
}

test_login_persists_outgoing_config() {
  make_env login
  printf '{"auth_mode":"apikey","token":"api1"}\n' > "$CODEX_HOME/auth.json"
  cat > "$CODEX_HOME/config.toml" <<'EOF'
model_provider = "codex-switch-api"
marker = "api-before-chatgpt"
[model_providers.codex-switch-api]
base_url = "https://api.openai.com/v1"
EOF
  mkdir -p "$CODEX_SWITCH_HOME/profiles/api1"
  cp "$CODEX_HOME/auth.json" "$CODEX_SWITCH_HOME/profiles/api1/auth.json"

  "$SCRIPT" login chatgpt1 --no-reload-vscode >/dev/null
  assert_file_contains "$CODEX_SWITCH_HOME/profiles/api1/config.toml" 'api-before-chatgpt'
  [[ ! -e "$CODEX_SWITCH_HOME/profiles/chatgpt1/config.toml" ]]
}

test_duplicate_profiles_rejected() {
  make_env duplicate
  printf '{"auth_mode":"apikey","token":"same"}\n' > "$CODEX_HOME/auth.json"
  cat > "$CODEX_HOME/config.toml" <<'EOF'
model_provider = "codex-switch-api"
[model_providers.codex-switch-api]
base_url = "https://example.test/v1"
EOF
  mkdir -p "$CODEX_SWITCH_HOME/profiles/one" "$CODEX_SWITCH_HOME/profiles/two" "$CODEX_SWITCH_HOME/profiles/target"
  cp "$CODEX_HOME/auth.json" "$CODEX_SWITCH_HOME/profiles/one/auth.json"
  cp "$CODEX_HOME/auth.json" "$CODEX_SWITCH_HOME/profiles/two/auth.json"
  printf 'one\n' > "$CODEX_SWITCH_HOME/profiles/one/config.toml"
  printf 'two\n' > "$CODEX_SWITCH_HOME/profiles/two/config.toml"
  printf '{"auth_mode":"apikey","token":"target"}\n' > "$CODEX_SWITCH_HOME/profiles/target/auth.json"
  cp "$CODEX_HOME/config.toml" "$CODEX_SWITCH_HOME/profiles/target/config.toml"
  before_one="$(sha256sum "$CODEX_SWITCH_HOME/profiles/one/config.toml")"
  before_two="$(sha256sum "$CODEX_SWITCH_HOME/profiles/two/config.toml")"

  if "$SCRIPT" use target --no-reload-vscode >/dev/null 2>&1; then
    printf 'expected duplicate profile switch to fail\n' >&2
    return 1
  fi
  [[ "$before_one" == "$(sha256sum "$CODEX_SWITCH_HOME/profiles/one/config.toml")" ]]
  [[ "$before_two" == "$(sha256sum "$CODEX_SWITCH_HOME/profiles/two/config.toml")" ]]
}

test_url_mismatch_does_not_persist() {
  make_env mismatch
  printf '{"auth_mode":"apikey","token":"api1"}\n' > "$CODEX_HOME/auth.json"
  cat > "$CODEX_HOME/config.toml" <<'EOF'
model_provider = "codex-switch-api"
marker = "must-remain-active-only"
[model_providers.codex-switch-api]
base_url = "https://one.example/v1"
EOF
  mkdir -p "$CODEX_SWITCH_HOME/profiles/api1" "$CODEX_SWITCH_HOME/profiles/api2"
  cp "$CODEX_HOME/auth.json" "$CODEX_SWITCH_HOME/profiles/api1/auth.json"
  printf 'saved-before-mismatch\n' > "$CODEX_SWITCH_HOME/profiles/api1/config.toml"
  printf '{"auth_mode":"apikey","token":"api2"}\n' > "$CODEX_SWITCH_HOME/profiles/api2/auth.json"
  sed 's#one.example#two.example#' "$CODEX_HOME/config.toml" > "$CODEX_SWITCH_HOME/profiles/api2/config.toml"

  if "$SCRIPT" use api2 --no-reload-vscode >/dev/null 2>&1; then
    printf 'expected URL mismatch switch to fail\n' >&2
    return 1
  fi
  assert_file_contains "$CODEX_SWITCH_HOME/profiles/api1/config.toml" 'saved-before-mismatch'
}

test_use_persists_outgoing_config
test_new_api_inherits_active_config
test_login_persists_outgoing_config
test_duplicate_profiles_rejected
test_url_mismatch_does_not_persist
printf 'codex-switch config persistence tests passed\n'
