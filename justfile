set positional-arguments

# List available commands.
default:
    @just --list

# Build the app and smoke executable.
build:
    @scripts/build.sh

# Build and run the tests used by CI.
test:
    @scripts/build.sh test

# Reload code in-process, preserving the window and vault unlock.
dev *args:
    @scripts/dev.sh "$@"

# Run the built app, optionally with a data directory.
run *args:
    @build/app "$@"

# Stage dependencies and native helpers without building the app.
stage:
    @scripts/build.sh stage

# Check code reload, unlock preservation, and failed-build recovery.
test-reload:
    @tests/dev-reload-test.sh

# Regenerate and merge gettext catalogs.
translations:
    @scripts/update-translations.sh
