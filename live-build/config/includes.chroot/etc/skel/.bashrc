# kldload .bashrc — live session + installed nodes (server, master, worker, kvm)
# Merged: kldload fleet tools + k8s/calico/helm helpers

[[ -n "${BASH_VERSION:-}" ]] || return
case $- in *i*) ;; *) return ;; esac

# ── Helper (must be before all tool checks) ───────────────────────────────
__have() { command -v "$1" >/dev/null 2>&1; }

# ── tmux (available but not forced — type 'tmux' or 'ta' to start) ────────
# To auto-attach on login, uncomment the next line:
# command -v tmux >/dev/null 2>&1 && [[ -z "${TMUX:-}" ]] && tmux new-session -A -s kldload

# ── Login banner — fastfetch (once per session) ──────────────────────────────
if __have fastfetch && [[ -z "${_KLDLOAD_BANNER_SHOWN:-}" ]]; then
  export _KLDLOAD_BANNER_SHOWN=1
  fastfetch 2>/dev/null
fi

# ── History ───────────────────────────────────────────────────────────────────
HISTSIZE=100000
HISTFILESIZE=200000
HISTTIMEFORMAT='%F %T '
HISTCONTROL=ignoredups:erasedups
shopt -s histappend checkwinsize
shopt -s cdspell 2>/dev/null || true

# ── Completion ────────────────────────────────────────────────────────────────
[[ -f /etc/bash_completion ]] && . /etc/bash_completion

# ── fzf — fuzzy finder (Ctrl-R history, Ctrl-T files, Alt-C cd) ──────────────
if __have fzf; then
  eval "$(fzf --bash 2>/dev/null)" || {
    [[ -f /usr/share/doc/fzf/examples/key-bindings.bash ]] && . /usr/share/doc/fzf/examples/key-bindings.bash
    [[ -f /usr/share/bash-completion/completions/fzf ]] && . /usr/share/bash-completion/completions/fzf
  }
  export FZF_DEFAULT_OPTS="--height 40% --layout=reverse --border --color=bg+:#1e2533,fg+:#34d399,hl:#60a5fa,hl+:#60a5fa,info:#64748b,prompt:#34d399,pointer:#34d399,marker:#34d399"
  # Use fd/fdfind if available (faster than find)
  if __have fdfind; then
    export FZF_DEFAULT_COMMAND='fdfind --type f --hidden --follow --exclude .git'
    export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
    export FZF_ALT_C_COMMAND='fdfind --type d --hidden --follow --exclude .git'
  elif __have fd; then
    export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
    export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
    export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
  fi
fi

# ── zoxide — smart cd (use 'z' instead of 'cd') ─────────────────────────────
if __have zoxide; then
  eval "$(zoxide init bash)"
fi

# ── PATH ──────────────────────────────────────────────────────────────────────
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/local/sbin:$PATH"
[[ -d "$HOME/go/bin" ]] && export PATH="$PATH:$HOME/go/bin"

# ── Prompt ────────────────────────────────────────────────────────────────────
__ps1_k8s_ns() {
  local ctx ns
  ctx="$(kubectl config current-context 2>/dev/null)" || return
  ns="$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null)"
  printf '%s/%s' "${ctx}" "${ns:-default}"
}

if command -v kubectl >/dev/null 2>&1; then
  PS1='\[\e[96m\][$(__ps1_k8s_ns)]\[\e[0m\] \[\e[1;34m\]\w\[\e[0m\] \[\e[95m\]\u@\h\[\e[0m\]\$ '
else
  PS1='\[\e[1;36m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
fi

# ── Internal helpers (must be before tool sections) ─────────────────────────
__have()           { command -v "$1" >/dev/null 2>&1; }

# ── Bracketed paste ───────────────────────────────────────────────────────────
bpoff() { bind 'set enable-bracketed-paste off' 2>/dev/null || true; }
bpon()  { bind 'set enable-bracketed-paste on'  2>/dev/null || true; }

# ── Modern tool upgrades (graceful fallback to originals) ────────────────────
if __have eza; then
  alias ls='eza --color=auto --group-directories-first'
  alias ll='eza -alF --git --group-directories-first'
  alias la='eza -a --group-directories-first'
  alias l='eza -F --group-directories-first'
  alias tree='eza --tree'
