#!/usr/bin/env bash
# Live check of every AI provider the app supports: a real photo and a real
# text request through the app's own analyzers, against the real services.
#
#   scripts/test_providers_live.sh
#
# Put keys in ~/.bitewise/provider_keys.env (chmod 600 — see
# scripts/provider_keys.env.example). Providers without a key are skipped.
# The cheapest way to cover the popular models at once is ONE OpenRouter
# key: the run then exercises GPT, Claude, Gemini, Grok, DeepSeek, GLM,
# Qwen, Kimi, Llama, Mistral and a free Gemma through it.
#
# Each provider costs one small vision call and one tiny text call.
set -euo pipefail
cd "$(dirname "$0")/../app"
exec flutter test test_live/providers_live_test.dart "$@"
