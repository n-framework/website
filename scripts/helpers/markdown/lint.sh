#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=packages/acore-scripts/src/logger.sh
source "${SCRIPT_DIR}/../../../packages/acore-scripts/src/logger.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "$REPO_ROOT"

acore_log_section "🔍 Linting markdown files with markdownlint-cli2..."

mapfile -t markdown_files < <(fd -e md -t f . "$REPO_ROOT")
if [ ${#markdown_files[@]} -eq 0 ]; then
	acore_log_warning "No markdown files found."
	exit 0
fi

bun run markdownlint-cli2 --fix "${markdown_files[@]}"

acore_log_success "✨ Markdown linting complete!"
