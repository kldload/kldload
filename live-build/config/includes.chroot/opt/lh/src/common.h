// common.h
#pragma once

// Feature-test macros to expose POSIX/XSI when compiling with -std=c11
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700

// System headers
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <fcntl.h>

// Third-party
#include <json-c/json.h>
#include <readline/readline.h>
#include <readline/history.h>

// Project headers
#include "ansi_colors.h"
#include "ascii_art.h"

// Shared constants (bumped to reduce truncation issues)
#define BUFFER_SIZE 16384

// Shared helpers (implemented in lh.c)
char *get_user_input(const char *prompt);
int   sanitize_input(char *input);

// Global (defined in lh.c)
extern char log_search_path[BUFFER_SIZE];