else
  alias ls='ls --color=auto'
  alias ll='ls -alFh --color=auto'
  alias la='ls -A --color=auto'
  alias l='ls -CF --color=auto'
fi
if __have bat; then
  alias cat='bat --paging=never --style=plain'
  alias catp='bat'
  export MANPAGER="sh -c 'col -bx | bat -l man -p'"
elif __have batcat; then
  # Debian names it batcat to avoid conflict with bacula
  alias bat='batcat'
  alias cat='batcat --paging=never --style=plain'
  alias catp='batcat'
  export MANPAGER="sh -c 'col -bx | batcat -l man -p'"
fi
if __have fd; then
  alias find='fd'
elif __have fdfind; then
  # Debian names it fdfind
  alias fd='fdfind'
fi
__have rg && alias grep='rg' || alias grep='grep --color=auto'

# ── Core aliases ──────────────────────────────────────────────────────────────
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'
alias df='df -h'
alias du='du -h'
alias ports='ss -tuln'
alias ..='cd ..'
alias ...='cd ../..'
alias e='${EDITOR:-vim}'
alias vi='vim'

# ── tmux ──────────────────────────────────────────────────────────────────────
alias tk='tmux kill-server'
alias tls='tmux ls'
alias ta='tmux attach -t'
alias tn='tmux new-session -s'

# ── Internal helpers ──────────────────────────────────────────────────────────
__require_kubectl(){ __have kubectl || { echo "kubectl not found" >&2; return 127; }; }
__require_helm()   { __have helm   || { echo "helm not found"    >&2; return 127; }; }
__fn_exists()      { declare -F "$1" >/dev/null 2>&1; }
_kcur_ns()         { kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null | sed 's/^$/default/'; }

# ── kubectl + kubeconfig ──────────────────────────────────────────────────────
if __have kubectl; then
  export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
  alias k='kubectl'
  alias kga='kubectl get all -A'
  alias kgn='kubectl get nodes -o wide'
  alias kgp='kubectl get pods -A -o wide'
  alias kgs='kubectl get svc -A -o wide'
  alias kgi='kubectl get ingress -A'
  alias kd='kubectl describe'
  alias kl='kubectl logs'
  alias klf='kubectl logs -f'
  alias kex='kubectl exec -it'
  alias kaf='kubectl apply -f'
  alias kdf='kubectl delete -f'
  source <(kubectl completion bash 2>/dev/null) || true
  complete -F __start_kubectl k 2>/dev/null || true
fi

# ── Namespace switcher ────────────────────────────────────────────────────────
kns() {
  __require_kubectl || return
  local arg="${1:-}" ctx cur
  ctx="$(kubectl config current-context 2>/dev/null)"
  cur="$(_kcur_ns)"
  if [[ -z "$arg" ]]; then
    echo "context:   ${ctx:-<none>}"; echo "namespace: ${cur:-default}"; return
  fi
  if [[ "$arg" == "-" ]]; then
    [[ -n "${KNS_PREV:-}" ]] || { echo "no previous namespace" >&2; return 1; }
    arg="$KNS_PREV"
  fi
  KNS_PREV="$cur"
  kubectl config set-context --current --namespace="$arg" >/dev/null
  echo "namespace: $arg"
}

kn() {
  __require_kubectl || return
  local sub="${1:-ls}"
  case "$sub" in
    ls|"") kubectl get ns ;;
    cur)   kns ;;
    use)   kns "${2:?usage: kn use <ns>}" ;;
    new)   kubectl create ns "${2:?usage: kn new <ns>}" ;;
    delete|del|rm)
      local ns="${2:?usage: kn delete <ns>}"
      echo "CONFIRM: delete namespace: $ns"
      read -r -p "Type '$ns' to continue: " ans
      [[ "$ans" == "$ns" ]] || { echo "aborted"; return 1; }
      kubectl delete ns "$ns" ;;
    edit)  kubectl edit ns "${2:?usage: kn edit <ns>}" ;;
    *)     echo "usage: kn [ls|cur|use <ns>|new <ns>|delete <ns>|edit <ns>]" >&2; return 1 ;;
  esac
}

