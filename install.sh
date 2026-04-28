#!/usr/bin/env bash
# AgentForce installer — Claude Code skill
# Usage: curl -fsSL https://raw.githubusercontent.com/TokenFlyAI/AgentForce/main/install.sh | bash

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/TokenFlyAI/AgentForce/main"
SKILL_SRC="${REPO_RAW}/.claude/commands/agentforce.md"
SKILL_DIR="${HOME}/.claude/commands"
SKILL_DEST="${SKILL_DIR}/agentforce.md"

echo "⚔️  Installing AgentForce..."

# Verify curl is available
if ! command -v curl >/dev/null 2>&1; then
  echo "❌ curl is required. Please install curl and re-run."
  exit 1
fi

# Ensure target directory exists
mkdir -p "${SKILL_DIR}"

# If a previous install exists, back it up
if [ -f "${SKILL_DEST}" ] && [ ! -L "${SKILL_DEST}" ]; then
  BACKUP="${SKILL_DEST}.bak-$(date +%s)"
  mv "${SKILL_DEST}" "${BACKUP}"
  echo "ℹ️  Backed up existing skill → ${BACKUP}"
elif [ -L "${SKILL_DEST}" ]; then
  rm "${SKILL_DEST}"
  echo "ℹ️  Removed existing symlink at ${SKILL_DEST}"
fi

# Download the skill
echo "→ Fetching agentforce.md from GitHub..."
if ! curl -fsSL "${SKILL_SRC}" -o "${SKILL_DEST}"; then
  echo "❌ Download failed. Check your network or the URL: ${SKILL_SRC}"
  exit 1
fi

# Sanity check the file
if [ ! -s "${SKILL_DEST}" ]; then
  echo "❌ Installed file is empty. Aborting."
  rm -f "${SKILL_DEST}"
  exit 1
fi

echo ""
echo "✅ AgentForce installed → ${SKILL_DEST}"
echo ""
echo "Next step: open Claude Code in any project and run:"
echo "    /agentforce <your task>"
echo ""
echo "Example:"
echo "    /agentforce Fix the failing test in auth.py"
echo ""
echo "Re-run this installer any time to update:"
echo "    curl -fsSL ${REPO_RAW}/install.sh | bash"
