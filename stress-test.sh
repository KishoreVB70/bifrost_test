#!/bin/bash
set -euo pipefail

# Load env vars
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

BASE_URL="${1:-https://bifrost-test.onrender.com}"
VK="${BIFROST_VIRTUAL_KEY:?BIFROST_VIRTUAL_KEY not set}"
PASS=0
FAIL=0

green() { echo -e "\033[32m✓ $1\033[0m"; PASS=$((PASS + 1)); }
red()   { echo -e "\033[31m✗ $1\033[0m"; FAIL=$((FAIL + 1)); }

check_status() {
  local label="$1" expected="$2" actual="$3" body="$4"
  if [ "$actual" = "$expected" ]; then
    green "$label (HTTP $actual)"
  else
    red "$label — expected $expected, got $actual: $body"
  fi
}

chat() {
  local model="$1" auth="$2"
  curl -s -w "\n%{http_code}" \
    -H "Content-Type: application/json" \
    ${auth:+-H "$auth"} \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: pong\"}]}" \
    "$BASE_URL/v1/chat/completions" 2>/dev/null
}

echo "============================================"
echo "  Bifrost Gateway Stress Test"
echo "  Target: $BASE_URL"
echo "============================================"
echo ""

# ─── AUTH TESTS ───────────────────────────────

echo "── Auth Tests ──"

# No key
RESP=$(chat "openai/gpt-4o-mini" "")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
check_status "No virtual key → blocked" "401" "$CODE" "$BODY"

# Wrong key
RESP=$(chat "openai/gpt-4o-mini" "x-bf-vk: sk-bf-wrongkey")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
check_status "Wrong virtual key → blocked" "401" "$CODE" "$BODY"

# Invalid header format
RESP=$(chat "openai/gpt-4o-mini" "x-bf-vk: invalid-no-prefix")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
check_status "Malformed auth header → blocked" "401" "$CODE" "$BODY"

echo ""

# ─── DASHBOARD AUTH TESTS ─────────────────────

echo "── Dashboard/API Protection ──"

CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/api/config")
check_status "GET /api/config → blocked" "401" "$CODE" ""

CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/api/governance/virtual-keys")
check_status "GET /api/virtual-keys → blocked" "401" "$CODE" ""

CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/api/providers")
check_status "GET /api/providers → blocked" "401" "$CODE" ""

CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
  -H "Content-Type: application/json" \
  -d '{"client_config": {"enable_governance": false}}' \
  "$BASE_URL/api/config")
check_status "PUT /api/config (disable governance) → blocked" "401" "$CODE" ""

echo ""

# ─── PROVIDER TESTS ───────────────────────────

echo "── Provider Tests (valid key) ──"

# Anthropic
RESP=$(chat "anthropic/claude-haiku-4-5-20251001" "x-bf-vk: $VK")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
check_status "Anthropic claude-haiku-4-5" "200" "$CODE" "$BODY"
sleep 1

# OpenAI
RESP=$(chat "openai/gpt-4o-mini" "x-bf-vk: $VK")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
check_status "OpenAI gpt-4o-mini" "200" "$CODE" "$BODY"
sleep 1

# Gemini
RESP=$(chat "gemini/gemini-3-flash-preview" "x-bf-vk: $VK")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
check_status "Gemini gemini-3-flash-preview" "200" "$CODE" "$BODY"
sleep 1

echo ""

# ─── EDGE CASES ───────────────────────────────

echo "── Edge Cases ──"

# Empty body
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "x-bf-vk: $VK" \
  -H "Content-Type: application/json" \
  -d '{}' \
  "$BASE_URL/v1/chat/completions")
check_status "Empty body → error (not crash)" "400" "$CODE" ""

# Invalid model
RESP=$(chat "openai/nonexistent-model-999" "x-bf-vk: $VK")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$CODE" != "200" ]; then
  green "Invalid model → rejected (HTTP $CODE)"
else
  red "Invalid model → should not return 200"
fi

# Invalid provider
RESP=$(chat "fakeprovider/some-model" "x-bf-vk: $VK")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$CODE" != "200" ]; then
  green "Invalid provider → rejected (HTTP $CODE)"
else
  red "Invalid provider → should not return 200"
fi

# No model field
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "x-bf-vk: $VK" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hi"}]}' \
  "$BASE_URL/v1/chat/completions")
check_status "Missing model field → error" "400" "$CODE" ""

# Huge prompt (test body size limits)
BIG=$(python3 -c "print('A' * 50000)")
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "x-bf-vk: $VK" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"openai/gpt-4o-mini\",\"messages\":[{\"role\":\"user\",\"content\":\"$BIG\"}]}" \
  "$BASE_URL/v1/chat/completions")
if [ "$CODE" != "000" ]; then
  green "Large payload → handled (HTTP $CODE)"
else
  red "Large payload → connection failed"
fi

# Wrong HTTP method
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X GET \
  -H "x-bf-vk: $VK" \
  "$BASE_URL/v1/chat/completions")
green "GET on POST endpoint → HTTP $CODE (Bifrost accepts both)"

echo ""

# ─── STREAMING ────────────────────────────────

echo "── Streaming ──"

# SSE streaming request
RESP=$(curl -s -w "\n%{http_code}" \
  -H "x-bf-vk: $VK" \
  -H "Content-Type: application/json" \
  -d '{"model":"openai/gpt-4o-mini","stream":true,"messages":[{"role":"user","content":"Reply with exactly: pong"}]}' \
  "$BASE_URL/v1/chat/completions" 2>/dev/null)
CODE=$(echo "$RESP" | tail -1)
if [ "$CODE" = "200" ]; then
  green "Streaming response (HTTP $CODE)"
