#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=packages/acore-scripts/src/logger.sh
source "${SCRIPT_DIR}/../packages/acore-scripts/src/logger.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

acore_log_section "🧪 Running tests..."

if grep -q '"test"' package.json; then
	bun run test
else
	acore_log_info "📝 No test script defined in package.json"
fi

acore_log_success "✅ Tests complete!"
