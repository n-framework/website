#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=packages/acore-scripts/src/logger.sh
source "${SCRIPT_DIR}/../packages/acore-scripts/src/logger.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

acore_log_section "🔍 Running helper lint scripts..."
for helper_lint in "${SCRIPT_DIR}/helpers"/*/lint.sh; do
	[ -f "$helper_lint" ] || continue
	helper_name="$(basename "$(dirname "$helper_lint")")"
	acore_log_info "▶️ Running ${helper_name} lint..."
	bash "$helper_lint"
done

acore_log_success "✨ Linting complete!"
