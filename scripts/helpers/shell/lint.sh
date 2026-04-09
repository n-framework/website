#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=packages/acore-scripts/src/logger.sh
source "${SCRIPT_DIR}/../../../packages/acore-scripts/src/logger.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "$REPO_ROOT"

acore_log_section "🔍 Linting shell scripts with shellcheck..."

mapfile -t shellcheck_scripts < <(fd -e sh -t f . "$REPO_ROOT/scripts")
if [ ${#shellcheck_scripts[@]} -eq 0 ]; then
	acore_log_warning "No shell scripts found."
	exit 0
fi

shellcheck "${shellcheck_scripts[@]}"

acore_log_success "✨ Shell linting complete!"
