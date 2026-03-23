// loghog_functions.c
#include "common.h"
#include "loghog_functions.h"

static void safe_system_less(const char *path) {
    char cmd[256 + 64];
    int n = snprintf(cmd, sizeof(cmd), "less -R '%s'", path);
    if (n <= 0 || (size_t)n >= sizeof(cmd)) {
        fprintf(stderr, "less invocation path too long\n");
        return;
    }
    (void)system(cmd); // ignore result; less returns non-zero on 'q'
}

void find_logs_command(char *buffer, size_t size, const char *search_path) {
    // Builds the base find+tail command (no filters)
    // Note: we quote the path to support spaces
    (void)snprintf(
        buffer, size,
        "find '%s' -type f \\( -name '*.log' -o -name 'messages' -o -name 'cron' -o -name 'maillog' -o -name 'secure' -o -name 'firewalld' \\) "
        "-exec tail -f -n +1 {} +",
        search_path
    );
}

void display_buffer_with_less(const char *buffer, size_t length) {
    char tmp_filename[] = "/tmp/logsearchXXXXXX";
    int tmp_fd = mkstemp(tmp_filename);
    if (tmp_fd == -1) { perror("mkstemp"); return; }

    FILE *tmp_file = fdopen(tmp_fd, "w+");
    if (!tmp_file) { perror("fdopen"); close(tmp_fd); return; }

    if (buffer && length) {
        (void)fwrite(buffer, 1, length, tmp_file);
        (void)fflush(tmp_file);
    }
    (void)fclose(tmp_file);

    safe_system_less(tmp_filename);
    (void)unlink(tmp_filename);
}

void run_command_with_buffer(const char *cmd, void (*buffer_action)(const char *, size_t)) {
    FILE *proc = popen(cmd, "r");
    if (!proc) { perror("popen"); return; }

    char *output = NULL;
    size_t total = 0;
    char buf[4096];

    while (fgets(buf, sizeof(buf), proc)) {
        size_t len = strlen(buf);
        char *tmp = realloc(output, total + len + 1);
        if (!tmp) { perror("realloc"); free(output); pclose(proc); return; }
        output = tmp;
        memcpy(output + total, buf, len);
        total += len;
        output[total] = '\0';

        fputs(buf, stdout);
        fflush(stdout);
    }

    if (buffer_action) buffer_action(output, total);
    free(output);
    (void)pclose(proc);
}

static void run_with_filter(const char *log_search_path, const char *grep_expr, int color_always) {
    char find_cmd[BUFFER_SIZE];
    find_logs_command(find_cmd, sizeof(find_cmd), log_search_path);

    char *cmd = NULL;
    const char *color = color_always ? "always" : "never";
    if (grep_expr && *grep_expr) {
        if (asprintf(&cmd, "%s | egrep --color=%s -i \"%s\"", find_cmd, color, grep_expr) < 0 || !cmd) {
            perror("asprintf");
            return;
        }
    } else {
        if (asprintf(&cmd, "%s", find_cmd) < 0 || !cmd) { perror("asprintf"); return; }
    }

    run_command_with_buffer(cmd, display_buffer_with_less);
    free(cmd);
}

void live_auth_log(const char *log_search_path) {
    const char *expr =
        "authentication(\\s*failed)?|permission(\\s*denied)?|invalid\\s*(user|password|token)|"
        "(unauthorized|illegal)\\s*(access|attempt)|SQL\\s*injection|cross-site\\s*(scripting|request\\s*Forgery)|"
        "directory\\s*traversal|(brute-?force|DoS|DDoS)\\s*attack|(vulnerability|exploit)\\s*(detected|scan)";
    run_with_filter(log_search_path, expr, 1);
}

void live_error_log(const char *log_search_path) {
    const char *expr =
        "\\b(?:error|fail(?:ed|ure)?|warn(?:ing)?|critical|socket|denied|refused|retry|reset|timeout|dns|network)";
    run_with_filter(log_search_path, expr, 1);
}

void live_log(const char *log_search_path) {
    run_with_filter(log_search_path, NULL, 1);
}

void live_network_log(const char *log_search_path) {
    const char *expr =
        "https?://|ftps?://|telnet://|ssh://|sftp://|ldap(s)?://|nfs://|tftp://|gopher://|"
        "imap(s)?://|pop3(s)?://|smtp(s)?://|rtsp://|rtmp://|mms://|xmpp://|ipp://|xrdp://";
    run_with_filter(log_search_path, expr, 1);
}

void run_regex(const char *log_search_path) {
    char *pattern = get_user_input("\nRegEX > ");
    if (!sanitize_input(pattern)) { free(pattern); return; }
    run_with_filter(log_search_path, pattern, 1);
    free(pattern);
}

