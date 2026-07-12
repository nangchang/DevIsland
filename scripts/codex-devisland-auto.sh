#!/bin/sh
# Launch Codex while keeping DevIsland status tracking and delegating approval
# decisions to Codex's configured reviewer (for example, Auto-review).

set -eu

export DEVISLAND_CODEX_APPROVAL_OWNER=codex
exec codex "$@"
