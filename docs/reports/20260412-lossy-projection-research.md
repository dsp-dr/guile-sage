# Lossy Projections of System State: Research Note

**Date:** 2026-04-12
**Author:** Research survey (staff engineering)
**Scope:** How to keep documentation, test suites, and architecture diagrams accurate as compressed views of a living system

---

## 1. Key Concepts

### 1.1 Architecture Fitness Functions

Fitness functions, from Ford/Parsons/Kua's *Building Evolutionary Architectures*, are objective automated checks that verify an implementation conforms to its stated design. They treat architectural rules as executable code that runs on every build. When a fitness function fails, the build fails, giving immediate feedback that a documented rule has been violated. The 2025-2026 evolution extends these beyond code-structure validation: LLM-based fitness functions can now evaluate softer properties like "do comments explain the why, not the what?" and "does this PR violate ADR-042?" The key insight is that **fitness functions collapse the feedback loop from months (manual review discovers drift) to minutes (CI catches it)**.

guile-sage already has a primitive fitness function in `scripts/doc-check.sh`, which verifies module coverage in ARCHITECTURE.org and CLAUDE.md, checks for hardcoded IPs, validates report naming conventions, and cross-references test files. This is the right pattern; it needs to be extended.

### 1.2 LLM-Based Documentation Drift Detection

Two new tools directly address the doc/code consistency problem:

**driftcheck** (Rust, open-source) is a pre-push git hook that uses LLMs to detect documentation drift. Its pipeline: (1) get the git diff, (2) use an LLM to generate targeted ripgrep queries, (3) search docs in parallel, (4) have the LLM check for contradictions, (5) consult git history to avoid false positives. It is intentionally conservative, flagging only factual errors where documentation explicitly contradicts code. It works with any OpenAI-compatible API, including Ollama.

**dokken** (Python, PyPI) inverts the problem: instead of docs drifting from code, it prevents code from drifting from architectural decisions. During setup, you answer questions about module responsibilities, boundaries, and constraints. These become the baseline. When code crosses those boundaries, dokken catches it in CI. In the era of AI coding assistants, this matters because LLMs can produce technically correct but architecturally wrong changes.

### 1.3 Operationalized ADRs

Architecture Decision Records become living enforcement mechanisms when paired with automated fitness functions. The approach from Castro (2026): let an LLM agent read ADRs directly during PR review, check diffs against the Decision and Consequences sections, and block merges that violate documented decisions. Critical lessons from production use: (a) LLMs naturally rationalize away violations, so prompts must include anti-rationalization instructions; (b) with 20+ ADRs, use summary-first triage to avoid context overload; (c) plan for 5-7 prompt iterations before the system is reliable.

guile-sage has `docs/adr/` but no automated enforcement. The existing `doc-check.sh` pattern could be extended to read ADRs and validate code against them.

### 1.4 Concordance Testing / Doc-as-Test

Rust's doc tests are the gold standard: code examples embedded in documentation comments are compiled and executed as part of the test suite. If the API changes and the example breaks, the test fails. Python's doctest module provides the same for Python. The pattern ensures documentation examples never go stale because they are tests.

guile-sage uses org-mode for documentation. Org-babel's tangling capability could make doc examples executable, but the project does not currently use this. The Scheme ecosystem lacks a doctest equivalent, which is a gap.

### 1.5 Literate Programming Renaissance for LLMs

A 2025 paper (arXiv:2502.17441) introduces Interoperable Literate Programming (ILP), demonstrating that well-structured literate programming documents improve LLM code generation in large-scale projects. The key finding: when documentation includes background reasoning and thought process alongside code, LLMs can "enter the perspective of their past self" and avoid diagnostic loops or scope drift. This is directly relevant to guile-sage, where agents read `docs/` and `CLAUDE.md` before acting -- the quality of those projections determines agent decision quality.

### 1.6 Property-Based Testing for System Invariants

PBT verifies that properties hold across random inputs, making it stronger than example-based tests for catching drift. guile-sage already uses PBT well (40 properties, 4,000 trials in test-pbt.scm). The frontier is **stateful PBT / model-based testing**: instead of testing pure functions, you model the system as a state machine and generate random sequences of operations, checking that invariants hold after every step. Antithesis (funded $105M in 2025) takes this further with deterministic simulation testing, compressing months of production behavior into hours.

### 1.7 Contract Testing for API Boundaries

Pact and PactFlow's new Drift tool verify that API implementations match their specifications. Drift enforces an OpenAPI spec against the running service, catching silent behavioral changes. The pattern applies to guile-sage's Ollama, OpenAI, and Gemini provider interfaces: each provider module makes assumptions about API shape that could drift when upstream APIs change.

### 1.8 Information-Theoretic Perspective

Documentation is lossy compression. The source coding theorem says you cannot compress below entropy without losing information. Applied to documentation: there exists a minimum description length below which an agent cannot reconstruct the system's behavior. Kolmogorov complexity formalizes this as the length of the shortest program that produces the system's behavior as output. The practical implication: when you measure "is this doc good enough?", you are implicitly asking a rate-distortion question -- at this compression ratio, how much distortion (wrong agent decisions) do you accept?

