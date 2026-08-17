#!/usr/bin/env python3
"""
sg-build-mcp - a minimal MCP stdio server that runs shell commands on this Mac.

Purpose: let a Claude session that has no macOS shell of its own (e.g. Cowork
running in the cloud, bridged to this machine) drive bazel / xcodebuild /
simctl / devicectl for the Swiftgram build.

Design notes:
  * Pure Python 3 stdlib. No pip installs, no node, no network.
  * Commands run detached in the background and stream into a log file, so a
    25-minute bazel build never blocks or times out an MCP call. The caller
    starts a job, then polls it.
  * Commands run under `zsh -lc` so ~/.zshrc is sourced and build secrets such
    as TELEGRAM_CODESIGNING_GIT_PASSWORD are present.

SECURITY: any client that can reach this server can run arbitrary commands as
this user. Only register it in a Claude desktop app you control.
"""

import json
import os
import signal
import subprocess
import sys
import time
import uuid

SERVER_NAME = "sg-build"
SERVER_VERSION = "1.0.0"
DEFAULT_PROTOCOL_VERSION = "2025-06-18"

LOG_DIR = os.path.expanduser("~/.sg-build-mcp/logs")
DEFAULT_CWD = os.path.expanduser("~/Swiftgram")
MAX_WAIT_SECONDS = 45  # the desktop app's MCP proxy times a call out at 60s

JOBS = {}


def log_path(job_id):
    return os.path.join(LOG_DIR, job_id + ".log")


def start_job(command, cwd=None):
    os.makedirs(LOG_DIR, exist_ok=True)
    job_id = time.strftime("%H%M%S") + "-" + uuid.uuid4().hex[:6]
    work_dir = os.path.expanduser(cwd) if cwd else DEFAULT_CWD
    if not os.path.isdir(work_dir):
        raise ValueError("cwd does not exist: %s" % work_dir)

    handle = open(log_path(job_id), "wb")
    handle.write(("$ %s\n(cwd: %s)\n\n" % (command, work_dir)).encode("utf-8"))
    handle.flush()

    process = subprocess.Popen(
        ["/bin/zsh", "-lc", command],
        cwd=work_dir,
        stdout=handle,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )
    JOBS[job_id] = {
        "process": process,
        "command": command,
        "cwd": work_dir,
        "started_at": time.time(),
        "handle": handle,
    }
    return job_id


def read_tail(job_id, tail_lines):
    path = log_path(job_id)
    if not os.path.exists(path):
        return ""
    with open(path, "rb") as handle:
        data = handle.read()
    text = data.decode("utf-8", errors="replace")
    lines = text.splitlines()
    if tail_lines > 0 and len(lines) > tail_lines:
        omitted = len(lines) - tail_lines
        lines = ["... (%d earlier lines omitted; raise tail_lines to see more)" % omitted] + lines[-tail_lines:]
    return "\n".join(lines)


def job_status(job_id, tail_lines=80):
    job = JOBS.get(job_id)
    if job is None:
        raise ValueError("unknown job_id: %s (it may predate a server restart)" % job_id)
    code = job["process"].poll()
    elapsed = int(time.time() - job["started_at"])
    if code is None:
        header = "job %s: RUNNING (%ds elapsed)" % (job_id, elapsed)
    else:
        header = "job %s: EXITED code=%d after %ds" % (job_id, code, elapsed)
    header += "\ncommand: %s\ncwd: %s\nlog: %s\n" % (job["command"], job["cwd"], log_path(job_id))
    return header + "\n" + read_tail(job_id, tail_lines)