void search_ip(const char *log_search_path) {
    char *pattern = get_user_input("\nIP / RegEX > ");
    if (!sanitize_input(pattern)) { free(pattern); return; }
    run_with_filter(log_search_path, pattern, 1);
    free(pattern);
}

void edit_log_paths(char *path) {
    char *new_paths =
        get_user_input("\nCurrent log paths: /var/lib/docker /var/log\n"
                       "ie: /var/lib/docker/containers /opt /nfsshare etc\n"
                       "Enter new log paths (separated by spaces) > ");
    if (!sanitize_input(new_paths)) { free(new_paths); return; }

    strncpy(path, new_paths, BUFFER_SIZE - 1);
    path[BUFFER_SIZE - 1] = '\0';
    free(new_paths);

    printf(ANSI_COLOR_GREEN "Updated log paths: %s\n" ANSI_COLOR_RESET, path);
}

void export_search_results_to_json(const char *log_search_path) {
    char *pattern = get_user_input("\nRegEX / Text > ");
    if (!sanitize_input(pattern)) { free(pattern); return; }

    char find_cmd[BUFFER_SIZE];
    find_logs_command(find_cmd, sizeof(find_cmd), log_search_path);

    char *cmd = NULL;
    if (asprintf(&cmd, "%s | egrep --color=never -i \"%s\"", find_cmd, pattern) < 0 || !cmd) {
        perror("asprintf");
        free(pattern);
        return;
    }

    FILE *proc = popen(cmd, "r");
    if (!proc) { perror("popen"); free(pattern); free(cmd); return; }

    json_object *json_arr = json_object_new_array();
    char buf[4096];

    while (fgets(buf, sizeof(buf), proc)) {
        json_object *obj = json_object_new_object();
        json_object_object_add(obj, "log_entry", json_object_new_string(buf));
        json_object_array_add(json_arr, obj);
    }

    (void)pclose(proc);
    free(cmd);
    free(pattern);

    if (json_object_array_length(json_arr) > 0) {
        const char *outname = "log_search_results.json";
        FILE *out = fopen(outname, "w");
        if (!out) {
            perror("fopen");
        } else {
            fputs(json_object_to_json_string_ext(json_arr, JSON_C_TO_STRING_PRETTY), out);
            fclose(out);
            printf("\nExported search results to %s\n", outname);
        }
    } else {
        printf("\nNo matching log entries found.\n");
    }

    json_object_put(json_arr);
}

