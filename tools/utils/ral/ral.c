#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <dirent.h>
#include <unistd.h>

void print_help(const char *program_name) {
    printf("Usage: %s [options] <directory>\n", program_name);
    printf("Options:\n");
    printf("  -h          Display this help and exit\n");
    printf("  -r          Enable recursion into subdirectories\n");
    printf("  -d <char>   Specify a different character to replace spaces (default is '.')\n");
    printf("\n");
    printf("Examples:\n");
    printf("ral /tv/ .    renames all files and subdirs with 'dots' .\n");
    printf("*/5 * * * * /usr/local/bin/ral /tv/ . (every 5 mins as a crontab)\n");
    printf("ral /tv/ -d _ (rename with underscores)\n");
    printf("\n");
}

void to_lowercase_and_replace_space(char *str, char replace_char) {
    for (int i = 0; str[i]; i++) {
        if (str[i] == ' ') {
            str[i] = replace_char;
        }
        str[i] = tolower(str[i]);
    }
}

int process_directory(const char *directory, char replace_char, int recursive) {
    DIR *d;
    struct dirent *dir;
    char newname[256];
    char oldpath[512];
    char newpath[512];

    d = opendir(directory);
    if (d) {
        while ((dir = readdir(d)) != NULL) {
            if (dir->d_type == DT_REG) {
                snprintf(oldpath, sizeof(oldpath), "%s/%s", directory, dir->d_name);
                strcpy(newname, dir->d_name);
                to_lowercase_and_replace_space(newname, replace_char);
                snprintf(newpath, sizeof(newpath), "%s/%s", directory, newname);

                if (strcmp(oldpath, newpath) != 0) {
                    if (access(newpath, F_OK) != -1) {
                        remove(newpath);
                    }
                    if (rename(oldpath, newpath) == 0) {
                        printf("Renamed '%s' to '%s'\n", oldpath, newpath);
                    } else {
                        perror("Error renaming file");
                    }
                }
            }
        }
        closedir(d);
        return EXIT_SUCCESS;
    } else {
        perror("Failed to open directory");
        return EXIT_FAILURE;
    }
}

int main(int argc, char *argv[]) {
    int opt;
    int recursive = 0;
    char replace_char = '.';

    while ((opt = getopt(argc, argv, "hrd:")) != -1) {
        switch (opt) {
            case 'h':
                print_help(argv[0]);
                return EXIT_SUCCESS;
            case 'r':
                recursive = 1;
                break;
            case 'd':
                replace_char = optarg[0];
                break;
            default:
                print_help(argv[0]);
                return EXIT_FAILURE;
        }
    }

    if (optind >= argc) {
        fprintf(stderr, "Expected directory argument after options\n\n");
        print_help(argv[0]);  // Show help menu when no directory is specified
        return EXIT_FAILURE;
    }

    return process_directory(argv[optind], replace_char, recursive);
}
