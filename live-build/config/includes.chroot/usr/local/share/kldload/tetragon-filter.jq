if .process_exec then
  "EXEC   " + ((.process_exec.process.binary // "?") + " " + (.process_exec.process.arguments // ""))
elif .process_exit then
  "EXIT   pid=" + ((.process_exit.process.pid // 0) | tostring) + " " + (.process_exit.process.binary // "?") +
  (if .process_exit.signal then " sig=" + .process_exit.signal else "" end)
elif .process_kprobe then
  "KPROBE " + (.process_kprobe.function_name // "?") + " " + (.process_kprobe.process.binary // "?") +
  (if .process_kprobe.action then " action=" + .process_kprobe.action else "" end)
else
  (.event_type // "?")
end