void display_help() {
    const char *help_text =
        ANSI_COLOR_CYAN "\n=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=\n\n" ANSI_COLOR_RESET
        ANSI_COLOR_CYAN "TAIL MODE\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "Logs are automatically stitched together by timestamp making \n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "events easy to follow in real time " ANSI_COLOR_CYAN "(CTRL+C to quit)\n\n" ANSI_COLOR_RESET
        ANSI_COLOR_CYAN "LESS MODE\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "Buffers from tail mode are sent directly to less, a powerful\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "text editing tool that allows for in-depth review, searches and\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "real-time log analysis " ANSI_COLOR_CYAN "(h for help)" ANSI_COLOR_LIGHT_GRAY " or " ANSI_COLOR_CYAN "(q to quit)\n" ANSI_COLOR_RESET
        ANSI_COLOR_CYAN "\n=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=\n\n" ANSI_COLOR_RESET
        ANSI_COLOR_CYAN "MENU OVERVIEW\n\n" ANSI_COLOR_RESET
        ANSI_COLOR_DARK "[" ANSI_COLOR_LIGHT_GREEN "A" ANSI_COLOR_DARK "]" ANSI_COLOR_BLUE "uthentication " ANSI_COLOR_DARK "(" ANSI_COLOR_CYAN "Tail" ANSI_COLOR_DARK ") - " ANSI_COLOR_BLUE "Track down security and authentication issues in real time.\n" ANSI_COLOR_RESET
        ANSI_COLOR_CYAN " - Identify events such as" ANSI_COLOR_DARK ":\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'authentication failed'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'permission denied'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'invalid user'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'unauthorized access'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'SQL injection detected'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'cross-site scripting attempt'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'directory traversal attack'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'and more...'\n\n" ANSI_COLOR_RESET
        ANSI_COLOR_DARK "[" ANSI_COLOR_LIGHT_GREEN "E" ANSI_COLOR_DARK "]" ANSI_COLOR_BLUE "rrors " ANSI_COLOR_DARK "(" ANSI_COLOR_CYAN "Tail" ANSI_COLOR_DARK ") - " ANSI_COLOR_BLUE "Tuned for error reporting.\n" ANSI_COLOR_RESET
        ANSI_COLOR_CYAN " - Filters logs for error-related events such as" ANSI_COLOR_DARK ":\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'error'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'failure'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'critical'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'socket timeout'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'network reset'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'DNS resolution failure'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'permission denied'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'and more...'\n\n" ANSI_COLOR_RESET
        ANSI_COLOR_DARK "[" ANSI_COLOR_LIGHT_GREEN "L" ANSI_COLOR_DARK "]" ANSI_COLOR_BLUE "ogHOG (Every log stitched together in timestamp order) - Troubleshoot anything\n" ANSI_COLOR_RESET
        ANSI_COLOR_CYAN " - Displays every log in real time, sorted by timestamp.\n\n" ANSI_COLOR_RESET
        ANSI_COLOR_DARK "[" ANSI_COLOR_LIGHT_GREEN "N" ANSI_COLOR_DARK "]" ANSI_COLOR_BLUE "etwork Protocol Filter " ANSI_COLOR_DARK "(" ANSI_COLOR_CYAN "Tail" ANSI_COLOR_DARK ") - " ANSI_COLOR_BLUE "Filters logs by protocol such as" ANSI_COLOR_DARK ":\n" ANSI_COLOR_RESET
        ANSI_COLOR_CYAN " - Identify events such as" ANSI_COLOR_DARK ":\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'http://'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'https://'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'ftp://'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'ssh://'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'telnet://'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'smtp://'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'sftp://'\n\n" ANSI_COLOR_RESET
        ANSI_COLOR_DARK "[" ANSI_COLOR_LIGHT_GREEN "R" ANSI_COLOR_DARK "]" ANSI_COLOR_BLUE "egex " ANSI_COLOR_DARK "(" ANSI_COLOR_CYAN "Tail" ANSI_COLOR_DARK ") - " ANSI_COLOR_BLUE "Search EVERYTHING using standard regular expressions such as" ANSI_COLOR_DARK ":\n" ANSI_COLOR_RESET
        ANSI_COLOR_CYAN " - Search every log instantly for any regular expression, pattermatching, rnges and wild cards" ANSI_COLOR_DARK ":\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'error|failure'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'REGEX_PATTERN'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     '(?:[0-9]{1,3}\\.){3}[0-9]{1,3}'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     '(authentication|permission|invalid user)'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     '(DoS|DDoS attack)'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'brute-force|directory traversal'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     '(SQL injection|cross-site scripting)'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     '(192.168.???.*) or ranges (192.168.[1..10].[1..100])'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     '(GET|POST|PUT|DELETE|PATCH) /[a-zA-Z0-9/_-]*'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'cron.*\\((root|admin)\\)'\n\n" ANSI_COLOR_RESET
        ANSI_COLOR_DARK "[" ANSI_COLOR_LIGHT_GREEN "I" ANSI_COLOR_DARK "]" ANSI_COLOR_BLUE "P (Log Search) - " ANSI_COLOR_CYAN "Filters logs by IP, ranges, and regular expressions such as" ANSI_COLOR_DARK ":\n" ANSI_COLOR_RESET
        ANSI_COLOR_CYAN " - Complex IP range searchs, made easy with standard [] .. | () queries" ANSI_COLOR_DARK ":\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     '(192.168.[1..25].[40..120])'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     '(192\\.168\\.[0-9]+\\.[0-9]+)'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     '(192|172|10)'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     ':(?::[A-Fa-f0-9]{1,4}){1,7}'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     '192\\.168\\.\\d{1,3}\\.\\d{1,3}'\n\n" ANSI_COLOR_RESET
        ANSI_COLOR_DARK "[" ANSI_COLOR_LIGHT_GREEN "S" ANSI_COLOR_DARK "]" ANSI_COLOR_BLUE "et (Log Paths) - " ANSI_COLOR_CYAN "Allows setting custom log paths such as" ANSI_COLOR_DARK ":\n" ANSI_COLOR_RESET
        ANSI_COLOR_CYAN " - Can be used as a remote log monitoring tool" ANSI_COLOR_DARK ":\n" ANSI_COLOR_RESET    
        ANSI_COLOR_LIGHT_GRAY "     '/nfs/shre /mnt/'\n" ANSI_COLOR_RESET    
        ANSI_COLOR_LIGHT_GRAY "     '/var/log /opt/logs'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     '/var/lib/docker /var/log/nginx'\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     '/usr/local/logs /home/user/logs'\n\n" ANSI_COLOR_RESET
        ANSI_COLOR_DARK "[" ANSI_COLOR_LIGHT_GREEN "J" ANSI_COLOR_DARK "]" ANSI_COLOR_BLUE "SON (Export tool) - " ANSI_COLOR_CYAN "Exports filtered logs to a JSON file in the home directory called" ANSI_COLOR_MAGENTA " log_search_results.json" ANSI_COLOR_DARK ".\n" ANSI_COLOR_RESET
        ANSI_COLOR_LIGHT_GRAY "     'jq '.[] | .log_entry' log_search_results.json'\n\n" ANSI_COLOR_RESET
        ANSI_COLOR_DARK "[" ANSI_COLOR_LIGHT_GREEN "H" ANSI_COLOR_DARK "]" ANSI_COLOR_BLUE "elp - " ANSI_COLOR_CYAN "Displays this Help.\n" ANSI_COLOR_RESET
        ANSI_COLOR_DARK "[" ANSI_COLOR_LIGHT_GREEN "Q" ANSI_COLOR_DARK "]" ANSI_COLOR_BLUE "uit - " ANSI_COLOR_CYAN "Exits the application.\n" ANSI_COLOR_RESET
        ANSI_COLOR_CYAN "\n=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=\n" ANSI_COLOR_RESET;

    display_buffer_with_less(help_text, strlen(help_text));
}

