#!/bin/bash
# monitor-parallel.sh - Monitor parallel sage sessions

SESSION="sage-parallel"

while true; do
    clear
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           PARALLEL SAGE SESSION MONITOR                          ║"
    echo "║           $(date '+%Y-%m-%d %H:%M:%S')                                      ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    total_tokens=0
    total_messages=0

    for pane in 0 1 2 3; do
        echo "┌─ Pane $pane ──────────────────────────────────────────────────────┐"

        # Get last few lines and extract status
        output=$(tmux capture-pane -t "$SESSION:0.$pane" -p 2>/dev/null)

        # Extract tokens if status line exists
        tokens=$(echo "$output" | grep -o "Tokens: [0-9]*" | tail -1 | grep -o "[0-9]*")
        messages=$(echo "$output" | grep -o "Messages: [0-9]*" | tail -1 | grep -o "[0-9]*")

        if [ -n "$tokens" ]; then
            total_tokens=$((total_tokens + tokens))
            total_messages=$((total_messages + messages))
            echo "│ Tokens: $tokens  Messages: $messages"
        fi

        # Show last response line
        last_line=$(echo "$output" | grep -v "^$" | tail -3 | head -1)
        echo "│ Last: ${last_line:0:60}..."
        echo "└──────────────────────────────────────────────────────────────────┘"
    done

    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo " TOTAL: $total_tokens tokens across $total_messages messages"
    echo "════════════════════════════════════════════════════════════════════"

    sleep 30
done
