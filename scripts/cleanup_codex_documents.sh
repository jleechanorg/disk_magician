#!/usr/bin/env bash
# cleanup_codex_documents.sh — safety-gated cleanup of Codex-app task scratch.
# Delegates to canonical disk-magician entry point.
exec disk-magician cleanup-codex-documents "$@"
