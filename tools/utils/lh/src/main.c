// main.c
#include "common.h"
#include "loghog_functions.h"

int main(void) {
    signal(SIGINT, sigint_handler);
    main_menu();
    return 0;
}
