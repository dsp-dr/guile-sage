# sage-theme.tmux - guile-sage tmux theme
# Source this: tmux source-file scripts/sage-theme.tmux

# Sage palette
SAGE_BG="#0a0f0a"
SAGE_FG="#d0d8d0"
SAGE_500="#5a8a5a"
SAGE_700="#3a6a3a"
SAGE_900="#1a4a1a"
SAGE_BRIGHT="#7aaa7a"
SAGE_DIM="#8fb08f"
SAGE_BLUE="#5a7a9a"
SAGE_YELLOW="#9a8a5a"
SAGE_PURPLE="#7a5a9a"

# Status bar
set -g status-style "bg=$SAGE_900,fg=$SAGE_FG"
set -g status-left-length 30
set -g status-right-length 50
set -g status-left "#[bg=$SAGE_500,fg=$SAGE_BG,bold] #S #[bg=$SAGE_900,fg=$SAGE_500]"
set -g status-right "#[fg=$SAGE_DIM]#(whoami)@#H #[fg=$SAGE_500]│ #[fg=$SAGE_BRIGHT]%H:%M "

# Window status
set -g window-status-format " #[fg=$SAGE_DIM]#I:#W "
set -g window-status-current-format "#[bg=$SAGE_500,fg=$SAGE_BG,bold] #I:#W "
set -g window-status-separator ""

# Pane borders
set -g pane-border-style "fg=$SAGE_700"
set -g pane-active-border-style "fg=$SAGE_BRIGHT"

# Messages
set -g message-style "bg=$SAGE_YELLOW,fg=$SAGE_BG"
set -g message-command-style "bg=$SAGE_BLUE,fg=$SAGE_FG"

# Mode (copy mode, etc)
set -g mode-style "bg=$SAGE_500,fg=$SAGE_BG"

# Clock
set -g clock-mode-colour "$SAGE_BRIGHT"
set -g clock-mode-style 24

# Bell
set -g window-status-bell-style "bg=$SAGE_YELLOW,fg=$SAGE_BG,bold"
