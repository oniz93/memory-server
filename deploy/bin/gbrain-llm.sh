#!/usr/bin/env bash
# gbrain-llm.sh — toggle the optional LLM lane: keyword-only (default) <-> LLM features via OpenCode Go.
#
#   gbrain-llm.sh status
#   gbrain-llm.sh on [model]     default model: glm-5.3  (any OpenCode Go chat model id)
#   gbrain-llm.sh off
#   gbrain-llm.sh test [model]   one tiny chat completion through the shim
#
# "on" routes gbrain's chat model (synthesize / think, `transcripts ingest --facts`) and its
# query-expansion model to OpenCode Go through the loopback shim. Search itself stays keyword:
# OpenCode Go has no embeddings endpoint. Turning it on SENDS PAGE / TRANSCRIPT TEXT TO OPENCODE.
#
# Needs $GBRAIN_ROOT/secrets/llm.env containing OPENCODE_GO_API_KEY=... (0600). The script adds
# SHIM_LOCAL_KEY (the key gbrain uses towards the shim) and writes secrets/llm-client.env, which
# gbrain.service and gbrain-ingest.service load. No key is passed on a command line or stored in
# the database. Run as GBRAIN_USER (uses sudo for systemctl).
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/gbrain-env.sh"

ENV="$GBRAIN_SECRETS/llm.env"
CLIENT_ENV="$GBRAIN_SECRETS/llm-client.env"
PORT="$GBRAIN_SHIM_PORT"
gbrain() { "$GBRAIN_EXE" "$@"; }
die() { echo "error: $*" >&2; exit 1; }

local_key() { sed -n 's/^SHIM_LOCAL_KEY=//p' "$ENV"; }
shim_curl() { curl -s -H @- "$@" <<<"Authorization: Bearer $(local_key)"; }   # header on stdin, not argv

status() {
  echo "shim unit:    $(systemctl is-active gbrain-llm-shim.service 2>/dev/null || true) / $(systemctl is-enabled gbrain-llm-shim.service 2>/dev/null || true)"
  echo "chat_model:   $(gbrain config get chat_model 2>/dev/null || echo '(unset: keyword-only)')"
  echo "expansion:    $(gbrain config get expansion_model 2>/dev/null || echo '(unset)')"
  echo "default:      $(gbrain config get models.default 2>/dev/null || echo '(unset)')"
  echo "client env:   $([ -s "$CLIENT_ENV" ] && echo present || echo absent)"
  [ -r "$ENV" ] && shim_curl -m 3 "http://127.0.0.1:$PORT/health" 2>/dev/null | sed 's/^/shim health: /' || true
  echo
}

case "${1:-status}" in
  status) status ;;
  on)
    model="${2:-glm-5.3}"
    [[ "$model" =~ ^[A-Za-z0-9._-]+$ ]] || die "bad model id: $model"
    [ -r "$ENV" ] && grep -q '^OPENCODE_GO_API_KEY=.\+' "$ENV" || die "put OPENCODE_GO_API_KEY=... in $ENV (chmod 600) first"
    umask 077
    grep -q '^SHIM_LOCAL_KEY=' "$ENV" || echo "SHIM_LOCAL_KEY=$(openssl rand -hex 24)" >> "$ENV"
    chmod 600 "$ENV"
    printf 'LITELLM_BASE_URL=http://127.0.0.1:%s/v1\nLITELLM_API_KEY=%s\n' "$PORT" "$(local_key)" > "$CLIENT_ENV"
    sudo systemctl enable --now gbrain-llm-shim.service
    sleep 2
    systemctl is-active -q gbrain-llm-shim.service || die "shim failed to start: tail $GBRAIN_LOG_DIR/llm-shim.log"
    gbrain config set chat_model "litellm:$model" --yes >/dev/null
    gbrain config set expansion_model "litellm:$model" --yes >/dev/null
    gbrain config set models.default "litellm:$model" --yes >/dev/null   # think / synthesize tiers
    sudo systemctl restart gbrain.service
    echo "LLM lane ON (litellm:$model via OpenCode Go). Page/transcript text now leaves this server for LLM calls."
    echo "For LLM commands in your own shell: set -a; . $CLIENT_ENV; set +a"
    status ;;
  off)
    for k in chat_model expansion_model models.default litellm_api_key provider_base_urls.litellm; do
      gbrain config unset "$k" >/dev/null 2>&1 || true
    done
    rm -f "$CLIENT_ENV"
    sudo systemctl disable --now gbrain-llm-shim.service 2>/dev/null || true
    sudo systemctl restart gbrain.service
    echo "LLM lane OFF: keyword-only, nothing leaves this server."
    status ;;
  test)
    shim_curl -m 60 -H 'content-type: application/json' "http://127.0.0.1:$PORT/v1/chat/completions" \
      -d "{\"model\":\"${2:-glm-5.3}\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: ok\"}]}"
    echo ;;
  *) sed -n '2,17p' "$0"; exit 2 ;;
esac
