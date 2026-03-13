#!/bin/bash
set -e

REPO="johnmatthewtennant/reminderkit-cli"
SKILL="apple-reminders"
FORMULA="johnmatthewtennant/tap/reminderkit-cli"

echo "Installing reminderkit-cli..."

# Install or upgrade via Homebrew
if brew list reminderkit-cli &>/dev/null; then
  brew upgrade "$FORMULA" 2>/dev/null || echo "  reminderkit-cli $(brew list --versions reminderkit-cli | awk '{print $2}') (latest)"
else
  brew install "$FORMULA"
fi

# Install Claude Code skill
echo "Installing Claude Code skill..."
mkdir -p ~/.agents/skills/"$SKILL"
curl -sL "https://raw.githubusercontent.com/$REPO/master/.agents/skills/$SKILL/SKILL.md" \
  -o ~/.agents/skills/"$SKILL"/SKILL.md
mkdir -p ~/.claude/skills
ln -sfn ~/.agents/skills/"$SKILL" ~/.claude/skills/"$SKILL"

echo ""
echo "Done! Use /apple-reminders in Claude Code."
