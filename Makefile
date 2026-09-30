DC ?= ldc2
DFLAGS ?= -O -release
WARNFLAGS ?= -w -de
BIN_DIR ?= bin
SOURCES := $(wildcard source/dtask/*.d)
TESTS := $(wildcard tests/*.d)

.PHONY: all test clean install
all: $(BIN_DIR)/dtask

$(BIN_DIR)/dtask: source/app.d $(SOURCES)
	mkdir -p "$(BIN_DIR)"
	$(DC) $(DFLAGS) $(WARNFLAGS) -Isource source/app.d $(SOURCES) -of=$@

test: $(BIN_DIR)/dtask
	mkdir -p "$(BIN_DIR)"
	$(DC) $(WARNFLAGS) -unittest -Isource tests/runner.d $(filter-out tests/runner.d,$(TESTS)) $(SOURCES) -of=$(BIN_DIR)/dtask-tests
	"$(BIN_DIR)/dtask-tests"
	python3 tests/integration.py "$(BIN_DIR)/dtask"

PREFIX ?= $(HOME)/.local
install: $(BIN_DIR)/dtask
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 "$(BIN_DIR)/dtask" "$(DESTDIR)$(PREFIX)/bin/dtask"

clean:
	rm -rf "$(BIN_DIR)" .dub
