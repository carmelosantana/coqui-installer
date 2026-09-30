#!/usr/bin/env bats

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; CFG="$ROOT/docker/openclaw.default.json"; }

@test "openclaw.default.json exists and is valid JSON" {
    [ -f "$CFG" ]
    run python3 -c "import json,sys; json.load(open('$CFG'))"
    [ "$status" -eq 0 ]
}

# php-agents' OpenAICompatibleProvider builds the chat URL by plain string
# concatenation -- "{baseUrl}/chat/completions" -- and OllamaProvider's own
# default baseUrl is http://localhost:11434/v1. A baseUrl without the /v1
# suffix therefore POSTs to :11434/chat/completions and Ollama answers 404,
# so every turn fails for anyone using the shipped default.
@test "ollama baseUrl carries the /v1 suffix the provider concatenates onto" {
    run python3 -c "
import json
d = json.load(open('$CFG'))
url = d['models']['providers']['ollama']['baseUrl']
assert url.endswith('/v1'), 'ollama baseUrl must end with /v1, got: ' + url
"
    [ "$status" -eq 0 ]
}

# The hostname is deliberate: compose.yaml maps host.docker.internal to
# host-gateway so a container reaches an Ollama daemon on the host. Users
# pointing at another machine override it in their own config.
@test "ollama baseUrl still targets host.docker.internal by default" {
    grep -q 'host.docker.internal:11434' "$CFG"
}

@test "the sole required model field is present" {
    run python3 -c "
import json
d = json.load(open('$CFG'))
assert d['agents']['defaults']['model']['primary'], 'agents.defaults.model.primary is required'
"
    [ "$status" -eq 0 ]
}
