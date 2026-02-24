#!/bin/bash
LOG=/tmp/zig-mcp-debug-full.log

(
  echo "=== Wrapper invoked at $(date) ==="
  echo "Args: $@"
  echo "PID: $$"
  echo "==="
) >> "$LOG" 2>&1

# Capture stdin to both a file and pipe it to the binary
tee -a "$LOG" | /home/lbw/Documents/Github/zig-mcp/zig-out/bin/zig-mcp "$@"
