#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=packages/acore-scripts/src/logger.sh
source "${SCRIPT_DIR}/../packages/acore-scripts/src/logger.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

acore_log_section "🚀 Setting up development environment..."

if [ -f .gitmodules ]; then
	acore_log_info "📦 Initializing submodules..."
	git submodule update --init --recursive --quiet
fi

acore_log_success "✅ Setup complete!"
