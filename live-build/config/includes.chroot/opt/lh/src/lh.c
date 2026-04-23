// lh.c — shared helpers and globals
#include "common.h"

// Default monitored paths — kldload-aware. Ships with:
//  /var/log                    system + distro logs
//  /var/log/kldload            autodeploy, firstboot, webui, klab-firstboot
//  /var/log/klab               klab golden build logs per VM
//  /var/log/libvirt            libvirtd + qemu-kvm + per-domain logs
//  /var/log/audit              auditd
//  /mnt/cluster-logs           SSHFS mountpoint populated by kldload-lh
//                              when cluster-wide log stitching is enabled
// Users can override at runtime with (S)et Log Paths.
char log_search_path[BUFFER_SIZE] = "/var/log /var/log/kldload /var/log/klab /var/log/libvirt /var/log/audit /mnt/cluster-logs";

char *get_user_input(const char *prompt) {
    char *input = readline(prompt);
    if (input && *input) add_history(input);
    return input;
}

int sanitize_input(char *input) {
    if (!input || !*input) return 0;
    if (strlen(input) >= BUFFER_SIZE) {
        printf(ANSI_COLOR_RED "Input too long. Please try again.\n" ANSI_COLOR_RESET);
        return 0;
    }
    return 1;
}
