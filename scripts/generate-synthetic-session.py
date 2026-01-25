#!/usr/bin/env python3
"""
Generate synthetic sessions for stress testing.

Usage:
    python3 generate-synthetic-session.py <name> [--source <file-or-url>] [--tokens <count>]

Examples:
    python3 generate-synthetic-session.py guile-manual --source https://www.gnu.org/software/guile/manual/guile.txt
    python3 generate-synthetic-session.py sage-source --source "src/sage/*.scm" --tokens 100000
    python3 generate-synthetic-session.py big-session --tokens 500000
"""

import argparse
import glob
import json
import os
import sys
import time
import urllib.request

def get_session_dir():
    """Get the session directory path."""
    sage_dir = os.environ.get('SAGE_DIR', os.path.expanduser('~/.local/share/sage'))
    project_slug = '-home-dsp-dr-ghq-github.com-dsp-dr-guile-sage'
    session_dir = os.path.join(sage_dir, 'projects', project_slug, 'sessions')
    os.makedirs(session_dir, exist_ok=True)
    return session_dir

def fetch_content(source, target_tokens):
    """Fetch content from URL, file, or generate placeholder."""
    if source and source.startswith(('http://', 'https://')):
        print(f"Fetching from URL: {source}", file=sys.stderr)
        with urllib.request.urlopen(source, timeout=30) as response:
            return response.read().decode('utf-8', errors='replace')
    elif source:
        # Handle glob patterns
        files = glob.glob(source)
        if files:
            print(f"Reading from files: {files}", file=sys.stderr)
            content = []
            for f in files:
                try:
                    with open(f, 'r') as fp:
                        content.append(f"=== {f} ===\n" + fp.read())
                except Exception as e:
                    print(f"Error reading {f}: {e}", file=sys.stderr)
            return '\n\n'.join(content)
        else:
            print(f"No files matching: {source}", file=sys.stderr)
            return generate_placeholder(target_tokens)
    else:
        return generate_placeholder(target_tokens)

def generate_placeholder(target_tokens):
    """Generate placeholder content to hit target tokens."""
    print("Generating placeholder content...", file=sys.stderr)
    chars = target_tokens * 4
    phrase = "The quick brown fox jumps over the lazy dog. "
    repeats = chars // len(phrase) + 1
    return (phrase * repeats)[:chars]

def estimate_tokens(content):
    """Estimate token count (~4 chars per token)."""
    return max(1, len(content) // 4)

def create_session(name, source, target_tokens):
    """Create a synthetic session."""
    session_dir = get_session_dir()
    output = os.path.join(session_dir, f"{name}.json")

    print(f"Generating synthetic session: {name}")
    print(f"Target tokens: {target_tokens}")

    content = fetch_content(source, target_tokens)
    char_count = len(content)
    est_tokens = estimate_tokens(content)

    print(f"Content size: {char_count} chars (~{est_tokens} tokens)")

    # Truncate if needed
    if est_tokens > target_tokens:
        truncate_chars = target_tokens * 4
        content = content[:truncate_chars]
        est_tokens = target_tokens
        print(f"Truncated to {target_tokens} tokens")

    timestamp = str(int(time.time()))

    session = {
        "version": "1.0.0",
        "updated": timestamp,
        "metadata": {
            "name": name,
            "source": source or "placeholder",
            "synthetic": True,
            "created": timestamp
        },
        "stats": {
            "total_tokens": est_tokens + 50,
            "input_tokens": est_tokens,
            "output_tokens": 50,
            "request_count": 1,
            "tool_calls": 0
        },
        "messages": [
            {
                "role": "user",
                "content": f"Reference documentation for context building:\n\n{content}",
                "timestamp": timestamp,
                "tokens": est_tokens
            },
            {
                "role": "assistant",
                "content": "I have read and indexed the reference documentation. This content is now available in my context for answering questions.",
                "timestamp": timestamp,
                "tokens": 25
            }
        ]
    }

    with open(output, 'w') as f:
        json.dump(session, f, indent=2)

    print(f"\nCreated: {output}")
    print(f"Tokens: {session['stats']['total_tokens']}")
    print(f"\nLoad with: /load {name}")
    print("Verify with: /status")

    return output

def main():
    parser = argparse.ArgumentParser(description='Generate synthetic sage sessions')
    parser.add_argument('name', help='Session name')
    parser.add_argument('--source', '-s', help='Source file, glob pattern, or URL')
    parser.add_argument('--tokens', '-t', type=int, default=100000, help='Target token count')

    args = parser.parse_args()
    create_session(args.name, args.source, args.tokens)

if __name__ == '__main__':
    main()
