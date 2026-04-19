# guile-sage Makefile

# Detect the local Guile binary at make-time. FreeBSD ships guile3/guild3
# (because it has multiple Guile majors installed); Linux distros and
# macOS Homebrew ship plain guile/guild. Try the suffixed names first to
# preserve the FreeBSD primary-dev behaviour, then fall back. The bare
# echo at the end keeps Make happy when neither is on PATH so the
# subsequent `command not found` is a normal compile-time error rather
# than an empty-variable surprise.
GUILE := $(shell command -v guile3 2>/dev/null || command -v guile 2>/dev/null || echo guile)
GUILD := $(shell command -v guild3 2>/dev/null || command -v guild 2>/dev/null || echo guild)
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

.PHONY: all clean check repl run run-safe init check-config help docs publish check-verbose uat uat-yolo install-hooks version build install uninstall patch minor major release tag docker docker-run docker-push claude-ollama generate-showcase generate-synthetic-session generate-test-pii monitor promote-images sage-commit test-guardrails timing-bench presentation eval tmux-session tmux-kill eval-provenance demo

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
	SAGE_YOLO_MODE=1 $(GUILE) -L $(SRCDIR) -c '(use-modules (sage repl)) (repl-start)'

check:
	@for test in $(TESTDIR)/test-*.scm; do \
		echo "Running $$test..."; \
		$(GUILE) -L $(SRCDIR) $$test || exit 1; \
	done
	@echo "All tests passed."

clean:
	find . -name "*.go" -delete
	find . -name "*~" -delete
	rm -rf ~/.cache/guile/ccache

# Directory creation rule
%/:
	install -d $@

# Installation
install: build | $(BINDIR)/ $(GUILE_SITE_DIR)/sage/ $(GUILE_CCACHE_DIR)/sage/ $(DATADIR)/sage/prompts/
	@echo "Installing guile-sage to $(PREFIX)..."
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

lint: lint-code lint-org lint-docs lint-contracts
	@echo "All lint checks passed."

lint-code:
	@echo "=== Code lint ==="
	@grep -rn "make-vector" $(SRCDIR) && echo "Warning: make-vector conflicts with core" || true

lint-org:
	@echo "=== Org-mode lint ==="
	@errors=0; \
	for f in docs/*.org; do \
		if ! grep -q '#+TITLE:' "$$f"; then \
			echo "FAIL: $$f missing #+TITLE"; errors=$$((errors+1)); \
		fi; \
		title=$$(grep '#+TITLE:' "$$f" | head -1); \
		if ! echo "$$title" | grep -q 'guile-sage'; then \
			echo "WARN: $$f title doesn't start with guile-sage: $$title"; \
		fi; \
		if grep -qn '^## ' "$$f"; then \
			echo "FAIL: $$f has markdown headers in org file"; errors=$$((errors+1)); \
		fi; \
	done; \
	if [ "$$errors" -gt 0 ]; then echo "$$errors org lint errors"; exit 1; fi; \
	echo "  All org files clean."

lint-docs:
	@echo "=== Documentation lint ==="
	@scripts/doc-check.sh

lint-contracts:
	@echo "=== Contract boundary lint ==="
	@scripts/lint-contracts.sh

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

# Presentation (Beamer PDF + standalone HTML)
presentation: docs/PRESENTATION.pdf docs/PRESENTATION.html
	@echo "Presentation built:"
	@echo "  PDF:  docs/PRESENTATION.pdf"
	@echo "  HTML: docs/PRESENTATION.html"

# Publishing
publish: docs
	@echo "Documentation built in docs/"

# Run without YOLO (read-only tools only)
run-safe:
	$(GUILE) -L $(SRCDIR) -c '(use-modules (sage repl)) (repl-start)'

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

# Script wrappers
claude-ollama:
	@scripts/claude-ollama.sh

generate-showcase:
	@$(GUILE) -L $(SRCDIR) scripts/generate-showcase.scm

generate-synthetic-session:
	@python3 scripts/generate-synthetic-session.py $(ARGS)

generate-test-pii:
	@python3 scripts/generate-test-pii.py

monitor:
	@scripts/monitor-parallel.sh

promote-images:
	@scripts/promote-images.sh

# Non-phony: rebuild images/README.md when the prompt catalog changes
images/README.md: scripts/generate-showcase.scm
	@echo "Rebuilding images/README.md from prompt catalog..."
	@python3 scripts/gen-image-readme.py

sage-commit:
	@scripts/sage-commit.sh "$(MSG)"

eval:
	@scripts/eval-sage.sh $(ARGS)

eval-provenance:
	@scripts/eval-provenance.sh $(ARGS)

test-guardrails:
	@scripts/test-guardrails.sh

timing-bench:
	@scripts/timing-bench.sh

# Record a fresh demo GIF. Requires asciinema + agg + local Ollama with qwen3:0.6b.
# Strips host-specific details (username, hostname) from the asciicast before
# rendering the GIF so the output is safe to publish.
demo:
	@command -v asciinema >/dev/null 2>&1 || { echo "asciinema required: brew install asciinema"; exit 1; }
	@command -v agg >/dev/null 2>&1 || { echo "agg required: brew install agg"; exit 1; }
	@asciinema rec -c scripts/demo.sh --rows 36 --cols 110 --overwrite docs/images/demo.cast
	@sed -i.bak 's/@[^:]*:dsp-dr\/guile-sage/@host:dsp-dr\/guile-sage/g' docs/images/demo.cast
	@sed -i.bak 's|/Users/[^/]*/ghq/github.com/dsp-dr/guile-sage|/workspace/guile-sage|g' docs/images/demo.cast
	@rm docs/images/demo.cast.bak
	@agg --cols 110 --rows 36 --font-size 13 --speed 2 --theme monokai docs/images/demo.cast docs/images/demo.gif
	@echo "Wrote docs/images/demo.gif"

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

