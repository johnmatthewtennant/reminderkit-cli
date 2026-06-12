CC = clang
# Version embedded in the binary. The Homebrew formula passes VERSION=#{version}
# (the release tag); local builds fall back to the latest git tag, then "dev".
VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo dev)
CFLAGS = -framework Foundation -framework EventKit -lobjc -O2 -DREMINDERKIT_VERSION='"$(VERSION)"'
INFO_PLIST = Info.plist
BUNDLE_ID = com.jtennant.reminderkit-cli
INFO_PLIST_FLAGS = -Wl,-sectcreate,__TEXT,__info_plist,$(INFO_PLIST)

all: reminderkit

reminderkit: reminderkit.m reminderkit-version-check.m reminderkit-generated.m reminderkit-handwritten.m reminderkit-tests.m disclaim.c disclaim.h $(INFO_PLIST)
	$(CC) $(CFLAGS) $(INFO_PLIST_FLAGS) reminderkit.m disclaim.c -o $@
	codesign --force --sign - --identifier $(BUNDLE_ID) $@

remkit-inspect: remkit-inspect.m
	$(CC) $(CFLAGS) $< -o $@

generate: generate-cli.py remkit-inspect
	./remkit-inspect 2>&1 | python3 generate-cli.py > reminderkit-generated.m
	$(MAKE) reminderkit

install-hooks:
	git config core.hooksPath .githooks

clean:
	rm -f reminderkit remkit-inspect

.PHONY: all clean generate install-hooks
