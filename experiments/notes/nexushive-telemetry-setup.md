# NexusHive Telemetry Setup — Agent Onboarding Guide

> For any Claude Code instance on the LAN_SUBNET LAN.
> Copy the env vars, emit metrics, verify in Prometheus.

## Network

```
LAN_SUBNET LAN (no auth required for OTLP)

nexus  .100   OTel Collector :4317 (gRPC) / :4318 (HTTP)
               Prometheus     :9090 (90d retention)
               Grafana        :3000 (admin:REDACTED)
               skills-hub     :8400 (MCP SSE)
               MQTT           :1883 (aq gossip)
               Ollama         — not on nexus, see mini

mini   .22    Ollama         :11434 (18 models incl. image gen)
               Telegraf       → OTLP to infra-host:4317
               Claude Code    → OTLP to infra-host:4317

hydra  .29    Claude Code    → OTLP to infra-host:4317
               k3s, ArgoCD, sandbox

pi     .248   Embedded sensors
```

## Quick Start (add to ~/.bashrc or ~/.zshrc)

```bash
# === REQUIRED: Enable OTLP telemetry ===
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=http://INFRA_HOST:4317
export OTEL_RESOURCE_ATTRIBUTES="host.name=$(hostname -s),team=aygp-dr"
```

Source the file, then start `claude`. Metrics flow automatically.

## Verify

```bash
# 1. Can we reach the collector?
nc -z INFRA_HOST 4317 && echo "OK" || echo "FAIL"

# 2. After running a Claude session, check Prometheus
curl -s 'http://INFRA_HOST:9090/api/v1/query?query=claude_code_session_count_total' | python3 -m json.tool

# 3. Check all tools currently reporting
curl -s 'http://INFRA_HOST:9090/api/v1/label/exported_job/values' | python3 -m json.tool
# Expected: ["claude-code", "github-copilot"]

# 4. Grafana dashboard
# http://INFRA_HOST:3000/d/claude-sessions/
```

## What Gets Sent

Claude Code emits these metrics automatically (no code needed):

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `claude_code_session_count_total` | counter | session_id | Sessions started |
| `claude_code_token_usage_tokens_total` | counter | model, type (input/output/cacheRead/cacheCreation) | Token counts |
| `claude_code_cost_usage_USD_total` | counter | model | Cost in USD |
| `claude_code_active_time_seconds_total` | counter | type (cli/user) | Active time |
| `claude_code_commit_count_total` | counter | | Git commits |
| `claude_code_pull_request_count_total` | counter | | PRs created |
| `claude_code_lines_of_code_count_total` | counter | type (added/removed) | LOC delta |
| `claude_code_code_edit_tool_decision_total` | counter | tool_name, decision | Edit accept/reject |

### Labels on every metric

| Label | Value | Source |
|-------|-------|--------|
| `exported_job` | `claude-code` | service.name resource attr |
| `otel_scope_name` | `com.anthropic.claude_code` | meter name |
| `otel_scope_version` | `2.1.101` | Claude Code version |
| `session_id` | UUID | per-session |
| `model` | `claude-opus-4-6[1m]` | model in use |
| `user_email` | email | account email |
| `organization_id` | UUID | org |
| `terminal_type` | `xterm-256color` / `ssh-session` | terminal |
| `host_name` | from `OTEL_RESOURCE_ATTRIBUTES` | identifies the machine |

## Privacy Controls

```bash
# These are OFF by default (safe) — only enable for debugging
export OTEL_LOG_USER_PROMPTS=0       # prompt content
export OTEL_LOG_TOOL_DETAILS=0       # tool parameters
export OTEL_LOG_TOOL_CONTENT=0       # tool I/O (traces only)

# These are ON by default — disable to reduce cardinality
export OTEL_METRICS_INCLUDE_SESSION_ID=true
export OTEL_METRICS_INCLUDE_ACCOUNT_UUID=true
```

## Other AI Tools

These also send OTLP to the same collector:

### Gemini CLI (native OTLP)

```bash
export GEMINI_TELEMETRY_ENABLED=1
export GEMINI_TELEMETRY_TARGET=local
export GEMINI_TELEMETRY_OTLP_ENDPOINT=http://INFRA_HOST:4317
export GEMINI_TELEMETRY_OTLP_PROTOCOL=grpc
```

