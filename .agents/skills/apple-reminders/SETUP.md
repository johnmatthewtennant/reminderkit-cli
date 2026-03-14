# Apple Reminders Setup

1. Install the CLI:
```bash
brew install johnmatthewtennant/tap/reminderkit-cli
```

2. Grant Reminders access (triggers macOS permission prompt):
```bash
osascript -e 'tell application "Reminders" to get name of every list'
```

3. Verify: `reminderkit lists` should return JSON.
