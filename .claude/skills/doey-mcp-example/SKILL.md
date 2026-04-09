---
name: doey-mcp-example
description: Example skill demonstrating MCP server integration. Not for actual use.
mcp_servers:
  - name: filesystem
    command: npx
    args: -y @modelcontextprotocol/server-filesystem /tmp
    env: {}
  - name: github
    command: github-mcp-server
    args: stdio
    env:
      GITHUB_PERSONAL_ACCESS_TOKEN: ${GITHUB_TOKEN}
---

# MCP Example Skill

This is a reference skill demonstrating the `mcp_servers` YAML frontmatter field.

## How MCP Integration Works

Skills can declare MCP server dependencies in their YAML frontmatter using the `mcp_servers` field.
When a worker is launched to execute a skill with MCP dependencies, Doey:

1. Parses the `mcp_servers` block from the skill's SKILL.md frontmatter
2. Generates a per-pane `.mcp.json` config file in `$RUNTIME_DIR/mcp/`
3. Passes `--mcp-config <path>` when launching the Claude instance
4. Cleans up MCP configs and processes on team despawn

## Frontmatter Schema

```yaml
mcp_servers:
  - name: <server-name>        # Required: unique server identifier
    command: <executable>       # Required: command to run
    args: <arg1> <arg2> ...    # Optional: space-separated arguments
    env:                        # Optional: environment variables
      KEY: value
      KEY2: ${ENV_VAR}         # Supports env var expansion
```

## Limitations

- MCP servers start at Claude launch — they cannot be added/removed at runtime
- Each team gets independent MCP server instances (no cross-team sharing)
- MCP tools appear as `mcp__<server-name>__<tool-name>` in tool listings
