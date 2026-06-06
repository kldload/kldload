#!/usr/bin/env bash
# kube-helpers.sh — kubectl shortcuts for kldload Kubernetes nodes
# Sourced automatically via /etc/profile.d/

# Only load if kubectl is available
command -v kubectl >/dev/null 2>&1 || return 0

__require_kubectl() {
    command -v kubectl >/dev/null 2>&1 || {
        echo "kubectl not found" >&2
        return 1
    }
    kubectl cluster-info >/dev/null 2>&1 || {
        echo "no cluster available" >&2
        return 1
    }
}
__require_helm() { command -v helm >/dev/null 2>&1 || {
    echo "helm not found" >&2
    return 1
}; }
_kcur_ns() { kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null; }

# ── Context & namespace ────────────────────────────────────────────────────
kc() {
    __require_kubectl || return
    case "${1:-cur}" in
    cur | current | "")
        echo "context: $(kubectl config current-context 2>/dev/null || echo '<none>')"
        echo "namespace: $(_kcur_ns)"
        ;;
    ls | list) kubectl config get-contexts ;;
    use)
        kubectl config use-context "${2:?usage: kc use <context>}" >/dev/null
        kc cur
        ;;
    *) echo "usage: kc [ls|use <ctx>|cur]" >&2 ;;
    esac
}

kns() {
    __require_kubectl || return
    local arg="${1:-}" cur
    cur="$(_kcur_ns)"
    if [[ -z "$arg" ]]; then
        echo "namespace: ${cur:-default}"
        return
    fi
    [[ "$arg" == "-" && -n "${KNS_PREV:-}" ]] && arg="$KNS_PREV"
    KNS_PREV="$cur"
    kubectl config set-context --current --namespace="$arg" >/dev/null
    echo "namespace: $arg"
}

kn() {
    __require_kubectl || return
    case "${1:-ls}" in
    ls | "") kubectl get ns ;;
    cur) kns ;;
    use) kns "${2:?usage: kn use <ns>}" ;;
    new) kubectl create ns "${2:?usage: kn new <ns>}" ;;
    del | delete | rm)
        local ns="${2:?usage: kn delete <ns>}"
        read -r -p "Delete namespace '$ns'? Type name to confirm: " ans
        [[ "$ans" == "$ns" ]] && kubectl delete ns "$ns" || echo "aborted"
        ;;
    *) echo "usage: kn [ls|cur|use|new|del] <ns>" >&2 ;;
    esac
}

# ── Workload views ─────────────────────────────────────────────────────────
kp() {
    __require_kubectl || return
    case "${1:-}" in
    all | -A) kubectl get pods -A -o wide --sort-by=.metadata.namespace ;;
    "") kubectl get pods -o wide --sort-by=.spec.nodeName ;;
    *) kubectl -n "$1" get pods -o wide ;;
    esac
}
kpa() {
    __require_kubectl || return
    kubectl get pods -A -o wide --sort-by=.metadata.namespace
}
ksvc() {
    __require_kubectl || return
    case "${1:-}" in
    all | -A) kubectl get svc -A -o wide ;;
    "") kubectl get svc -o wide ;;
    *) kubectl -n "$1" get svc -o wide ;;
    esac
}
ks() { ksvc "$@"; }

king() {
    __require_kubectl || return
    case "${1:-}" in
    all | -A) kubectl get ing -A -o wide 2>/dev/null || kubectl get ingress -A -o wide ;;
    "") kubectl get ing -o wide 2>/dev/null || kubectl get ingress -o wide ;;
    *) kubectl -n "$1" get ing -o wide 2>/dev/null || kubectl -n "$1" get ingress -o wide ;;
    esac
}

kep() {
    __require_kubectl || return
    case "${1:-}" in
    all | -A) kubectl get endpoints -A ;;
    "") kubectl get endpoints ;;
    *) kubectl -n "$1" get endpoints ;;
    esac
}