The `doc-check.sh` approach of checking module coverage is a crude proxy for this. A better metric would measure: given only the docs, can an LLM correctly answer questions about the system? The error rate on those questions is the distortion at the current compression ratio.

### 1.9 Diagrams as Code / Single Source of Truth

Structurizr (C4 model as code) and GitOps both embody the principle: eliminate the lossy projection by making the artifact *be* the system state. Structurizr DSL generates diagrams from a model checked into version control -- the model cannot drift from itself. Similarly, Terraform/IaC means the code IS the infrastructure documentation.

guile-sage already generates C4 diagrams from PlantUML in ARCHITECTURE.org. The next step would be generating the PlantUML from code analysis (e.g., scanning `use-modules` declarations to build the dependency graph automatically).

### 1.10 Jepsen: Testing Documentation Claims

Jepsen's methodology is relevant beyond distributed systems: it tests whether a system's documented guarantees actually hold under stress. Jepsen has repeatedly found that documentation claims (consistency levels, isolation guarantees) are wrong. The pattern applies to any system that makes claims in its docs: write tests that verify those claims, especially under adversarial conditions. guile-sage's security tests already do this for sandbox claims; extending this to all documented behaviors would catch more drift.

---

## 2. Approaches Ranked by Applicability to guile-sage

Ranked by (impact on agent correctness) x (feasibility given current infrastructure):

| Rank | Approach | Effort | Impact | Why |
|------|----------|--------|--------|-----|
| 1 | **Extend doc-check.sh to a full fitness function suite** | Low | High | Already have the pattern; add tool count validation, provider list checks, config key verification |
| 2 | **LLM-based drift detection (driftcheck-style)** | Medium | High | Uses Ollama (already a dep); pre-push hook catches contradictions before they reach agents |
| 3 | **Stateful PBT for REPL command sequences** | Medium | High | Already have PBT infra; model the REPL as state machine, generate random /command sequences |
| 4 | **ADR enforcement in CI** | Low | Medium | Already have ADRs; add a check that scans PRs against ADR decisions |
| 5 | **Doc-distortion metric (LLM-based)** | Medium | Medium | Ask LLM questions about the system using only docs, compare answers to code truth |
| 6 | **Auto-generate module dependency diagrams** | Low | Medium | Parse use-modules to produce PlantUML; eliminate manual diagram maintenance |
| 7 | **Executable org-babel doc examples** | Medium | Medium | Make ARCHITECTURE.org code blocks tangleable and testable |
| 8 | **Contract tests for provider APIs** | Medium | Medium | Verify Ollama/OpenAI/Gemini response shapes match documented expectations |
| 9 | **Doc freshness metric** | Low | Low | Track last-modified dates of docs vs related source files; surface staleness |
| 10 | **Full Knuth-style literate programming** | High | Low | Org-babel supports it but migration cost is high and benefits are marginal vs current approach |

---

## 3. Feature Proposals for v0.8.0 Roadmap

### Proposal A: Projection Integrity Test Suite (`gmake check-docs`)

**What:** Extend `scripts/doc-check.sh` into a comprehensive fitness function suite that validates all documented claims against implementation. Beyond current module-coverage checks, add:
- Tool count in CLAUDE.md matches `(length *all-tools*)` from tools.scm
- Provider list in ARCHITECTURE.org matches actual provider modules in `src/sage/`
- Config keys documented in COMMANDS.org match keys accepted by config.scm
- Slash commands in COMMANDS.org match commands registered in repl.scm
- Version string consistency across version.scm, CLAUDE.md, ARCHITECTURE.org
- ADR decisions cross-referenced against code (e.g., "we use curl for HTTP" is still true)

**Why:** This is the highest-ROI change. It turns implicit assumptions into executable tests. Every time a doc claim breaks, an agent would have made a wrong decision.

**Effort:** 2-3 days. Extend existing shell script or port to Guile for tighter integration.

### Proposal B: LLM Drift Detection Pre-Push Hook

**What:** Implement a driftcheck-style pre-push hook adapted for guile-sage. On `git push`:
1. Extract the diff
2. Send diff to local Ollama with prompt: "Generate ripgrep patterns to find documentation that might be affected by these changes"
3. Search `docs/`, `CLAUDE.md`, `AGENTS.md` with those patterns
4. Send matched doc sections + diff to Ollama with prompt: "Does the documentation contradict the code changes? Only flag factual errors."
5. Block push if contradictions found, with explanations

**Why:** This catches the drift that fitness functions miss -- the semantic contradictions that require understanding intent, not just string matching. Using local Ollama keeps it fast and free.

**Effort:** 3-5 days. Could be a shell script calling Ollama's API, fitting the project's curl-based HTTP pattern.

### Proposal C: Stateful PBT for REPL Invariants

**What:** Extend test-pbt.scm with model-based testing for the REPL:
1. Define a state machine model: session state, context window state, tool registry state
2. Define operations: /compact, /session new, /session load, /model switch, /status, chat messages
3. Define invariants: context never exceeds limit, session always serializable, tool count stable across compaction, /status output matches actual state
4. Generate random operation sequences (100+ steps) and verify invariants after each step

