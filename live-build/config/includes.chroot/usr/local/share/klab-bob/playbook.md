# kldload Demo & Workflow Reference — Bob's Playbook
# Bob uses this to walk users through demos and manage infrastructure

## kvm-demo (KVM Hypervisor Demo)
    1)
      header
      clean_vms
    2)
      header
      echo -e "${Y}=== VM Inventory ===${N}"
    3)
      header
      echo -e "${Y}=== Snapshot All VMs ===${N}"
    4)
      header
      echo -e "${Y}=== Rollback ===${N}"
    5)
      header
      clean_vms
    6)
      if [[ "$HAS_NVIDIA" != "1" ]]; then echo -e "${R}NVIDIA not available${N}"; pause; continue; fi
      header
    7)
      if [[ "$HAS_NVIDIA" != "1" || "$HAS_PODMAN" != "1" ]]; then echo -e "${R}Requires NVIDIA + Podman${N}"; pause; continue; fi
      header
    8)
      if [[ "$HAS_NVIDIA" != "1" || "$HAS_PODMAN" != "1" ]]; then echo -e "${R}Requires NVIDIA + Podman${N}"; pause; continue; fi
      header
    9)
      header
      echo -e "${Y}=== GPU Sharing — All Processes ===${N}"
    10)
      header
      clean_gpu

## kube-demo (Kubernetes Demo)
  ) &
  local deploy_pid=$!

  ) &
  local traffic_pid=$!

    1)  demo_overview ;;
    2)  demo_zfs_clones ;;
    3)  demo_add_nodes ;;
    4)  demo_cilium ;;
    5)  demo_connectivity ;;
    6)  demo_hubble ;;
    7)  demo_coredns ;;
    8)  demo_netpol ;;
    9)  demo_metallb ;;
    10) demo_gateway ;;
    11) demo_zfs_pvc ;;
    12) demo_snapshot_restore ;;
    13) demo_db_pvc ;;
    14) demo_nginx ;;
    15) demo_pod_dns ;;
    16) demo_scale ;;
    17) demo_rolling_update ;;
    18) demo_self_heal ;;
    19) demo_drain ;;
    20) demo_node_rollback ;;
    21) demo_replace_nodes ;;
    22) demo_ebpf_deep_dive ;;
    23) demo_zero_sidecar ;;
    24) demo_datapath_trace ;;
    99) demo_smoke ;;
    0)  demo_cleanup ;;
    00) demo_destroy_all ;;
    q)  echo ""; exit 0 ;;
    *)  echo -e "${R}Invalid option${N}"; sleep 1 ;;

## klab interactive menu
      1)  menu_header; menu_pick_distro && { cmd_golden "$PICKED_DISTRO"; pause; } ;;
      2)  menu_header; cmd_golden all; pause ;;
      3)  menu_header; cmd_status; pause ;;
      6)  menu_header; cmd_promote green; pause ;;
      7)  menu_header; cmd_rollback; pause ;;
      8)  menu_header; cmd_test --quick; pause ;;
      9)  menu_header; cmd_test --full; pause ;;
      10) menu_header; cmd_kubernetes; pause ;;
          echo -ne "  ${W}Path to playbook: ${N}"; local pb; read -r pb
          [[ -n "$pb" ]] && cmd_run_playbook "$pb"
      12) menu_header; cmd_results ""; pause ;;
      13) menu_header; cmd_verify all; pause ;;
          menu_pick_distro && {
            local _glog="${RESULTS_DIR}/goldens/${PICKED_DISTRO}-latest.log"
      15) menu_header; tail -50 "$MASTER_LOG" 2>/dev/null || echo "  No log yet"; pause ;;
      0)  menu_header; cmd_destroy all; pause ;;
      00) menu_header; cmd_destroy goldens; pause ;;
      *)  echo -e "${R}  Invalid${N}"; sleep 1 ;;

## Bob's Execution Capabilities
Bob can execute commands on the kldload host and klab VMs via the web UI WebSocket API.

### Commands Bob can trigger via WebSocket:
- klab_status — get full lab status
- klab_golden {distro} — build golden image
- klab_deploy {site: blue|green} — deploy site
- klab_promote — promote green to blue
- klab_rollback — rollback blue
- klab_test {mode: quick|full, distro} — run ZFS tests
- klab_destroy {target} — tear down resources
- klab_vm_op {vm, op: start|shutdown|destroy|reboot} — manage VMs
- klab_isolate {vm, ip, isolate: true|false} — network isolation
- klab_fault {vm, ip, fault: network_down|packet_loss|kill_vm|clear} — chaos
- klab_ebpf_trace {tool, target, duration, arg} — eBPF tracing
- klab_run_playbook {distros[], script, site} — run on multiple distros
- klab_flows — get network flows
- klab_metrics — get Prometheus metrics

### SSH to any VM:
ssh root@192.168.122.10X  (blue, X=distro index 1-6)
ssh root@192.168.122.20X  (green, X=distro index 1-6)
Password: kldload
Distro order: 1=centos, 2=rocky, 3=fedora, 4=debian, 5=ubuntu, 6=rhel

### kubectl (when K8s deployed):
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl get nodes
kubectl get pods -A
hubble observe (when Cilium running)
