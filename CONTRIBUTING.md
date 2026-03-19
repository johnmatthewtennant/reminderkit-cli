# Contributing

## Architecture

```
remkit-inspect.m           Runtime introspection tool — dumps ObjC properties/methods
        |
        v  (stdout: property list)
generate-cli.py            Code generator — reads config dicts, emits Objective-C
        |
        v  (stdout: generated source)
reminderkit-generated.m    AUTO-GENERATED — config-driven commands, helpers, serialization
reminderkit-handwritten.m  Manually maintained commands (cmdBatch, cmdInstallSkill)
reminderkit-tests.m        Test infrastructure (cmdTest + helpers)
reminderkit.m              Assembly file — #includes the above three + usage/main
        |
        v  (clang)
reminderkit                Final binary
```

`remkit-inspect.m` discovers available properties and methods on `REMReminder` and related classes at runtime. Its output feeds into `generate-cli.py`, which uses configuration dictionaries (`REMINDER_READ_PROPS`, `REMINDER_WRITE_OPS`, `SPECIAL_WRITE_OPS`) to produce `reminderkit-generated.m`.

**File ownership:**
- `reminderkit-generated.m` — owned by the generator. Do not edit manually. Run `make generate` to regenerate.
- `reminderkit-handwritten.m` — manually maintained commands not produced by the generator.
- `reminderkit-tests.m` — test infrastructure, manually maintained.
- `reminderkit.m` — assembly file with `#include` directives, `usage()`, and `main()`. Manually maintained.

**Include order matters:** `reminderkit.m` includes generated → handwritten → tests. Each file depends on symbols from earlier includes (generated provides helpers, handwritten provides batch/skill commands, tests use both). Do not reorder.

## Building

```bash
make              # build reminderkit binary
make generate     # regenerate reminderkit-generated.m and rebuild
make clean        # remove build artifacts
```

## Discovering new properties

```bash
make remkit-inspect
./remkit-inspect 2>&1 | less
```

This dumps all Objective-C properties and methods on `REMReminder`, `REMReminderChangeItem`, and related classes. Use this to find new properties to expose.

## Adding a new read property

1. Add an entry to `REMINDER_READ_PROPS` in `generate-cli.py`:
   ```python
   "objcPropertyName": ("jsonKey", "type_hint"),
   ```
2. Type hints: `"string"`, `"bool"`, `"bool_getter"`, `"int"`, `"uint"`, `"date"`, `"datecomps"`, `"objid"`, `"set_hashtags"`
3. Regenerate: `make generate`

## Adding a new write operation (setter)

1. Add an entry to `REMINDER_WRITE_OPS` in `generate-cli.py`:
   ```python
   "cli-flag": ("setterSelector:", "arg_type"),
   ```
2. Arg types: `"string"`, `"bool"`, `"int"`, `"uint"`, `"datecomps"`, `"url"`
3. For no-arg methods (like `removeFromParentReminder`), add to `SPECIAL_WRITE_OPS` instead
4. Regenerate: `make generate`

## Adding a handwritten command

1. Add the command function to `reminderkit-handwritten.m`
2. Add dispatch logic to `main()` in `reminderkit.m`
3. Add usage line to `usage()` in `reminderkit.m`
4. Rebuild: `make`

## Running tests

```bash
make && ./reminderkit test
```

Tests create a temporary list (`__remcli_test_list__`) in Apple Reminders, exercise all commands, and clean up. They run against the real Reminders store — no mocks.

## Adding a test

Tests are numbered sequentially in `cmdTest` in `reminderkit-tests.m`. Add new tests before the cleanup section (the `cmdDelete child` / `cmdDelete parent` / `cmdDeleteList` tests at the end).

## Generator sync

A pre-push hook verifies that `reminderkit-generated.m` matches the generator output. If it fails, run `make generate` and commit the result.