kne() {
  __require_kubectl || return
  local ns="${1:-}"; shift || true
  [[ -n "$ns" ]] || { echo "usage: kne <ns> <kubectl args...>" >&2; return 1; }
  kubectl -n "$ns" "$@"
}

# ── Workload views ────────────────────────────────────────────────────────────
kp()   { __require_kubectl || return; kubectl get pods -o wide --sort-by=.spec.nodeName; }
kpa()  { __require_kubectl || return; kubectl get pods -A -o wide --sort-by=.metadata.namespace; }
ksvc() { __require_kubectl || return; kubectl get svc -o wide; }
kdep() { __require_kubectl || return; kubectl get deploy -o wide; }
kall() { __require_kubectl || return; kubectl get all -o wide; }

kshow() {
  __require_kubectl || return
  local ns="${1:-$(_kcur_ns)}"
  echo "== ns: $ns =="; echo
  echo "── workloads ──"; kubectl -n "$ns" get deploy,sts,ds,job,cronjob,pods -o wide 2>/dev/null || true; echo
  echo "── services/ingress ──"; kubectl -n "$ns" get svc,ing,ep -o wide 2>/dev/null || true; echo
  echo "── config ──"; kubectl -n "$ns" get cm,secret,sa 2>/dev/null || true; echo
  echo "── rbac ──"; kubectl -n "$ns" get role,rolebinding 2>/dev/null || true; echo
  echo "── storage ──"; kubectl -n "$ns" get pvc 2>/dev/null || true; echo
  echo "── events (last 25) ──"; kubectl -n "$ns" get events --sort-by=.lastTimestamp 2>/dev/null | tail -25 || true; echo
}

ksh() {
  __require_kubectl || return
  local ns="${1:-}" target="${2:-}" shell="${3:-/bin/bash}"
  [[ -n "$ns" && -n "$target" ]] || { echo "usage: ksh <ns> <pod|app=label> [shell]" >&2; return 1; }
  local pod
  if [[ "$target" == *"="* ]]; then
    pod="$(kubectl -n "$ns" get pod -l "$target" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  else
    pod="$target"
  fi
  [[ -n "$pod" ]] || { echo "pod not found: $target" >&2; return 1; }
  kubectl -n "$ns" exec -it "$pod" -- "$shell" 2>/dev/null || kubectl -n "$ns" exec -it "$pod" -- /bin/sh
}

cmd() {
  __require_kubectl || return
  local ns="${1:-}" target="${2:-}"
  [[ -n "$ns" && -n "$target" ]] || { echo "usage: cmd <ns> <pod|app=label>" >&2; return 1; }
  local pod node debugpod
  if [[ "$target" == *"="* ]]; then
    pod="$(kubectl -n "$ns" get pod -l "$target" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  else
    pod="$target"
  fi
  [[ -n "$pod" ]] || { echo "pod not found: $target" >&2; return 1; }
  node="$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
  [[ -n "$node" ]] || { echo "could not determine node" >&2; return 1; }
  debugpod="dbg-$(echo "$pod" | tr '.' '-' | cut -c1-28)-$RANDOM"
  kubectl -n "$ns" run "$debugpod" \
    --image=nicolaka/netshoot:latest --restart=Never --rm -it \
    --overrides='{"apiVersion":"v1","spec":{"nodeName":"'"$node"'","tolerations":[{"operator":"Exists"}],"containers":[{"name":"netshoot","image":"nicolaka/netshoot:latest","stdin":true,"tty":true,"command":["bash"]}]}}' \
    --command -- bash
}

