#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=packages/acore-scripts/src/logger.sh
source "${SCRIPT_DIR}/../../../packages/acore-scripts/src/logger.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "$REPO_ROOT"

acore_log_section "🐚 Formatting shell scripts with shfmt..."

fd -e sh -t f . "$REPO_ROOT/scripts/helpers" | xargs -d '\n' shfmt -w -sr -ci -ln bash

acore_log_success "✅ Shell formatting complete!"
