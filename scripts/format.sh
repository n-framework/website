#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=packages/acore-scripts/src/logger.sh
source "${SCRIPT_DIR}/../packages/acore-scripts/src/logger.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

acore_log_info "Running format for all projects..."

for helper_format in "${SCRIPT_DIR}/helpers"/*/format.sh; do
	[ -f "$helper_format" ] || continue
	bash "$helper_format"
done

echo ""
acore_log_success "✅ Formatting complete!"