TOOLS = [
    {
        "name": "sg_run",
        "description": (
            "Start a shell command on this Mac in the background and return a job_id. "
            "Runs under `zsh -lc` from ~/Swiftgram unless cwd says otherwise, so login shell "
            "environment (build secrets, PATH, Xcode toolchain) is available. Use this for "
            "bazel/Make.py builds, xcodebuild, simctl, devicectl, git. Poll with sg_status."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "Shell command to run."},
                "cwd": {"type": "string", "description": "Working directory. Defaults to ~/Swiftgram."},
            },
            "required": ["command"],
        },
    },
    {
        "name": "sg_status",
        "description": "Report whether a job is still running plus the tail of its output.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "job_id": {"type": "string"},
                "tail_lines": {"type": "integer", "description": "Output lines to return, newest last. Default 80, 0 for all."},
            },
            "required": ["job_id"],
        },
    },
    {
        "name": "sg_wait",
        "description": (
            "Block until a job exits or the timeout elapses (max 45s), then report status. "
            "Cheaper than repeated polling for medium-length steps."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "job_id": {"type": "string"},
                "timeout_seconds": {"type": "integer", "description": "Default 45, capped at 45."},
                "tail_lines": {"type": "integer", "description": "Default 80."},
            },
            "required": ["job_id"],
        },
    },
    {
        "name": "sg_grep_log",
        "description": "Search a job's full log for a substring and return matching lines with line numbers. Use to pull compiler errors out of a long build log.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "job_id": {"type": "string"},
                "pattern": {"type": "string", "description": "Case-insensitive substring, e.g. 'error:'."},
                "max_matches": {"type": "integer", "description": "Default 50."},
            },
            "required": ["job_id", "pattern"],
        },
    },
    {
        "name": "sg_stop",
        "description": "Terminate a running job and its process group.",
        "inputSchema": {
            "type": "object",
            "properties": {"job_id": {"type": "string"}},
            "required": ["job_id"],
        },
    },
    {
        "name": "sg_jobs",
        "description": "List jobs started in this server session with their state.",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


def call_tool(name, args):
    if name == "sg_run":
        job_id = start_job(args["command"], args.get("cwd"))
        return "started job %s\nlog: %s\nPoll it with sg_status or sg_wait." % (job_id, log_path(job_id))

    if name == "sg_status":
        return job_status(args["job_id"], int(args.get("tail_lines", 80)))

    if name == "sg_wait":
        job_id = args["job_id"]
        job = JOBS.get(job_id)
        if job is None:
            raise ValueError("unknown job_id: %s" % job_id)
        timeout = min(int(args.get("timeout_seconds", MAX_WAIT_SECONDS)), MAX_WAIT_SECONDS)
        deadline = time.time() + timeout
        while time.time() < deadline and job["process"].poll() is None:
            time.sleep(1.0)
        return job_status(job_id, int(args.get("tail_lines", 80)))

    if name == "sg_grep_log":
        job_id = args["job_id"]
        if job_id not in JOBS:
            raise ValueError("unknown job_id: %s" % job_id)
        pattern = args["pattern"].lower()
        limit = int(args.get("max_matches", 50))
        matches = []
        with open(log_path(job_id), "rb") as handle:
            for number, raw in enumerate(handle.read().decode("utf-8", errors="replace").splitlines(), 1):
                if pattern in raw.lower():
                    matches.append("%6d: %s" % (number, raw))
                    if len(matches) >= limit:
                        matches.append("... (truncated at %d matches)" % limit)
                        break
        if not matches:
            return "no lines matching %r in job %s" % (args["pattern"], job_id)
        return "\n".join(matches)

    if name == "sg_stop":
        job_id = args["job_id"]
        job = JOBS.get(job_id)
        if job is None:
            raise ValueError("unknown job_id: %s" % job_id)
        if job["process"].poll() is None:
            try:
                os.killpg(os.getpgid(job["process"].pid), signal.SIGTERM)
            except OSError:
                job["process"].terminate()
            return "sent SIGTERM to job %s" % job_id
        return "job %s already exited (code=%d)" % (job_id, job["process"].poll())

    if name == "sg_jobs":
        if not JOBS:
            return "no jobs in this server session"
        rows = []
        for job_id, job in JOBS.items():
            code = job["process"].poll()
            state = "running" if code is None else "exit=%d" % code
            rows.append("%s  %-10s  %s" % (job_id, state, job["command"][:100]))
        return "\n".join(rows)

    raise ValueError("unknown tool: %s" % name)


def respond(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except ValueError:
            continue

        method = request.get("method")
        request_id = request.get("id")

        # Notifications carry no id and expect no response.
        if request_id is None:
            continue

        try:
            if method == "initialize":
                requested = (request.get("params") or {}).get("protocolVersion")
                result = {
                    "protocolVersion": requested or DEFAULT_PROTOCOL_VERSION,
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                }
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": TOOLS}
            elif method == "tools/call":
                params = request.get("params") or {}
                text = call_tool(params.get("name"), params.get("arguments") or {})
                result = {"content": [{"type": "text", "text": text}]}
            else:
                respond({
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": -32601, "message": "method not found: %s" % method},
                })
                continue
        except Exception as error:  # surface failures as tool errors, keep serving
            if method == "tools/call":
                respond({
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {"content": [{"type": "text", "text": "error: %s" % error}], "isError": True},
                })
            else:
                respond({
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": -32603, "message": str(error)},
                })
            continue

        respond({"jsonrpc": "2.0", "id": request_id, "result": result})


if __name__ == "__main__":
    main()
