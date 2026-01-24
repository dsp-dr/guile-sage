# guile-sage Makefile

GUILE = guile3
GUILD = guild3
SRCDIR = src
TESTDIR = tests

# Source files
SOURCES = $(wildcard $(SRCDIR)/sage/*.scm)
OBJECTS = $(SOURCES:.scm=.go)

.PHONY: all clean check repl run init check-config help docs publish run-yolo check-verbose uat uat-yolo

all: $(OBJECTS)

%.go: %.scm
	$(GUILD) compile -L $(SRCDIR) -o $@ $<

repl:
	$(GUILE) -L $(SRCDIR)

run:
	$(GUILE) -L $(SRCDIR) -c '(use-modules (sage repl)) (repl-start)'

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

# Documentation targets (non-phony, depend on .org sources)
DOCS_ORG = $(wildcard docs/*.org)
DOCS_PDF = $(DOCS_ORG:.org=.pdf)
DOCS_HTML = $(DOCS_ORG:.org=.html)

docs/PRESENTATION.pdf: docs/PRESENTATION.org
	@echo "Building $@ from $<..."
	emacs --batch \
		--eval "(require 'ox-beamer)" \
		--eval "(find-file \"$<\")" \
		--eval "(org-beamer-export-to-pdf)" \
		2>/dev/null || echo "Note: Emacs/LaTeX not available for PDF export"

docs/%.html: docs/%.org
	@echo "Building $@ from $<..."
	emacs --batch \
		--eval "(require 'ox-html)" \
		--eval "(find-file \"$<\")" \
		--eval "(org-html-export-to-html)" \
		2>/dev/null || echo "Note: Emacs not available for HTML export"

# Publishing
publish: docs
	@echo "Documentation built in docs/"

# YOLO mode
run-yolo:
	SAGE_YOLO_MODE=1 $(GUILE) -L $(SRCDIR) -c '(use-modules (sage repl)) (repl-start)'

# Test with metrics
check-verbose:
	@echo "Running tests with verbose output..."
	@total=0; passed=0; \
	for test in $(TESTDIR)/test-*.scm; do \
		echo "=== $$test ==="; \
		result=$$($(GUILE) -L $(SRCDIR) $$test 2>&1); \
		echo "$$result"; \
		t=$$(echo "$$result" | grep -o 'Tests: [0-9]*/[0-9]*' | head -1); \
		if [ -n "$$t" ]; then \
			p=$$(echo "$$t" | sed 's/Tests: \([0-9]*\).*/\1/'); \
			n=$$(echo "$$t" | sed 's/.*\/\([0-9]*\).*/\1/'); \
			passed=$$((passed + p)); \
			total=$$((total + n)); \
		fi; \
	done; \
	echo ""; \
	echo "=== TOTAL: $$passed/$$total tests passed ==="

# UAT tests
uat:
	@echo "Running UAT tests..."
	$(GUILE) -L $(SRCDIR) ../guile-sage-uat/tests/test-tools-uat.scm

uat-yolo:
	@echo "Running UAT tests in YOLO mode..."
	SAGE_YOLO_MODE=1 $(GUILE) -L $(SRCDIR) ../guile-sage-uat/tests/test-tools-uat.scm

help:
	@echo "Targets:"
	@echo "  all          - Compile all modules"
	@echo "  init         - Initialize and validate setup"
	@echo "  check-config - Check configuration"
	@echo "  repl         - Start interactive REPL"
	@echo "  run          - Run sage CLI"
	@echo "  run-yolo     - Run sage CLI in YOLO mode"
	@echo "  check        - Run tests"
	@echo "  check-verbose- Run tests with metrics"
	@echo "  uat          - Run UAT tests"
	@echo "  uat-yolo     - Run UAT tests in YOLO mode"
	@echo "  docs         - Build documentation"
	@echo "  publish      - Build and prepare for publishing"
	@echo "  clean        - Remove compiled files"