# ── Calico / NetworkPolicy ────────────────────────────────────────────────────
kpol() {
  __require_kubectl || return; local ns="${1:-$(_kcur_ns)}"
  echo "== Kubernetes NetworkPolicy (ns=$ns) =="; kubectl -n "$ns" get netpol 2>/dev/null || true; echo
  echo "== Calico NetworkPolicy (ns=$ns) =="; kubectl -n "$ns" get networkpolicies.crd.projectcalico.org 2>/dev/null || true; echo
  echo "== Calico GlobalNetworkPolicy =="; kubectl get globalnetworkpolicies.crd.projectcalico.org 2>/dev/null || true
}
calget()  { __require_kubectl || return; kubectl -n "${1:?ns}" get networkpolicies.crd.projectcalico.org "${2:?name}" -o yaml; }
gnpget()  { __require_kubectl || return; kubectl get globalnetworkpolicies.crd.projectcalico.org "${1:?name}" -o yaml; }
poledit() { __require_kubectl || return; kubectl -n "${1:?ns}" edit networkpolicies.crd.projectcalico.org "${2:?name}"; }
gnpedit() { __require_kubectl || return; kubectl edit globalnetworkpolicies.crd.projectcalico.org "${1:?name}"; }

kcal() {
  __require_kubectl || return
  echo "== calico-system =="; kubectl -n calico-system get pods -o wide 2>/dev/null || true; echo
  echo "== tigera-operator =="; kubectl -n tigera-operator get pods -o wide 2>/dev/null || true; echo
  echo "== tigerastatus =="; kubectl get tigerastatus 2>/dev/null || true
}

khealth() {
  __require_kubectl || return
  echo "== nodes =="; kubectl get nodes -o wide 2>/dev/null || true; echo
  echo "== kube-system (bad states) =="; kubectl -n kube-system get pods 2>/dev/null | grep -vE 'Running|Completed' || echo "OK"; echo
  echo "== calico-system (bad states) =="; kubectl -n calico-system get pods 2>/dev/null | grep -vE 'Running|Completed' || echo "OK"; echo
  echo "== recent warnings =="; kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | grep -iE 'warning|failed|error|backoff|unhealthy' | tail -30 || echo "OK"
}

kdiag() {
  __require_kubectl || return
  local ns="${1:?usage: kdiag <ns>}"
  echo "== pods =="; kubectl -n "$ns" get pods -o wide 2>/dev/null || true; echo
  echo "== svc/ing/ep =="; kubectl -n "$ns" get svc,ing,ep -o wide 2>/dev/null || true; echo
  echo "== config+rbac =="; kubectl -n "$ns" get cm,secret,sa,role,rolebinding 2>/dev/null || true; echo
  echo "== events =="; kubectl -n "$ns" get events --sort-by=.lastTimestamp 2>/dev/null | tail -30 || true
}

kfixns() {
  __require_kubectl || return
  local ns="${1:?usage: kfixns <ns>}"
  kubectl get ns "$ns" -o json \
    | sed 's/"finalizers":[[][^]]*[]]/"finalizers":[]/g' \
    | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - \
    && echo "OK: finalizers removed" || echo "WARN: finalize failed"
}

# ── Helm ──────────────────────────────────────────────────────────────────────
if __have helm; then
  alias h='helm'
  alias hls='helm list -A'
  alias hup='helm upgrade --install'
  source <(helm completion bash 2>/dev/null) || true
fi

hl()  { __require_helm || return; [[ -n "${1:-}" ]] && helm list -n "$1" || helm list -A; }
hs()  { __require_helm || return; helm status "${1:?rel}" -n "${2:-default}"; }
hm()  { __require_helm || return; helm get manifest "${1:?rel}" -n "${2:-default}"; }
hv()  { __require_helm || return; helm get values "${1:?rel}" -n "${2:-default}" --all; }
hh()  { __require_helm || return; helm history "${1:?rel}" -n "${2:-default}"; }
hown() {
  __require_kubectl || return; __require_helm || return
  local rel="${1:?rel}" ns="${2:-}"
  if [[ -n "$ns" ]]; then
    kubectl -n "$ns" get all,cm,secret,sa,role,rolebinding,netpol,ing,ep -o wide -l "app.kubernetes.io/instance=$rel" 2>/dev/null || true
  else
    kubectl get all,cm,secret,sa -A -o wide -l "app.kubernetes.io/instance=$rel" 2>/dev/null || true
  fi
}

