# ADR-0003: Security Model - Safe/Unsafe Tool Separation

## Status
Accepted

## Context
AI assistants can execute arbitrary code and access files. Need security model that:
- Protects users from accidental damage
- Allows power users full access
- Prevents prompt injection attacks
- Blocks access to sensitive files

## Decision
Implement **two-tier permission model** with Safe and Unsafe tool categories, plus YOLO mode override.

## Rationale

### Tool Categories

**Safe Tools** (always allowed):
- `read_file` - Read file contents
- `list_files` - List directory
- `glob_files` - Find files by pattern
- `search_files` - Search content
- `git_status` - View git state
- `git_diff` - View changes
- `git_log` - View history

**Unsafe Tools** (YOLO mode required):
- `write_file` - Create/overwrite files
- `edit_file` - Modify files
- `git_commit` - Make commits
- `eval_scheme` - Execute arbitrary code
- `create_tool` - Add new tools
- `run_tests` - Execute test suite
- `reload_module` - Reload code

### Path Safety
All file operations enforce:
1. **Workspace boundary**: No access outside project directory
2. **Sensitive file blocking**: `.env`, `.git/`, `.ssh/`, `.gnupg/`
3. **Path canonicalization**: Prevent `../` traversal

### YOLO Mode
- Enabled via `-y/--yolo` flag or `SAGE_YOLO_MODE=1`
- Bypasses all permission checks
- For trusted environments only
- Clear warning on startup

## Alternatives Considered

### Per-tool approval prompts
- Pro: Fine-grained control
- Con: Interrupts flow, user fatigue leads to rubber-stamping
- Decision: Rejected for v1, may add in v0.5

### Capability-based security
- Pro: More granular
- Con: Complex to implement
- Decision: Revisit for v1.0

### OS-level sandboxing
- Pro: Strongest isolation
- Con: Platform-specific, complex
- Decision: Out of scope for now

## Consequences
- 34 security tests validate the model
- Users must explicitly opt into YOLO mode
- Safe tools work out-of-box
- Clear documentation of risks

## Test Coverage
```
tests/test-security.scm:
- Path traversal (../, absolute paths)
- Command injection (;, |, $())
- Sensitive file access (.env, .git/)
- Permission bypass attempts
- TOCTOU considerations
```

## References
- OWASP Top 10
- Claude Code permission model
- Gemini CLI safety controls