void main_menu(void) {
    while (1) {
        printf(ANSI_COLOR_GREEN ASCII_ART ANSI_COLOR_RESET);
        printf(ANSI_COLOR_DARK "(" ANSI_COLOR_LIGHT_GREEN "A" ANSI_COLOR_DARK ")" ANSI_COLOR_LIGHT_GREEN "uth\n" ANSI_COLOR_RESET);
        printf(ANSI_COLOR_DARK "(" ANSI_COLOR_LIGHT_GREEN "E" ANSI_COLOR_DARK ")" ANSI_COLOR_LIGHT_GREEN "rror\n" ANSI_COLOR_RESET);
        printf(ANSI_COLOR_DARK "(" ANSI_COLOR_LIGHT_GREEN "L" ANSI_COLOR_DARK ")" ANSI_COLOR_LIGHT_GREEN "ive (all logs)\n" ANSI_COLOR_RESET);
        printf(ANSI_COLOR_DARK "(" ANSI_COLOR_LIGHT_GREEN "N" ANSI_COLOR_DARK ")" ANSI_COLOR_LIGHT_GREEN "etwork\n" ANSI_COLOR_RESET);
        printf(ANSI_COLOR_DARK "(" ANSI_COLOR_LIGHT_GREEN "R" ANSI_COLOR_DARK ")" ANSI_COLOR_LIGHT_GREEN "egEx\n" ANSI_COLOR_RESET);
        printf(ANSI_COLOR_DARK "(" ANSI_COLOR_LIGHT_GREEN "I" ANSI_COLOR_DARK ")" ANSI_COLOR_LIGHT_GREEN "pEx\n" ANSI_COLOR_RESET);
        printf(ANSI_COLOR_DARK "(" ANSI_COLOR_LIGHT_GREEN "S" ANSI_COLOR_DARK ")" ANSI_COLOR_LIGHT_GREEN "et dir\n" ANSI_COLOR_RESET);
        printf(ANSI_COLOR_DARK "(" ANSI_COLOR_LIGHT_GREEN "J" ANSI_COLOR_DARK ")" ANSI_COLOR_LIGHT_GREEN "sonEx\n" ANSI_COLOR_RESET);
        printf(ANSI_COLOR_DARK "(" ANSI_COLOR_LIGHT_GREEN "H" ANSI_COLOR_DARK ")" ANSI_COLOR_LIGHT_GREEN "elp!\n" ANSI_COLOR_RESET);
        printf(ANSI_COLOR_DARK "(" ANSI_COLOR_LIGHT_GREEN "Q" ANSI_COLOR_DARK ")" ANSI_COLOR_LIGHT_GREEN "uit!\n" ANSI_COLOR_RESET);
        printf(ANSI_COLOR_DARK "\n-" ANSI_COLOR_LIGHT_GRAY "> " ANSI_COLOR_RESET);

        char *option = readline(NULL);
        if (!option) { continue; }

        char opt = option[0];
        switch (opt) {
            case 'A': case 'a': live_auth_log(log_search_path); break;
            case 'E': case 'e': live_error_log(log_search_path); break;
            case 'L': case 'l': live_log(log_search_path); break;
            case 'N': case 'n': live_network_log(log_search_path); break;
            case 'R': case 'r': run_regex(log_search_path); break;
            case 'I': case 'i': search_ip(log_search_path); break;
            case 'S': case 's': edit_log_paths(log_search_path); break;
            case 'J': case 'j': export_search_results_to_json(log_search_path); break;
            case 'H': case 'h': display_help(); break;
            case 'Q': case 'q': free(option); return;
            default: printf(ANSI_COLOR_BLUE "oops!\n" ANSI_COLOR_RESET); break;
        }
        free(option);
    }
}

void sigint_handler(int sig) {
    (void)sig;
    printf("\nReturning to menu...\n");
    fflush(stdout);
}