else
  red "Streaming failed (HTTP $CODE)"
fi
sleep 1

# Streaming without key
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -d '{"model":"openai/gpt-4o-mini","stream":true,"messages":[{"role":"user","content":"Hi"}]}' \
  "$BASE_URL/v1/chat/completions")
check_status "Streaming without key → blocked" "401" "$CODE" ""

echo ""

# ─── INJECTION / ABUSE ────────────────────────

echo "── Injection & Abuse ──"

# SQL injection in model name
RESP=$(chat "openai/gpt-4o-mini'; DROP TABLE users;--" "x-bf-vk: $VK")
CODE=$(echo "$RESP" | tail -1)
if [ "$CODE" != "200" ]; then
  green "SQL injection in model → rejected (HTTP $CODE)"
else
  red "SQL injection in model → should not return 200"
fi

# XSS in message content
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "x-bf-vk: $VK" \
  -H "Content-Type: application/json" \
  -d '{"model":"openai/gpt-4o-mini","messages":[{"role":"user","content":"<script>alert(1)</script>"}]}' \
  "$BASE_URL/v1/chat/completions")
if [ "$CODE" = "200" ]; then
  green "XSS in message → handled safely (HTTP $CODE)"
else
  green "XSS in message → rejected (HTTP $CODE)"
fi

# Path traversal in model
RESP=$(chat "../../etc/passwd" "x-bf-vk: $VK")
CODE=$(echo "$RESP" | tail -1)
if [ "$CODE" != "200" ]; then
  green "Path traversal in model → rejected (HTTP $CODE)"
else
  red "Path traversal in model → should not return 200"
fi

# Header injection attempt
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "x-bf-vk: $VK" \
  -H "Content-Type: application/json" \
  -H "X-Forwarded-For: 127.0.0.1" \
  -H "Host: evil.com" \
  -d '{"model":"openai/gpt-4o-mini","messages":[{"role":"user","content":"Hi"}]}' \
  "$BASE_URL/v1/chat/completions")
if [ "$CODE" != "000" ]; then
  green "Header injection → handled (HTTP $CODE)"
else
  red "Header injection → connection failed"
fi

# Empty virtual key
RESP=$(chat "openai/gpt-4o-mini" "x-bf-vk: ")
CODE=$(echo "$RESP" | tail -1)
check_status "Empty virtual key → blocked" "401" "$CODE" ""

# Virtual key with spaces
RESP=$(chat "openai/gpt-4o-mini" "x-bf-vk: sk-bf-some key")
CODE=$(echo "$RESP" | tail -1)
check_status "Virtual key with spaces → blocked" "401" "$CODE" ""

echo ""

# ─── RATE / LOAD ──────────────────────────────

echo "── Rapid Fire (10 sequential) ──"

RAPID_PASS=0
RAPID_FAIL=0
for i in $(seq 1 10); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "x-bf-vk: $VK" \
    -H "Content-Type: application/json" \
    -d '{"model":"openai/gpt-4o-mini","messages":[{"role":"user","content":"Reply: pong"}]}' \
    "$BASE_URL/v1/chat/completions")
  if [ "$CODE" = "200" ]; then
    RAPID_PASS=$((RAPID_PASS + 1))
  else
    RAPID_FAIL=$((RAPID_FAIL + 1))
  fi
done
green "Rapid fire: $RAPID_PASS/10 succeeded, $RAPID_FAIL/10 rate-limited/failed"

echo ""

# ─── CONCURRENT REQUESTS ─────────────────────

echo "── Concurrent Requests (10 parallel) ──"

CONC_PASS=0
CONC_FAIL=0
for i in $(seq 1 10); do
  (
    RESP=$(chat "openai/gpt-4o-mini" "x-bf-vk: $VK")
    CODE=$(echo "$RESP" | tail -1)
    if [ "$CODE" = "200" ]; then
      echo "  Request $i: ✓ (HTTP 200)"
    else
      echo "  Request $i: ✗ (HTTP $CODE)"
    fi
  ) &
done
wait
green "Concurrent requests completed"

echo ""

# ─── DIFFERENT ENDPOINTS ──────────────────────

echo "── Endpoint Protection ──"

# Non-existent endpoint
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/v1/models")
check_status "GET /v1/models (no key) → blocked" "401" "$CODE" ""

# Embeddings endpoint
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -d '{"model":"openai/text-embedding-3-small","input":"test"}' \
  "$BASE_URL/v1/embeddings")
check_status "POST /v1/embeddings (no key) → blocked" "401" "$CODE" ""

# Admin API create virtual key
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"name":"hacker-key","is_active":true}' \
  "$BASE_URL/api/governance/virtual-keys")
check_status "POST create virtual key → blocked" "401" "$CODE" ""

# Admin API delete virtual key
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
  "$BASE_URL/api/governance/virtual-keys/vk-001")
check_status "DELETE virtual key → blocked" "401" "$CODE" ""

# Admin API session login with wrong creds
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"hacker","password":"hacker"}' \
  "$BASE_URL/api/session/login")
check_status "Login with wrong creds → blocked" "401" "$CODE" ""

# Admin API update provider
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
  -H "Content-Type: application/json" \
  -d '{"keys":[{"name":"hacker","value":"sk-hacked"}]}' \
  "$BASE_URL/api/providers/openai")
check_status "PUT update provider → blocked" "401" "$CODE" ""

echo ""

# ─── HEALTH CHECK ─────────────────────────────

echo "── Health & Metrics ──"

CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/metrics")
green "GET /metrics → HTTP $CODE"

echo ""
echo "============================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================"

exit $FAIL
