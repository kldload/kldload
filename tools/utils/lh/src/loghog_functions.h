// loghog_functions.h
#pragma once
#include <stddef.h>

// Pipelines/helpers
void find_logs_command(char *buffer, size_t size, const char *search_path);
void display_buffer_with_less(const char *buffer, size_t length);
void run_command_with_buffer(const char *cmd, void (*buffer_action)(const char *, size_t));

// Modes/actions
void live_auth_log(const char *log_search_path);
void live_error_log(const char *log_search_path);
void live_log(const char *log_search_path);
void live_network_log(const char *log_search_path);
void run_regex(const char *log_search_path);
void search_ip(const char *log_search_path);
void edit_log_paths(char *log_search_path);
void export_search_results_to_json(const char *log_search_path);
void display_help(void);

// UI
void main_menu(void);

// Signals
void sigint_handler(int sig);