# tmux development session
SESSION = guile-sage

tmux-session:
	@if tmux has-session -t $(SESSION) 2>/dev/null; then \
		echo "Session '$(SESSION)' already exists. Attaching..."; \
		tmux attach-session -t $(SESSION); \
	else \
		tmux new-session -d -s $(SESSION) -n repl; \
		tmux send-keys -t $(SESSION):repl 'SAGE_YOLO_MODE=1 $(GUILE) -L $(SRCDIR) -c "(use-modules (sage repl)) (repl-start)"' Enter; \
		tmux new-window -t $(SESSION) -n tests; \
		tmux send-keys -t $(SESSION):tests 'gmake check' Enter; \
		tmux new-window -t $(SESSION) -n shell; \
		tmux select-window -t $(SESSION):repl; \
		tmux attach-session -t $(SESSION); \
	fi

tmux-kill:
	@tmux kill-session -t $(SESSION) 2>/dev/null && echo "Killed session '$(SESSION)'" || echo "No session '$(SESSION)' to kill"

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
	@echo "  run           - Run sage CLI (YOLO mode)"
	@echo "  run-safe      - Run sage CLI (read-only tools only)"
	@echo "  check         - Run tests"
	@echo "  check-verbose - Run tests with metrics"
	@echo "  uat           - Run UAT tests"
	@echo "  uat-yolo      - Run UAT tests in YOLO mode"
	@echo "  docs          - Build documentation"
	@echo "  publish       - Build and prepare for publishing"
	@echo "  clean         - Remove compiled files"
	@echo ""
	@echo "Scripts:"
	@echo "  claude-ollama          - Launch Claude Code backed by Ollama"
	@echo "  generate-showcase      - Generate 100 showcase images"
	@echo "  generate-synthetic-session - Generate synthetic session (ARGS='name')"
	@echo "  generate-test-pii      - Generate synthetic PII test data (JSON)"
	@echo "  monitor                - Monitor parallel sage sessions"
	@echo "  promote-images         - Copy showcase images to images/"
	@echo "  sage-commit            - Commit as guile-sage identity (MSG='msg')"
	@echo "  test-guardrails        - Run LiteLLM guardrail policy tests"
	@echo "  timing-bench           - Run per-model timing benchmarks"
	@echo "  eval-provenance        - Eval traffic + validate provenance ledger"
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
	@echo "Tmux:"
	@echo "  tmux-session  - Create/attach dev tmux session (repl + tests + shell)"
	@echo "  tmux-kill     - Kill the dev tmux session"
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