### OpenAI Codex CLI (native OTLP)

Create `~/.codex/config.toml`:
```toml
[otel]
exporter = { otlp-grpc = { endpoint = "http://INFRA_HOST:4317" } }
log_user_prompt = false
```

### GitHub Copilot

Uses Claude Code's OTLP stack — same `OTEL_*` env vars. Shows up as `exported_job="github-copilot"` and `otel_scope_name="github.copilot"`.

### Aider (via LiteLLM proxy)

No native OTLP. Route through LiteLLM proxy:
```bash
pip install 'litellm[proxy]' aider-chat
litellm --config ~/litellm_config.yaml --host 127.0.0.1 --port 4000
export OPENAI_API_BASE=http://localhost:4000
aider
```

## Writing a Custom Agent

Emit metrics from any Python tool:

```python
from opentelemetry import metrics
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.resources import Resource

resource = Resource.create({
    "service.name": "my-custom-agent",    # becomes exported_job label
    "host.name": "hydra",                 # identifies the machine
    "team": "aygp-dr",
})

exporter = OTLPMetricExporter(endpoint="http://INFRA_HOST:4317", insecure=True)
reader = PeriodicExportingMetricReader(exporter, export_interval_millis=60000)
provider = MeterProvider(resource=resource, metric_readers=[reader])
metrics.set_meter_provider(provider)

meter = metrics.get_meter("com.nexushive.my_agent", version="0.1.0")

session_counter = meter.create_counter("my_agent.session.count", description="Sessions")
token_counter = meter.create_counter("my_agent.token.usage", unit="tokens")
cost_counter = meter.create_counter("my_agent.cost.usage", unit="USD")

# Record
session_counter.add(1, {"session_id": "abc-123"})
token_counter.add(1500, {"model": "gpt-4o", "type": "input"})
cost_counter.add(0.03, {"model": "gpt-4o"})

# Flush before exit
provider.force_flush()
provider.shutdown()
```

Install deps: `pip install opentelemetry-api opentelemetry-sdk opentelemetry-exporter-otlp-proto-grpc`

## Metric Naming

OTLP uses dots. Prometheus exporter converts to underscores + suffixes:

| OTLP name | Prometheus name |
|-----------|-----------------|
| `my_agent.session.count` | `my_agent_session_count_total` |
| `my_agent.token.usage` (unit=tokens) | `my_agent_token_usage_tokens_total` |
| `my_agent.cost.usage` (unit=USD) | `my_agent_cost_usage_USD_total` |

## Architecture

```
Any host on LAN_SUBNET
  │
  │ OTEL_EXPORTER_OTLP_ENDPOINT=http://INFRA_HOST:4317
  ▼
OTel Collector (infra-host:4317)
  │ batch (10s / 1024)
  ├─► Prometheus (:8889 exporter → :9090 scrape, 15s interval, 90d retention)
  │     ▼
  │   Grafana (:3000)
  │     ├─ Claude Code — Sessions     /d/claude-sessions/
  │     ├─ AI Tools — Multi-Provider  /d/ai-tools/
  │     ├─ mini — System Health       /d/mini-system/
  │     ├─ Skills Hub — MCP Server    /d/skills-hub/
  │     ├─ nexus — System Health      /d/nexus-system/
  │     ├─ Agents (aq gossip)         /d/agents/
  │     └─ Hydra                      /d/hydra/
  │
  └─► Debug exporter (stdout)
```

## Dashboards

| Dashboard | UID | Active data |
|-----------|-----|-------------|
| Claude Code — Sessions | `claude-sessions` | Yes (4+ sessions, $8+ cost) |
| AI Tools — Multi-Provider | `ai-tools` | Partial (Claude active, others pending) |
| mini — System Health | `mini-system` | Pending Telegraf |
| Skills Hub — MCP Server | `skills-hub` | Yes (35 skills, uptime, auth) |
| nexus — System Health | `nexus-system` | Yes |
| Agents | `agents` | Yes (aq gossip) |
| Hydra | `hydra` | Yes |

## Prometheus Config Reload

No restart needed — hot reload via HTTP:
```bash
curl -X POST http://INFRA_HOST:9090/-/reload
```
