#!/usr/bin/env bash
# Apply the OpenCode exit-watchdog patch to a Harbor v0.21.0 source checkout.
# Run from the root of the Harbor checkout before installing Harbor.
set -euo pipefail

TARGET=src/harbor/agents/installed/opencode.py

test -f "$TARGET" || {
  echo "ERROR: run this from the root of a Harbor v0.21.0 source checkout." >&2
  exit 1
}

grep -q '^version = "0\.21\.0"$' pyproject.toml || {
  echo "ERROR: this patch supports Harbor v0.21.0 only." >&2
  exit 1
}

if grep -q 'stall_flag = "/logs/agent/.opencode_stalled"' "$TARGET"; then
  echo "OpenCode reliability patch is already applied."
  exit 0
fi

patch_file=$(mktemp)
trap 'rm -f "$patch_file"' EXIT
cat > "$patch_file" <<'PATCH'
diff --git a/src/harbor/agents/installed/opencode.py b/src/harbor/agents/installed/opencode.py
index bd14029..76b942c 100644
--- a/src/harbor/agents/installed/opencode.py
+++ b/src/harbor/agents/installed/opencode.py
@@ -508,15 +508,47 @@ class OpenCode(BaseInstalledAgent):
         cli_flags_arg = (cli_flags + " ") if cli_flags else ""
         resume_flag = "--continue " if self._resume else ""
 
+        log_path = "/logs/agent/opencode.txt"
+        stall_flag = "/logs/agent/.opencode_stalled"
+        opencode_cmd = (
+            f"opencode --model={self.model_name} run --format=json "
+            f"{resume_flag}{cli_flags_arg}--thinking "
+            f"--dangerously-skip-permissions -- {escaped_instruction} "
+            f"> {log_path} 2>&1 </dev/null"
+        )
+        watchdog = (
+            "( IDLE_SEC=60; STALL_SEC=600; last_size=-1; "
+            "last_change=$(date +%s); "
+            "while kill -0 $OC 2>/dev/null; do "
+            f"sz=$(wc -c < {log_path} 2>/dev/null || echo 0); "
+            "now=$(date +%s); "
+            'if [ "$sz" != "$last_size" ]; then '
+            "last_size=$sz; last_change=$now; fi; "
+            "idle=$((now - last_change)); "
+            f"if grep -qE '\"reason\":\"(stop|length)\"' {log_path} "
+            "2>/dev/null && [ $idle -ge $IDLE_SEC ]; then "
+            "kill $OC 2>/dev/null; pkill -P $OC 2>/dev/null; sleep 2; "
+            "kill -9 $OC 2>/dev/null; pkill -9 -P $OC 2>/dev/null; break; "
+            "fi; "
+            f"if [ $idle -ge $STALL_SEC ]; then touch {stall_flag}; "
+            "kill $OC 2>/dev/null; pkill -P $OC 2>/dev/null; sleep 2; "
+            "kill -9 $OC 2>/dev/null; pkill -9 -P $OC 2>/dev/null; break; "
+            "fi; sleep 3; done ) &"
+        )
         await self.exec_as_agent(
             environment,
-            # Note that the --thinking flag just means thinking blocks will be included in the json formatted output
             command=(
-                ". ~/.nvm/nvm.sh; "
-                f"opencode --model={self.model_name} run --format=json "
-                f"{resume_flag}{cli_flags_arg}--thinking "
-                f"--dangerously-skip-permissions -- {escaped_instruction} "
-                f"2>&1 </dev/null | stdbuf -oL tee /logs/agent/opencode.txt"
+                f". ~/.nvm/nvm.sh; rm -f {stall_flag}; "
+                f"{opencode_cmd} & OC=$!; "
+                f"{watchdog} WATCH=$!; "
+                "wait $OC 2>/dev/null; kill $WATCH 2>/dev/null; "
+                f"if [ -f {stall_flag} ]; then "
+                "echo 'opencode stalled: no new output for 600s; terminating as "
+                "unresponsive' >&2; exit 42; fi; "
+                f"if ! grep -q '^{{' {log_path} 2>/dev/null; then "
+                "echo 'opencode produced no json output; it failed to launch "
+                "(see opencode.txt)' >&2; exit 43; fi; "
+                "exit 0"
             ),
             env=env,
         )
PATCH

git apply --check "$patch_file"
git apply "$patch_file"
python3 -m py_compile "$TARGET"
echo "OpenCode reliability patch applied for Harbor v0.21.0."
