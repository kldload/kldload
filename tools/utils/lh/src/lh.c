// lh.c — shared helpers and globals
#include "common.h"

// Default monitored paths
char log_search_path[BUFFER_SIZE] = "/var/log";

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
