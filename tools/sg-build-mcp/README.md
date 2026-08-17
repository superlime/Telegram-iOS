# sg-build-mcp

A dependency-free MCP stdio server that gives a Claude session shell access to
this Mac, so a session without its own macOS shell can drive the Swiftgram
build (bazel / Make.py / xcodebuild / simctl / devicectl).

Commands run detached and stream to a log file, so a long bazel build never
times out an MCP call: start a job, then poll it.

## Register it with the Claude desktop app

Edit `~/Library/Application Support/Claude/claude_desktop_config.json` and merge
in the `sg-build` entry:

```json
{
  "mcpServers": {
    "sg-build": {
      "command": "/usr/bin/python3",
      "args": ["/Users/rentamac/Swiftgram/tools/sg-build-mcp/server.py"]
    }
  }
}
```

Then quit the Claude desktop app completely (Cmd-Q, not just close the window)
and reopen it. The server's tools become available to Cowork sessions bridged to
this machine as `mcp__remote-devices__sg-build__*`.

## Tools

| Tool | Purpose |
| --- | --- |
| `sg_run` | Start a command in the background, returns a `job_id`. Defaults to cwd `~/Swiftgram`. |
| `sg_status` | Running/exited plus the tail of the job's output. |
| `sg_wait` | Block until exit or timeout (max 240s), then report. |
| `sg_grep_log` | Case-insensitive substring search over a job's full log — use for `error:` in build output. |
| `sg_stop` | SIGTERM the job's process group. |
| `sg_jobs` | List jobs from this server session. |

Jobs are tracked in memory; log files persist under `~/.sg-build-mcp/logs/`.
Restarting the desktop app forgets job ids but keeps the logs.

## Smoke test

```sh
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | /usr/bin/python3 tools/sg-build-mcp/server.py
```

Two JSON lines back means the server is healthy.

## Security

Any client that can reach this server runs arbitrary commands as this user, with
your login shell environment (including build secrets from `~/.zshrc`). Register
it only in a Claude desktop app you control, and remove the entry when you are
done with it.

> Note: `sg_wait` caps at 45s because the desktop app times an MCP call out at 60s. Long builds are polled with `sg_status`, not waited on.
