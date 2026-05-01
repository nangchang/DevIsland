# CLAUDE.md

This file provides Claude Code–specific guidance for this repository.
For general project documentation (architecture, build, key files), see [AGENTS.md](AGENTS.md).

## Bridge Installation

The bridge connects Claude Code hooks to the app:

```bash
# Install bridge + patch ~/.claude/settings.json
bash scripts/install-bridge.sh

# Optional: register as LaunchAgent (auto-start on login)
bash scripts/install-launch-agent.sh
```

`install-bridge.sh` hard-codes `/Volumes/data/Github/DevIsland/scripts` as the source path — update this if working from a different clone location.

Bridge logs are written to `/tmp/DevIsland.bridge.log`. The app logs to `/tmp/DevIsland.log` and `/tmp/DevIsland.error.log` when running as a LaunchAgent.