kdep() {
    __require_kubectl || return
    kubectl get deploy -o wide
}
kno() {
    __require_kubectl || return
    kubectl get nodes -o wide
}
kall() {
    __require_kubectl || return
    kubectl get all -o wide
}

# ── Describe & logs ────────────────────────────────────────────────────────
kshow() {
    __require_kubectl || return
    local resource="${1:?usage: kshow <resource> [name]}"
    local name="${2:-}"
    if [[ -n "$name" ]]; then
        kubectl describe "$resource" "$name"
    else
        kubectl describe "$resource"
    fi
}

klog() {
    __require_kubectl || return
    local pod="${1:?usage: klog <pod> [-f] [-c container]}"
    shift
    kubectl logs "$pod" "$@"
}

klogf() {
    __require_kubectl || return
    local pod="${1:?usage: klogf <pod> [-c container]}"
    shift
    kubectl logs -f "$pod" "$@"
}

# ── Exec into pod ──────────────────────────────────────────────────────────
kexec() {
    __require_kubectl || return
    local pod="${1:?usage: kexec <pod> [command]}"
    shift
    kubectl exec -it "$pod" -- "${@:-/bin/sh}"
}

# ── Health ─────────────────────────────────────────────────────────────────
khealth() {
    __require_kubectl || return
    echo "=== Nodes ==="
    kubectl get nodes -o wide
    echo ""
    echo "=== System Pods ==="
    kubectl get pods -n kube-system -o wide
    echo ""
    echo "=== Cilium ==="
    cilium status --brief 2>/dev/null || echo "cilium CLI not available"
    echo ""
    echo "=== Unhealthy Pods ==="
    kubectl get pods -A --field-selector 'status.phase!=Running,status.phase!=Succeeded' 2>/dev/null || echo "All pods healthy"
}

# ── Helm shortcuts ─────────────────────────────────────────────────────────
hl() {
    __require_helm || return
    helm list -A
}
hs() {
    __require_helm || return
    helm status "${1:?usage: hs <release>}" -n "${2:-$(_kcur_ns)}"
}
hv() {
    __require_helm || return
    helm get values "${1:?usage: hv <release>}" -n "${2:-$(_kcur_ns)}" --all
}
hh() {
    __require_helm || return
    helm history "${1:?usage: hh <release>}" -n "${2:-$(_kcur_ns)}"
}

# ── Quick help ─────────────────────────────────────────────────────────────
khelp() {
    cat <<'EOF'
kldload Kubernetes shortcuts:

  Context & Namespace:
    kc              current context
    kc ls           list contexts
    kc use <ctx>    switch context
    kns <ns>        switch namespace
    kns -           previous namespace
    kn ls           list namespaces
    kn new <ns>     create namespace
    kn del <ns>     delete namespace

  Workloads:
    kp              pods (current ns)
    kp all          pods (all ns)
    ksvc / ks       services
    king            ingresses
    kep             endpoints
    kdep            deployments
    kno             nodes
    kall            all resources

  Inspect:
    kshow <r> [n]   describe resource
    klog <pod>      pod logs
    klogf <pod>     follow pod logs
    kexec <pod>     exec into pod

  Health:
    khealth         full cluster health
    kube-status     comprehensive status

  Helm:
    hl              list all releases
    hs <rel>        release status
    hv <rel>        release values
    hh <rel>        release history

  Network:
    kube-network init <id>     setup WireGuard backplane (mgmt + k8s planes)
    kube-network add-peer      add peer to mesh
    kube-network pin-kubelet   pin kubelet to wg-k8s interface
    kube-network nft           apply K8s firewall rules
    kube-network status        WireGuard plane status

  Cluster:
    kube-setup      install K8s packages
    kube-init       bootstrap control plane + Cilium
    kube-join <ip>  join as worker
    kube-reset      tear down K8s on this node
    kube-status     cluster health dashboard
    kube-cluster    KVM: golden image → clone CP + workers
EOF
}
