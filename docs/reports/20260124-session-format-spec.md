# Sage Session Format Specification

**Version:** 1.0.0
**Status:** Draft

## Overview

This document specifies the format for Sage session persistence files.

## Directory Structure

```
$XDG_DATA_HOME/sage/                          # ~/.local/share/sage/
├── projects/
│   └── <project-slug>/                       # URL-safe project path
│       └── sessions/
│           ├── <session-name>.json           # Named sessions
│           └── session-<timestamp>.json      # Auto-saved sessions
└── global/
    └── sessions/                             # Non-project sessions
```

### Project Slug Format

Project paths are converted to URL-safe slugs:
- `/home/user/project` → `-home-user-project`
- Replace `/` with `-`
- Remove leading `-`

## File Format

### Container: JSON (single object)

```json
{
  "version": "1.0.0",
  "updated": "<unix-timestamp>",
  "metadata": { ... },
  "stats": { ... },
  "messages": [ ... ]
}
```

### Alternative: JSONL (streaming)

For very large sessions, a JSONL format may be used:
```jsonl
{"type":"header","version":"1.0.0","created":"1769350031"}
{"type":"message","role":"user","content":"...","timestamp":"...","tokens":100}
{"type":"message","role":"assistant","content":"...","timestamp":"...","tokens":200}
{"type":"stats","total_tokens":300,"input_tokens":100,"output_tokens":200}
```

## Schema Definition

### Root Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| version | string | Yes | Schema version (semver) |
| updated | string | Yes | Unix timestamp of last update |
| metadata | object | No | Session metadata |
| stats | object | Yes | Token and request statistics |
| messages | array | Yes | Conversation messages |

### Metadata Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| name | string | No | Human-readable session name |
| project | string | No | Project path |
| model | string | No | Model used (e.g., "glm-4.7") |
| provider | string | No | Provider (e.g., "ollama") |
| created | string | No | Unix timestamp of creation |
| tags | array | No | User-defined tags |

### Stats Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| total_tokens | integer | Yes | Total tokens (input + output) |
| input_tokens | integer | Yes | User message tokens |
| output_tokens | integer | Yes | Assistant response tokens |
| request_count | integer | Yes | Number of API requests |
| tool_calls | integer | No | Number of tool invocations |
| compaction_count | integer | No | Times session was compacted |

### Message Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| role | string | Yes | "user", "assistant", or "system" |
| content | string | Yes | Message content |
| timestamp | string | Yes | Unix timestamp |
| tokens | integer | Yes | Estimated token count |
| tool_name | string | No | Tool name if tool call |
| tool_result | boolean | No | True if this is a tool result |
| compacted | boolean | No | True if this is a compaction summary |

### Role Values

- `user` - Human input
- `assistant` - LLM response
- `system` - System messages (e.g., compaction summaries)
- `tool` - Tool call/result (deprecated, use tool_name)

## JSON Schema (Draft-07)

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "https://github.com/dsp-dr/guile-sage/session-v1.schema.json",
  "title": "Sage Session",
  "type": "object",
  "required": ["version", "updated", "stats", "messages"],
  "properties": {
    "version": {
      "type": "string",
      "pattern": "^[0-9]+\\.[0-9]+\\.[0-9]+$"
    },
    "updated": {
      "type": "string",
      "pattern": "^[0-9]+$"
    },
    "metadata": {
      "type": "object",
      "properties": {
        "name": { "type": "string" },
        "project": { "type": "string" },
        "model": { "type": "string" },
        "provider": { "type": "string" },
        "created": { "type": "string" },
        "tags": { "type": "array", "items": { "type": "string" } }
      }
    },
    "stats": {
      "type": "object",
      "required": ["total_tokens", "input_tokens", "output_tokens", "request_count"],
      "properties": {
        "total_tokens": { "type": "integer", "minimum": 0 },
        "input_tokens": { "type": "integer", "minimum": 0 },
        "output_tokens": { "type": "integer", "minimum": 0 },
        "request_count": { "type": "integer", "minimum": 0 },
        "tool_calls": { "type": "integer", "minimum": 0 },
        "compaction_count": { "type": "integer", "minimum": 0 }
      }
    },
    "messages": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["role", "content", "timestamp", "tokens"],
        "properties": {
          "role": { "enum": ["user", "assistant", "system", "tool"] },
          "content": { "type": "string" },
          "timestamp": { "type": "string" },
          "tokens": { "type": "integer", "minimum": 0 },
          "tool_name": { "type": "string" },
          "tool_result": { "type": "boolean" },
          "compacted": { "type": "boolean" }
        }
      }
    }
  }
}
```

## Token Estimation

Tokens are estimated using the approximation:
```
tokens ≈ max(1, floor(characters / 4))
```

For precise counting, use the model's tokenizer.

## Compaction

When a session exceeds the token limit:

1. Messages are summarized by the LLM
2. Original messages are replaced with a single `system` message
3. The `compacted` field is set to `true`
4. `stats.compaction_count` is incremented

## Versioning

- **1.0.0** - Initial version (current)
- Future versions will maintain backward compatibility
- Breaking changes require major version bump

## Examples

### Minimal Session

```json
{
  "version": "1.0.0",
  "updated": "1769350031",
  "stats": {
    "total_tokens": 100,
    "input_tokens": 50,
    "output_tokens": 50,
    "request_count": 1
  },
  "messages": [
    {"role": "user", "content": "Hello", "timestamp": "1769350030", "tokens": 1},
    {"role": "assistant", "content": "Hi there!", "timestamp": "1769350031", "tokens": 3}
  ]
}
```

### Session with Tool Use

```json
{
  "version": "1.0.0",
  "updated": "1769350100",
  "stats": {
    "total_tokens": 500,
    "input_tokens": 200,
    "output_tokens": 300,
    "request_count": 2,
    "tool_calls": 1
  },
  "messages": [
    {"role": "user", "content": "Read config.scm", "timestamp": "1769350050", "tokens": 5},
    {"role": "assistant", "content": "```tool\n{\"name\":\"read_file\",...}\n```", "timestamp": "1769350060", "tokens": 50, "tool_name": "read_file"},
    {"role": "user", "content": "Tool result: ...", "timestamp": "1769350061", "tokens": 100, "tool_result": true},
    {"role": "assistant", "content": "The config module...", "timestamp": "1769350100", "tokens": 200}
  ]
}
```

### Compacted Session

```json
{
  "version": "1.0.0",
  "updated": "1769360000",
  "stats": {
    "total_tokens": 50000,
    "input_tokens": 25000,
    "output_tokens": 25000,
    "request_count": 100,
    "compaction_count": 1
  },
  "messages": [
    {
      "role": "system",
      "content": "Summary of previous conversation: The user explored the sage codebase...",
      "timestamp": "1769360000",
      "tokens": 5000,
      "compacted": true
    },
    {"role": "user", "content": "Continue with...", "timestamp": "1769360001", "tokens": 10}
  ]
}
```