**Why:** The REPL is a stateful system with complex interactions between compaction, session persistence, and context tracking. Current PBT tests pure functions. Stateful PBT would catch interaction bugs where documentation claims about behavior (e.g., "auto-compact at 80%") fail under specific operation sequences.

**Effort:** 5-8 days. Requires abstracting REPL operations into callable functions (some refactoring of repl.scm).

---

## 4. Bibliography and Reading List

### Books

- Ford, N., Parsons, R., & Kua, P. (2017). *Building Evolutionary Architectures: Support Constant Change*. O'Reilly. -- Defines fitness functions for architecture governance.
- Knuth, D. E. (1984). "Literate Programming." *The Computer Journal*, 27(2), 97-111. -- The original articulation of code+docs as one artifact.
- Rissanen, J. (2007). *Information and Complexity in Statistical Modeling*. Springer. -- MDL principle applied to model selection; relevant to "minimum useful documentation."
- Lamport, L. (2002). *Specifying Systems: The TLA+ Language and Tools for Hardware and Software Engineers*. Addison-Wesley. -- Formal specification as executable documentation.

### Papers

- Bao, Y., et al. (2025). "Renaissance of Literate Programming in the Era of LLMs: Enhancing LLM-Based Code Generation in Large-Scale Projects." arXiv:2502.17441. -- ILP improves LLM code generation; literate docs as agent context.
- Newcombe, C., et al. (2015). "How Amazon Web Services Uses Formal Methods." *CACM* 58(4). -- TLA+ at scale; specs as documentation that can be model-checked.
- Eick, S. G., et al. (2001). "Does Code Decay? Assessing the Evidence from Change Management Data." *IEEE Trans. Software Engineering* 27(1). -- Empirical evidence of software decay patterns.
- Kingsbury, K. (2020). "Jepsen: Distributed Systems Safety Research." jepsen.io. -- Testing documented consistency claims against reality.

### Tools

- **driftcheck** -- https://github.com/deichrenner/driftcheck -- LLM-based pre-push hook for documentation drift detection. Rust. Supports Ollama.
- **dokken** -- https://pypi.org/project/dokken/ -- Architecture decision enforcement in CI. Python. Prevents code from drifting from documented architectural intent.
- **ArchUnit** -- https://www.archunit.org/ -- Executable architecture rules as unit tests. Java. The gold standard for architecture fitness functions.
- **Structurizr** -- https://structurizr.com/ -- C4 model as code. Diagrams generated from DSL, eliminating diagram drift.
- **PactFlow Drift** -- https://pactflow.io/ -- API specification drift detection. Verifies implementations match OpenAPI specs.
- **Antithesis** -- https://antithesis.com/ -- Deterministic simulation testing. Compresses months of behavior into hours.
- **Hypothesis** -- https://hypothesis.readthedocs.io/ -- Python PBT framework with stateful testing support.

### Articles

- Castro, A. (2026). "Stop Architecture Drift: Operationalizing ADRs with Automated Fitness Functions." dev.to. -- Practical guide to LLM-enforced ADRs with anti-rationalization patterns.
- Niessen, L. (2026). "Fitness Functions: Automating Your Architecture Decisions." Medium. -- Overview including LLM-based fitness criteria.
- "Literate Programming for LLMs." m32.io. -- Documentation as agent context; reasoning preservation across sessions.
- "Version Drift & Doc Chaos in Product Teams." cinfinitysolutions.com. -- Documentation decay patterns and automated pipeline approaches.

### Relevant to guile-sage Specifically

- guile-sage `scripts/doc-check.sh` -- Existing fitness function (module coverage, IP check, naming conventions, version consistency).
- guile-sage `tests/test-pbt.scm` -- Existing PBT infrastructure (40 properties, custom LCG PRNG, 100 trials/property).
- guile-sage `docs/ARCHITECTURE.org` -- C4 diagrams in PlantUML; already "diagrams as code" but manually maintained.
- guile-sage `docs/adr/` -- Architecture decision records present but not enforced.

---

## 5. The Core Tension

Documentation is a lossy projection. The question is not "can we make it lossless?" (we cannot -- the code is the only lossless representation of itself) but "at what compression ratio does the distortion become unacceptable for the agents consuming it?"

The answer depends on the consumer. A human developer tolerates more ambiguity than an LLM agent. An LLM reading CLAUDE.md to decide whether to use `guile3` or `guile` needs that fact to be correct -- one wrong token and it fails. The cost of a wrong doc is proportional to the confidence the consumer places in it multiplied by the cost of the resulting wrong action.

The practical program is therefore:
1. **Enumerate the claims** docs make (fitness functions)
2. **Test the claims** automatically (CI/CD)
3. **Detect new drift** at the point of introduction (pre-push hooks)
4. **Measure the distortion** (LLM-based doc quality metric)
5. **Reduce the projection surface** (generate what you can from code; maintain only what you must write by hand)
