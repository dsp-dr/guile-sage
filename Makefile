# guile-sage Makefile

GUILE = guile3
GUILD = guild3
SRCDIR = src
TESTDIR = tests

# Source files
SOURCES = $(wildcard $(SRCDIR)/sage/*.scm)
OBJECTS = $(SOURCES:.scm=.go)

.PHONY: all clean check repl run init check-config

all: $(OBJECTS)

%.go: %.scm
	$(GUILD) compile -L $(SRCDIR) -o $@ $<

repl:
	$(GUILE) -L $(SRCDIR)

run:
	$(GUILE) -L $(SRCDIR) -e '(sage main)' -c '(main (command-line))'

check:
	@for test in $(TESTDIR)/test-*.scm; do \
		echo "Running $$test..."; \
		$(GUILE) -L $(SRCDIR) $$test || exit 1; \
	done
	@echo "All tests passed."

clean:
	find . -name "*.go" -delete
	find . -name "*~" -delete

# Development helpers
tags:
	etags $(SOURCES)

lint:
	@echo "Checking for common issues..."
	@grep -rn "make-vector" $(SRCDIR) && echo "Warning: make-vector conflicts with core" || true

init:
	@sh scripts/init.sh

check-config:
	@sh scripts/check-config.sh

help:
	@echo "Targets:"
	@echo "  all          - Compile all modules"
	@echo "  init         - Initialize and validate setup"
	@echo "  check-config - Check configuration"
	@echo "  repl         - Start interactive REPL"
	@echo "  run          - Run sage CLI"
	@echo "  check        - Run tests"
	@echo "  clean        - Remove compiled files"