# ── Salt — fleet management ───────────────────────────────────────────────────
if __have salt; then
  slist() {
    salt --static --no-color --out=json --out-indent=-1 "*" \
      grains.item host os osrelease ipv4 num_cpus mem_total roles \
    | jq -r '
        to_entries[]
        | .key as $id | .value as $v
        | ($v.ipv4 // [] | map(select(. != "127.0.0.1" and . != "0.0.0.0")) | join("  ")) as $ips
        | [$id, $v.host, ($v.os + " " + $v.osrelease), $ips, $v.num_cpus, $v.mem_total, ($v.roles // "")]
        | @tsv' \
    | column -t -s $'\t' \
    | awk 'BEGIN{printf "%-30s %-20s %-18s %-32s %-5s %-8s %s\n",
        "MINION","HOST","OS","IPs","CPUs","RAM","ROLES"
        print "------------------------------","--------------------","------------------",
              "--------------------------------","-----","--------","------"} {print}'
  }

  alias sping='salt "*" test.ping'
  alias ssall='salt "*" cmd.run "ss -tnlp"'
  alias sdfall='salt "*" cmd.run "df -hT --exclude-type=tmpfs --exclude-type=devtmpfs"'
  alias shighstate='salt "*" state.highstate'
  alias sgrain='salt "*" grains.items'
  alias saccept='salt-key -A'
  alias skeys='salt-key -L'
  alias skservices='salt "*" service.status kubelet containerd'

  # K8s via Salt (runs on control-plane nodes)
  alias sknodes='salt -G "role:etcd" cmd.run "kubectl get nodes -o wide"'
  alias skpods='salt -G "role:etcd" cmd.run "kubectl get pods -A -o wide"'
  alias sksvc='salt -G "role:etcd" cmd.run "kubectl get svc -A -o wide"'

  skpodsmap() {
    salt -G "role:etcd" cmd.run \
      'kubectl get pods -A -o json | jq -r ".items[] | [.metadata.namespace,.metadata.name,.status.podIP,.spec.nodeName] | @tsv"' \
    | column -t
  }
fi

# ── Docker / Podman ───────────────────────────────────────────────────────────
if __have docker; then
  alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
  alias dcu='docker compose up -d'
  alias dcd='docker compose down'
  alias dlogs='docker logs -f'
  dssh() { docker exec -it "${1:?container}" /bin/bash 2>/dev/null || docker exec -it "${1:?container}" /bin/sh; }
fi

if __have podman; then
  alias pps='podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
fi

# ── virsh / KVM ───────────────────────────────────────────────────────────────
if __have virsh; then
  alias vls='virsh list --all'
  alias vstart='virsh start'
  alias vstop='virsh shutdown'
  alias vkill='virsh destroy'
  alias vconsole='virsh console'
fi

# ── ZFS / kldload ────────────────────────────────────────────────────────────────
alias zls='zfs list'
alias zbe='kldload-be list'
alias zsnap='zfs list -t snapshot'
alias deploy='kldload-deploy-tui'
__have kldload-spawn && alias spawn='kldload-spawn'

# ── Help ──────────────────────────────────────────────────────────────────────
khelp() {
cat <<'EOF'
NAMESPACE
  kn / kn cur / kn use <ns> / kn new <ns> / kn delete <ns>
  kns [<ns>|-]           switch ns, show current, or go back (-)

WORKLOADS
  kp / kpa / ksvc / kdep / kall / kshow [ns]
  kne <ns> <kubectl args...>

EXEC / DEBUG
  ksh <ns> <pod|app=label>        exec shell in pod
  cmd <ns> <pod|app=label>        netshoot debug pod on same node

POLICY (Calico + k8s)
  kpol [ns]   calget/gnpget/poledit/gnpedit

HEALTH
  kcal / khealth / kdiag <ns> / kfixns <ns>

HELM
  h / hls / hup / hl [ns] / hs/hm/hv/hh <rel> [ns] / hown <rel> [ns]

SALT (if master)
  slist / sping / saccept / skeys / shighstate
  sknodes / skpods / sksvc / skpodsmap

ZFS / kldload
  zls / zbe / zsnap / deploy / spawn
EOF
}

if command -v kldload-help >/dev/null 2>&1; then
  alias khelp='kldload-help'
fi
