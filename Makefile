# guile-sage Makefile

GUILE = guile3
GUILD = guild3
SRCDIR = src
TESTDIR = tests

# Installation directories (XDG-compliant user-local install)
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
DATADIR ?= $(PREFIX)/share
LIBDIR ?= $(PREFIX)/lib

# Guile-specific install paths
GUILE_SITE_DIR ?= $(DATADIR)/guile/site/3.0
GUILE_CCACHE_DIR ?= $(LIBDIR)/guile/3.0/site-ccache

# Source files
SOURCES = $(wildcard $(SRCDIR)/sage/*.scm)
OBJECTS = $(SOURCES:.scm=.go)

.PHONY: all clean check repl run init check-config help docs publish run-yolo check-verbose uat uat-yolo install-hooks version build install uninstall patch minor major release tag docker docker-run docker-push

all: $(OBJECTS)

# Alias for all
build: all

%.go: %.scm
	$(GUILD) compile -L $(SRCDIR) -o $@ $<

version:
	@$(GUILE) -L $(SRCDIR) -c '(use-modules (sage version)) (format #t "guile-sage v~a~%" (version-string))'

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

# Installation
install: build
	@echo "Installing guile-sage to $(PREFIX)..."
	@mkdir -p $(BINDIR)
	@mkdir -p $(GUILE_SITE_DIR)/sage
	@mkdir -p $(GUILE_CCACHE_DIR)/sage
	@# Install source files
	@for f in $(SRCDIR)/sage/*.scm; do \
		install -m 644 "$$f" $(GUILE_SITE_DIR)/sage/; \
	done
	@# Install compiled files
	@for f in $(SRCDIR)/sage/*.go; do \
		if [ -f "$$f" ]; then \
			install -m 644 "$$f" $(GUILE_CCACHE_DIR)/sage/; \
		fi; \
	done
	@# Install resources
	@mkdir -p $(DATADIR)/sage/prompts
	@if [ -d resources/prompts ]; then \
		cp -r resources/prompts/* $(DATADIR)/sage/prompts/ 2>/dev/null || true; \
	fi
	@# Create wrapper script
	@echo '#!/bin/sh' > $(BINDIR)/sage
	@echo '# guile-sage wrapper script' >> $(BINDIR)/sage
	@echo 'exec $(GUILE) -L $(GUILE_SITE_DIR) -C $(GUILE_CCACHE_DIR) -c "(use-modules (sage main)) (main (command-line))" "$$@"' >> $(BINDIR)/sage
	@chmod +x $(BINDIR)/sage
	@echo "Installed:"
	@echo "  Binary:  $(BINDIR)/sage"
	@echo "  Modules: $(GUILE_SITE_DIR)/sage/"
	@echo "  Cache:   $(GUILE_CCACHE_DIR)/sage/"
	@echo ""
	@echo "Ensure $(BINDIR) is in your PATH"

uninstall:
	@echo "Uninstalling guile-sage from $(PREFIX)..."
	@rm -f $(BINDIR)/sage
	@rm -rf $(GUILE_SITE_DIR)/sage
	@rm -rf $(GUILE_CCACHE_DIR)/sage
	@rm -rf $(DATADIR)/sage
	@echo "Uninstalled guile-sage"

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

install-hooks:
	@echo "Installing git hooks..."
	@if [ -f .git/hooks/pre-commit ]; then \
		if ! grep -q "guile-sage pre-commit" .git/hooks/pre-commit; then \
			echo "" >> .git/hooks/pre-commit; \
			echo "# guile-sage pre-commit hook" >> .git/hooks/pre-commit; \
			echo "if [ -x scripts/pre-commit ]; then scripts/pre-commit || exit 1; fi" >> .git/hooks/pre-commit; \
			echo "Added guile-sage hook to existing pre-commit."; \
		else \
			echo "guile-sage hook already installed."; \
		fi; \
	else \
		cp scripts/pre-commit .git/hooks/pre-commit; \
		chmod +x .git/hooks/pre-commit; \
		echo "Installed pre-commit hook."; \
	fi

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

# Version bumping (semantic versioning)
patch:
	@sh scripts/bump-version.sh patch

minor:
	@sh scripts/bump-version.sh minor

major:
	@sh scripts/bump-version.sh major

# Get current version as variable
VERSION = $(shell $(GUILE) -L $(SRCDIR) -c '(use-modules (sage version)) (display (version-string))')

# Create and push git tag
tag:
	@echo "Creating tag v$(VERSION)..."
	@git tag -a "v$(VERSION)" -m "Release v$(VERSION)"
	@echo "Created tag v$(VERSION)"
	@echo "Push with: git push origin v$(VERSION)"

# GitHub release (requires gh CLI)
release: build
	@echo "Creating GitHub release v$(VERSION)..."
	@if ! command -v gh >/dev/null 2>&1; then \
		echo "Error: gh CLI not installed. Install with: pkg install gh"; \
		exit 1; \
	fi
	@if ! git tag | grep -q "^v$(VERSION)$$"; then \
		echo "Tag v$(VERSION) not found. Creating..."; \
		git tag -a "v$(VERSION)" -m "Release v$(VERSION)"; \
	fi
	@git push origin "v$(VERSION)" 2>/dev/null || true
	@gh release create "v$(VERSION)" \
		--title "guile-sage v$(VERSION)" \
		--generate-notes \
		|| echo "Release may already exist"
	@echo "Release v$(VERSION) created: https://github.com/dsp-dr/guile-sage/releases/tag/v$(VERSION)"

# Docker
DOCKER_IMAGE = ghcr.io/dsp-dr/guile-sage

docker:
	@echo "Building Docker image..."
	docker build -t $(DOCKER_IMAGE):$(VERSION) -t $(DOCKER_IMAGE):latest .
	@echo "Built: $(DOCKER_IMAGE):$(VERSION)"

docker-run:
	docker run --rm -it -v $(PWD):/workspace $(DOCKER_IMAGE):latest

docker-push: docker
	@echo "Pushing to GitHub Container Registry..."
	docker push $(DOCKER_IMAGE):$(VERSION)
	docker push $(DOCKER_IMAGE):latest
	@echo "Pushed: $(DOCKER_IMAGE):$(VERSION)"

# UAT tests
uat:
	@echo "Running UAT tests..."
	$(GUILE) -L $(SRCDIR) ../guile-sage-uat/tests/test-tools-uat.scm

uat-yolo:
	@echo "Running UAT tests in YOLO mode..."
	SAGE_YOLO_MODE=1 $(GUILE) -L $(SRCDIR) ../guile-sage-uat/tests/test-tools-uat.scm

help:
	@echo "Targets:"
	@echo "  all/build     - Compile all modules to .go files"
	@echo "  install       - Install to PREFIX (default: ~/.local)"
	@echo "  uninstall     - Remove installed files"
	@echo "  version       - Show version"
	@echo "  init          - Initialize and validate setup"
	@echo "  install-hooks - Install git pre-commit hooks"
	@echo "  check-config  - Check configuration"
	@echo "  repl          - Start interactive REPL"
	@echo "  run           - Run sage CLI"
	@echo "  run-yolo      - Run sage CLI in YOLO mode"
	@echo "  check         - Run tests"
	@echo "  check-verbose - Run tests with metrics"
	@echo "  uat           - Run UAT tests"
	@echo "  uat-yolo      - Run UAT tests in YOLO mode"
	@echo "  docs          - Build documentation"
	@echo "  publish       - Build and prepare for publishing"
	@echo "  clean         - Remove compiled files"
	@echo ""
	@echo "Version & Release:"
	@echo "  patch         - Bump patch version (0.1.0 -> 0.1.1)"
	@echo "  minor         - Bump minor version (0.1.0 -> 0.2.0)"
	@echo "  major         - Bump major version (0.1.0 -> 1.0.0)"
	@echo "  tag           - Create git tag for current version"
	@echo "  release       - Create GitHub release (requires gh CLI)"
	@echo ""
	@echo "Install options:"
	@echo "  PREFIX=~/.local  - Installation prefix (default)"
	@echo "  PREFIX=/opt/sage - System-wide install"
	@echo ""
	@echo "Docker:"
	@echo "  docker        - Build Docker image"
	@echo "  docker-run    - Run sage in container with current dir mounted"
	@echo "  docker-push   - Push to GitHub Container Registry"
	@echo ""
	@echo "Release workflow:"
	@echo "  1. make patch              # bump version"
	@echo "  2. git add -A && git commit -m 'chore: bump to vX.Y.Z'"
	@echo "  3. make tag                # create git tag"
	@echo "  4. git push && git push --tags"
	@echo "  5. make release            # create GitHub release"
