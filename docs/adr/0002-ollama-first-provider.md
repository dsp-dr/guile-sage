# ADR-0002: Ollama as Primary Provider

## Status
Accepted

## Context
Need to choose LLM provider(s) for the initial release. Options:
- OpenAI API
- Anthropic API
- Google Gemini API
- Ollama (local + cloud)
- Multi-provider from start

## Decision
Use **Ollama** as the sole provider for v0.1-v0.5, with multi-provider support planned for v0.6.

## Rationale

### Why Ollama First
1. **Local-first**: Can run completely offline on mac.lan
2. **Free for local**: No API costs during development
3. **Cloud option**: Ollama Cloud provides paid scaling path
4. **Simple API**: REST-based, well-documented
5. **Model variety**: Access to qwen3-coder, glm-4.7, llama, etc.
6. **OpenAI-compatible**: Easy to add other providers later

### Why Not Multi-Provider Initially
1. **Complexity**: Each provider has different auth, endpoints, response formats
2. **Testing burden**: Would need to test against multiple APIs
3. **Focus**: Better to do one thing well first
4. **Cost**: Testing against paid APIs adds expense

### Provider Comparison
| Provider   | Local | Free Tier | Tool Calling | Notes               |
|------------|-------|-----------|--------------|---------------------|
| Ollama     | Yes   | Yes       | Via prompts  | Our choice          |
| OpenAI     | No    | No        | Native       | v0.6                |
| Anthropic  | No    | No        | Native       | v0.6                |
| Gemini     | No    | Yes       | Native       | v0.6                |

## Consequences
- Single provider simplifies testing
- Users need Ollama installed (local) or API key (cloud)
- Tool calling uses prompt engineering (not native function calling)
- Provider abstraction layer needed for v0.6

## Migration Path
```
v0.1-v0.5: Ollama only
v0.6+: Add provider abstraction
        - (sage providers base)
        - (sage providers ollama)
        - (sage providers openai)
        - (sage providers anthropic)
```

## References
- [Ollama API](https://github.com/ollama/ollama/blob/main/docs/api.md)
- [Ollama Cloud](https://ollama.com/cloud)
