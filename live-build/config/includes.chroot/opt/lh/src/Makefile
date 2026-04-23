APP := lh
SRC := main.c loghog_functions.c lh.c
CSTD := -std=c11
WARN := -Wall -Wextra -Wpedantic
OPT  := -O2

# Feature macros (also present in headers; keeping here for safety)
DEFS := -D_GNU_SOURCE -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700

JSONC_CFLAGS := $(shell pkg-config --cflags json-c)
JSONC_LIBS   := $(shell pkg-config --libs json-c)
READLINE_LIBS := -lreadline -lncurses

CFLAGS  := $(CSTD) $(WARN) $(OPT) $(DEFS) $(JSONC_CFLAGS)
LDLIBS  := $(JSONC_LIBS) $(READLINE_LIBS)

.PHONY: all clean install uninstall debug

all: $(APP)

$(APP): $(SRC)
	$(CC) $(CFLAGS) $^ -o $@ $(LDLIBS)

debug: CFLAGS := -std=c11 -g3 -O0 $(WARN) $(DEFS) $(JSONC_CFLAGS)
debug: LDFLAGS :=
debug: $(APP)

clean:
	rm -f $(APP)

install: $(APP)
	install -m0755 $(APP) /usr/local/bin/$(APP)

uninstall:
	rm -f /usr/local/bin/$(APP)
