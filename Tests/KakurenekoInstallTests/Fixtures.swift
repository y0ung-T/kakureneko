import Foundation

/// Realistic pre-existing user configs (comments, odd formatting, tables, user hooks).
enum Fixtures {
    /// Gemini CLI settings (JSONC: line + block comments, a user hook of its own).
    static let geminiSettings = """
    {
      // Gemini CLI settings
      "theme": "GitHub",
      "selectedAuthType": "gemini-api-key",
      /* MCP servers */
      "mcpServers": {
        "github": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"] }
      },
      "hooks": {
        "AfterAgent": [
          { "hooks": [ { "name": "my-logger", "type": "command", "command": "~/bin/log-turn.sh", "timeout": 2000 } ] }
        ]
      }
    }

    """

    /// Cursor hooks (strict JSON, tab indentation, a user `stop` hook).
    static let cursorHooks = "{\n\t\"version\": 1,\n\t\"hooks\": {\n\t\t\"afterFileEdit\": [{\"command\": \"./hooks/format.sh\"}],\n\t\t\"stop\": [\n\t\t\t{ \"command\": \"say done\", \"timeout\": 3 }\n\t\t]\n\t}\n}\n"

    /// Codex config.toml: comments, an existing `notify`, tables, a multi-line array with brackets in a comment.
    static let codexConfig = """
    # Codex configuration
    model = "gpt-5.5"  # default model
    approval_policy = "on-request"
    notify = ["terminal-notifier", "-title", "Codex"]   # desktop ping

    [tui]
    notifications = true

    [mcp_servers.docs]
    command = "npx"
    args = [
      "-y",   # comment inside an array with [brackets]
      "docs-mcp",
    ]

    [profiles.fast]
    model = "gpt-5.5-mini"

    """

    /// Codex config without `notify` and without a trailing newline.
    static let codexConfigNoNotify = "model = \"o4\"\n\n[tui]\nnotifications = false"

    /// Codex hooks.json with a user Stop hook.
    static let codexHooks = """
    {
      "hooks": {
        "Stop": [
          { "hooks": [ { "type": "command", "command": "/usr/local/bin/my-stop-hook", "timeout": 10 } ] }
        ]
      }
    }

    """

    /// Aider config with comments and an existing notifications command.
    static let aiderConfig = """
    # Aider config
    model: sonnet
    # Notifications
    notifications: true
    notifications-command: "say 'Aider is ready'"
    auto-commits: false   # keep commits manual

    """

    /// Antigravity hooks keyed by hook name.
    static let agyHooks = """
    {
      "my-guard": { "PreToolUse": [ { "type": "command", "command": "~/bin/guard.sh", "timeout": 10 } ] }
    }

    """

    /// Qwen settings (JSONC, CRLF line endings).
    static let qwenSettings = "{\r\n  // qwen\r\n  \"general\": { \"terminalBell\": true },\r\n  \"model\": { \"name\": \"qwen3-coder\" }\r\n}\r\n"

    /// Factory Droid settings.json without hooks.json.
    static let droidSettings = """
    {
      "model": "claude-sonnet-4",
      "completionSound": "fx-ok01",
      "hooks": {
        "PostToolUse": [ { "matcher": "Edit", "hooks": [ { "type": "command", "command": "npm run lint", "timeout": 30 } ] } ]
      }
    }

    """

    /// Auggie settings, single line, no trailing newline.
    static let auggieSettings = "{\"notificationMode\":\"bell\",\"model\":\"sonnet\"}"

    /// Devin CLI config.
    static let devinConfig = """
    {
        "read_config_from": { "claude": true },
        "theme": "dark"
    }

    """

    /// Windsurf hooks with a user hook.
    static let windsurfHooks = """
    { "hooks": {
      "post_write_code": [ { "command": "prettier --write", "show_output": true } ]
    } }

    """

    /// A BOM + empty object.
    static let bomEmpty = "\u{FEFF}{}\n"
}
