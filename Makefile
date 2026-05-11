CC = clang
CFLAGS = -framework Foundation -framework EventKit -lobjc -O2
INFO_PLIST = Info.plist
BUNDLE_ID = com.jtennant.reminderkit-cli
INFO_PLIST_FLAGS = -Wl,-sectcreate,__TEXT,__info_plist,$(INFO_PLIST)

all: reminderkit

reminderkit: reminderkit.m reminderkit-generated.m reminderkit-handwritten.m reminderkit-tests.m disclaim.c disclaim.h $(INFO_PLIST)
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
