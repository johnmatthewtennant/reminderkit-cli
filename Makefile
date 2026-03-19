CC = clang
CFLAGS = -framework Foundation -lobjc -O2

all: reminderkit

reminderkit: reminderkit.m
	$(CC) $(CFLAGS) $< -o $@

remkit-inspect: remkit-inspect.m
	$(CC) $(CFLAGS) $< -o $@

generate: generate-cli.py
	./remkit-inspect 2>&1 | python3 generate-cli.py > reminderkit.m
	$(MAKE) reminderkit

install-hooks:
	git config core.hooksPath .githooks

clean:
	rm -f reminderkit remkit-inspect

.PHONY: all clean generate install-hooks
