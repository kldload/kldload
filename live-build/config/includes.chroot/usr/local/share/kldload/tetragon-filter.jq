# Tetragon export-stdout → one-line-per-event human-readable filter.
#
# Tetragon ships every kernel event as a JSON document containing many
# fields (process tree, capabilities, namespaces, parent, pod context,
# etc.). Streaming that raw is unreadable. This filter extracts the
# headline — what kind of event, what binary, what args — and drops
# everything else.
#
# The noise filter at the top drops events from chatty kubernetes
# system components that fire constantly on a healthy cluster:
#
#   - FRR vtysh polling (metallb-speaker calls `vtysh -c "show daemons"`
#     repeatedly to populate metrics; one EXEC/EXIT pair every few
#     hundred ms on every worker)
#   - kube-rbac-proxy, liveness/readiness probes — health-check noise
#
# To re-enable noisy events for debugging a specific incident, set
# TETRAGON_NOFILTER=1 in the environment of the kubectl-logs command
# (the filter still runs but the noise gate is skipped).

# ---- helpers --------------------------------------------------------
# Binary path of whichever process subtype is present on this event.
def binary:
    (.process_exec.process.binary // .process_exit.process.binary // .process_kprobe.process.binary // "");

# Noise predicate. True if this event should be dropped.
# jq quirk: `as $var` is a binding operator and binds for the rest of
# the pipeline — it CANNOT live in the condition of an `if` directly,
# the binding has to occur in a pipe BEFORE the `if`. Earlier draft
# used `if EXPR as $p then ... as $bin | ...` which jq parses as
# `if EXPR then (as $p then ...) else ...` and fails on the `then`.
def is_noise:
    binary as $bin
    | ($bin | endswith("/vtysh"))
      or ($bin | endswith("/frr-metrics"))
      or ($bin | endswith("/kube-rbac-proxy"))
      or ($bin | endswith("/livenessProbe"))
      or ($bin | endswith("/readinessProbe"));

# ---- main pipeline --------------------------------------------------
if (env.TETRAGON_NOFILTER // "") == "" and is_noise then
    empty
elif .process_exec then
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
