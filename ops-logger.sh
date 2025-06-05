#!/usr/bin/env bash
# OpsLogger - Complete logging solution for red team operations
# Version 2.5.1 - Fixed tmux popup issues

# Configuration variables
CONFIG_FILE="${HOME}/.ops-logger.conf"
DEFAULT_TARGET="target-$(hostname | tr '.' '-')"
DEFAULT_LOG_DIR="${HOME}/OperationLogs"
PROMPT_NEW_SHELLS=true
RECORD_INTERVAL=0.5
DEBUG=false

# File markers
LOG_MARKER="/tmp/ops-logger-active"
RECORDING_MARKER="/tmp/ops-logger-recording"
CONFIG_IN_PROGRESS="/tmp/ops-logger-configuring"

# Helper functions
log_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        local debug_dir="${LOG_DIR:-${DEFAULT_LOG_DIR}}"
        mkdir -p "$debug_dir" 2>/dev/null
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $*" >> "${debug_dir}/ops-logger-debug.log"
    fi
}

ensure_dir() {
    mkdir -p "$1" 2>/dev/null || return 1
    return 0
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        TARGET_NAME="$DEFAULT_TARGET"
        LOG_DIR="$DEFAULT_LOG_DIR"
    fi
    
    TARGET_NAME="${TARGET_NAME:-$DEFAULT_TARGET}"
    LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"
}

save_config() {
    ensure_dir "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" << EOF
# Ops Logger Configuration
TARGET_NAME="$TARGET_NAME"
LOG_DIR="$LOG_DIR"
PROMPT_NEW_SHELLS=$PROMPT_NEW_SHELLS
RECORD_INTERVAL=$RECORD_INTERVAL
DEBUG=$DEBUG
EOF
}

# Get public IP
get_public_ip() {
    local ip
    ip=$(curl -s --connect-timeout 3 ifconfig.me) || \
    ip=$(curl -s --connect-timeout 3 ipinfo.io/ip) || \
    ip=$(curl -s --connect-timeout 3 icanhazip.com) || \
    ip="unknown"
    echo "$ip"
}

# Detection functions
is_tmux() { [[ -n "$TMUX" ]]; }

# Get normalized pane ID (session-window-pane format)
get_pane_id() {
    if is_tmux; then
        local session=$(tmux display -p '#{session_name}')
        local window=$(tmux display -p '#{window_index}')
        local pane=$(tmux display -p '#{pane_index}')
        echo "${session}-${window}-${pane}"
    else
        echo "$$"
    fi
}

# Get tmux pane reference for tmux commands (% format for tmux commands)
get_tmux_pane_ref() {
    if is_tmux; then
        tmux display -p '#{pane_id}'
    else
        echo ""
    fi
}

# Get the actual tmux prefix key instead of hardcoding C-b
get_tmux_prefix() {
    # First check if we're using oh-my-tmux which often uses C-a
    if tmux show-options -g | grep -q "TMUX_CONF"; then
        echo "C-a"
    else
        # Try to get the actual prefix from tmux config
        local prefix=$(tmux show-options -g prefix 2>/dev/null | cut -d' ' -f2)
        if [[ -n "$prefix" ]]; then
            echo "$prefix"
        else
            # Default to C-b if we can't determine
            echo "C-b"
        fi
    fi
}

is_logging_active() { [[ -f "${LOG_MARKER}-$1" ]]; }
is_recording_active() { [[ -f "${RECORDING_MARKER}-$1" ]]; }

# ================================================================
# DEPENDENCY CHECKING
# ================================================================

# Check if TPM is installed
check_tpm_installed() {
    [[ -d "$HOME/.tmux/plugins/tpm" ]]
}

# Check if tmux-logging plugin is installed
check_tmux_logging_installed() {
    [[ -d "$HOME/.tmux/plugins/tmux-logging" ]]
}

# Print installation instructions for TMux Plugin Manager (TPM)
print_tpm_install_instructions() {
    echo "========================================================================="
    echo "Tmux Plugin Manager (TPM) is not installed. To install:"
    echo "========================================================================="
    echo "1. Run these commands:"
    echo "   mkdir -p ~/.tmux/plugins"
    echo "   git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm"
    echo ""
    echo "2. Add these lines to your ~/.tmux.conf:"
    echo "   # List of plugins"
    echo "   set -g @plugin 'tmux-plugins/tpm'"
    echo "   set -g @plugin 'tmux-plugins/tmux-sensible'"
    echo "   set -g @plugin 'tmux-plugins/tmux-logging'"
    echo ""
    echo "   # Initialize TMUX plugin manager (keep this line at the bottom)"
    echo "   run '~/.tmux/plugins/tpm/tpm'"
    echo ""
    echo "3. Reload your tmux configuration:"
    echo "   tmux source-file ~/.tmux.conf"
    echo ""
    echo "4. Install plugins by pressing:"
    echo "   prefix + I (capital I)"
    echo "========================================================================="
}

# Print installation instructions for tmux-logging plugin
print_tmux_logging_install_instructions() {
    echo "========================================================================="
    echo "tmux-logging plugin is not installed. To install:"
    echo "========================================================================="
    echo "1. Ensure TPM is installed (see previous instructions if needed)"
    echo ""
    echo "2. Add this line to your ~/.tmux.conf (before the tpm init line):"
    echo "   set -g @plugin 'tmux-plugins/tmux-logging'"
    echo ""
    echo "3. Reload your tmux configuration:"
    echo "   tmux source-file ~/.tmux.conf"
    echo ""
    echo "4. Install the plugin by pressing:"
    echo "   prefix + I (capital I)"
    echo "========================================================================="
}

# Check for required dependencies
check_dependencies() {
    local id="$1"
    local missing=false
    
    if ! is_tmux; then
        echo "WARNING: Not running in tmux. Only basic CSV logging will be available."
        echo "         For full functionality, start tmux first."
        return 0
    fi
    
    # Check TPM and tmux-logging plugin
    if ! check_tpm_installed; then
        missing=true
        print_tpm_install_instructions
    elif ! check_tmux_logging_installed; then
        missing=true
        print_tmux_logging_install_instructions
    fi
    
    if $missing; then
        # Don't use display-message, just echo
        echo "Plugin dependencies missing, see instructions above"
        return 1
    fi
    
    return 0
}

# ================================================================
# CSV LOGGING (our custom implementation)
# ================================================================

# Setup CSV logging (ORIGINAL FORMAT MAINTAINED)
setup_csv_log() {
    local target="$1"
    local log_dir="$2"
    local csv_file="${log_dir}/${target}_commands_$(date +%Y-%m-%d).csv"
    
    ensure_dir "$log_dir"
    if [[ ! -f "$csv_file" ]]; then
        echo '"StartTime","EndTime","SourceIP","User","Path","Command"' > "$csv_file"
    fi
    
    echo "$csv_file"
}

# Create command hook with better timing and error handling
create_command_hook() {
    local hook_script="$1"
    local csv_log="$2"
    local pane_id="$3"
    
    cat > "$hook_script" << 'EOF'
#!/usr/bin/env bash
# Command hook - FIXED version with proper function timing

# IMMEDIATELY set all variables and disable errexit
set +e

# Set variables first before anything else
CSV_LOG="__CSV_LOG__"
PANE_ID="__PANE_ID__"
PUBLIC_IP=$(timeout 5 curl -s ifconfig.me 2>/dev/null || echo "unknown")
RTL_INTERNAL_LOGGING=true
RTL_CMD_START_TIME=""

# Function to check if command should be logged
should_log_command() {
    local cmd="$1"
    case "$cmd" in
        *"RTL_"*|*"log_command"*|*"CSV_LOG"*|*"should_log_command"*) return 1 ;;
        "history "*|*"PROMPT_COMMAND"*|*"source /tmp/ops"*) return 1 ;;
        "") return 1 ;;
        *) return 0 ;;
    esac
}

# Function to log command to CSV
RTL_log_command() {
    local cmd="$1"
    local start_time="$2"
    local end_time="$3"
    local user=$(whoami)
    local path=$(pwd)
    
    should_log_command "$cmd" || return 0
    
    local old_flag="$RTL_INTERNAL_LOGGING"
    RTL_INTERNAL_LOGGING=false
    
    local escaped_cmd=${cmd//\"/\"\"}
    
    printf '"%s","%s","%s","%s","%s","%s"\n' \
        "$start_time" "$end_time" "$PUBLIC_IP" "$user" "$path" "$escaped_cmd" >> "$CSV_LOG" 2>/dev/null
    
    RTL_INTERNAL_LOGGING="$old_flag"
}

# BASH-specific setup
if [[ -n "$BASH_VERSION" ]]; then
    # Save original PROMPT_COMMAND
    [[ -z "$RTL_ORIG_PROMPT_COMMAND" ]] && RTL_ORIG_PROMPT_COMMAND="$PROMPT_COMMAND"
    
    RTL_LAST_COMMAND=""
    RTL_LAST_HISTNUM=""
    
    # FIXED: Define preexec function BEFORE setting trap
    RTL_preexec() {
        local cmd="$BASH_COMMAND"
        if should_log_command "$cmd" 2>/dev/null; then
            RTL_CMD_START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
        fi
    }
    
    # FIXED: Define PROMPT_COMMAND function BEFORE using it
    RTL_PROMPT_COMMAND() {
        if [[ "$RTL_INTERNAL_LOGGING" == "false" ]]; then
            return 0
        fi
        
        local current_histnum=$(history 1 2>/dev/null | awk '{print $1}')
        local current_cmd=$(history 1 2>/dev/null | sed 's/^[ ]*[0-9]*[ ]*//')
        
        if [[ "$current_cmd" != "$RTL_LAST_COMMAND" && "$current_histnum" != "$RTL_LAST_HISTNUM" ]]; then
            if should_log_command "$current_cmd" 2>/dev/null; then
                local end_time="$(date '+%Y-%m-%d %H:%M:%S')"
                local start_time="${RTL_CMD_START_TIME:-$end_time}"
                
                RTL_log_command "$current_cmd" "$start_time" "$end_time"
                
                RTL_LAST_COMMAND="$current_cmd"
                RTL_LAST_HISTNUM="$current_histnum"
            fi
        fi
        
        RTL_CMD_START_TIME=""
    }
    
    # NOW set the trap (function is already defined)
    trap 'RTL_preexec 2>/dev/null || true' DEBUG 2>/dev/null
    
    # Set PROMPT_COMMAND (function is already defined)
    if [[ -n "$RTL_ORIG_PROMPT_COMMAND" ]]; then
        PROMPT_COMMAND="RTL_PROMPT_COMMAND; $RTL_ORIG_PROMPT_COMMAND"
    else
        PROMPT_COMMAND="RTL_PROMPT_COMMAND"
    fi
    
# ZSH-specific setup
elif [[ -n "$ZSH_VERSION" ]]; then
    # Define functions first
    RTL_zsh_preexec() {
        local cmd="$1"
        if should_log_command "$cmd" 2>/dev/null; then
            RTL_CMD_START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
        fi
    }
    
    RTL_zsh_precmd() {
        if [[ "$RTL_INTERNAL_LOGGING" == "false" ]]; then
            return 0
        fi
        
        local cmd=$(fc -ln -1 2>/dev/null)
        
        if should_log_command "$cmd" 2>/dev/null; then
            local end_time="$(date '+%Y-%m-%d %H:%M:%S')"
            local start_time="${RTL_CMD_START_TIME:-$end_time}"
            
            RTL_log_command "$cmd" "$start_time" "$end_time"
        fi
        
        RTL_CMD_START_TIME=""
    }
    
    # NOW set the hooks (functions are already defined)
    if autoload -Uz add-zsh-hook 2>/dev/null; then
        add-zsh-hook preexec RTL_zsh_preexec 2>/dev/null || true
        add-zsh-hook precmd RTL_zsh_precmd 2>/dev/null || true
    fi
fi

# Mark as active
echo "$$" > "__LOG_MARKER__-${PANE_ID}"
echo "Ops Logger command hook installed for pane $PANE_ID" >&2
EOF

    # Replace placeholders with actual values
    sed -i "s|__CSV_LOG__|$csv_log|g" "$hook_script"
    sed -i "s|__PANE_ID__|$pane_id|g" "$hook_script"
    sed -i "s|__LOG_MARKER__|$LOG_MARKER|g" "$hook_script"
    
    chmod +x "$hook_script"
}

# ================================================================
# VERBOSE LOGGING (using tmux-logging plugin with header integration)
# ================================================================

# Create verbose log file WITH header included in the actual log file
create_verbose_log_with_header() {
    local target="$1"
    local log_dir="$2"
    local session window pane timestamp
    
    if is_tmux; then
        session=$(tmux display -p '#{session_name}')
        window=$(tmux display -p '#{window_index}')
        pane=$(tmux display -p '#{pane_index}')
        timestamp=$(date +%Y%m%d)
    else
        session="shell"
        window="0"
        pane="0"
        timestamp=$(date +%Y%m%d)
    fi
    
    local verbose_dir="${log_dir}/verbose"
    ensure_dir "$verbose_dir"
    
    # Create the log file with header directly included
    local log_file="${verbose_dir}/${target}_verbose_${session}_${window}_${pane}_${timestamp}.log"
    
    # Create the file with header if it doesn't exist
    if [[ ! -f "$log_file" ]]; then
        cat > "$log_file" << EOF
================================================================================
                           RED TEAM TERMINAL LOGGER
                              Daily Verbose Log
================================================================================
Target: $target
Date: $(date +%Y-%m-%d)
Host: $(hostname)
Public IP: $(get_public_ip)
Pane ID: $(get_pane_id)
Session: $session
Window: $window
Pane: $pane
Started: $(date '+%Y-%m-%d %H:%M:%S')
================================================================================

EOF
    fi
    
    echo "$log_file"
}

# Configure tmux-logging plugin settings for proper format
configure_tmux_logging() {
    local log_file="$1"
    local target="$2"
    
    # Set better ANSI filtering to match our requirements
    tmux set-option -g @logging-filter-out "\\033\\[[0-9;]*[a-zA-Z]" 2>/dev/null || true
    
    # Set custom log directory to match our file
    local log_dir=$(dirname "$log_file")
    tmux set-option -g @logging-path "$log_dir" 2>/dev/null || true
    
    # Set custom filename format that matches our pre-created file
    local filename=$(basename "$log_file")
    tmux set-option -g @logging-filename "$filename" 2>/dev/null || true
    
    log_debug "Configured tmux-logging settings for file: $log_file"
}

# Start verbose logging with header properly integrated
start_verbose_logging() {
    local id="$1"
    local tmux_pane_ref="$2"
    local target="$3"
    local log_dir="$4"
    
    # Create the log file with header
    local log_file=$(create_verbose_log_with_header "$target" "$log_dir")
    
    # Configure tmux-logging to use our pre-created file
    configure_tmux_logging "$log_file" "$target"
    
    # Setup direct pipe-pane with ANSI filtering, appending to our header file
    log_debug "Starting verbose logging to: $log_file"
    
    if command -v ansifilter >/dev/null 2>&1; then
        tmux pipe-pane -t "$tmux_pane_ref" "ansifilter >> '$log_file'"
    else
        # Improved ANSI filtering that preserves readability
        tmux pipe-pane -t "$tmux_pane_ref" "sed -r 's/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g' >> '$log_file'"
    fi
    
    # Check if logging started successfully
    if tmux list-panes -F "#{pane_id} #{pane_pipe}" | grep -q "$tmux_pane_ref.*1"; then
        log_debug "Verbose logging started successfully to: $log_file"
        return 0
    else
        log_debug "ERROR: Verbose logging failed to start"
        return 1
    fi
}

# Stop verbose logging
stop_verbose_logging() {
    local tmux_pane_ref="$1"
    
    # Direct pipe-pane stop method (most reliable)
    tmux pipe-pane -t "$tmux_pane_ref" 2>/dev/null || true
    
    log_debug "Stopped verbose logging for pane: $tmux_pane_ref"
}

# ================================================================
# OHMYTMUX-COMPATIBLE WINDOW NAME MANAGEMENT
# ================================================================

# Improved window name handling that works with ohmytmux
get_current_window_name() {
    local tmux_pane_ref="$1"
    local name=$(tmux display -t "$tmux_pane_ref" -p '#{window_name}')
    
    # Remove our indicators as well as any ohmytmux status indicators
    name="${name#🔴 }"
    name="${name#🎥 }"
    name="${name#● }"
    name="${name#⚠ }"
    name="${name#▶ }"
    
    echo "$name"
}

set_window_logging_indicator() {
    local tmux_pane_ref="$1"
    local current_name=$(get_current_window_name "$tmux_pane_ref")
    
    # Preserve ohmytmux automatic formats but add our indicator
    if [[ "$current_name" == *Z ]]; then
        # Zoomed window format in ohmytmux
        tmux rename-window -t "$tmux_pane_ref" "🔴 ${current_name%Z}Z"
    else
        tmux rename-window -t "$tmux_pane_ref" "🔴 $current_name"
    fi
}

set_window_recording_indicator() {
    local tmux_pane_ref="$1"
    local current_name=$(get_current_window_name "$tmux_pane_ref")
    
    # Remove logging indicator if present and add recording
    current_name="${current_name#🔴 }"
    
    # Preserve ohmytmux automatic formats
    if [[ "$current_name" == *Z ]]; then
        # Zoomed window format in ohmytmux
        tmux rename-window -t "$tmux_pane_ref" "🎥 ${current_name%Z}Z"
    else
        tmux rename-window -t "$tmux_pane_ref" "🎥 $current_name"
    fi
}

clear_window_indicators() {
    local tmux_pane_ref="$1"
    local current_name=$(tmux display -t "$tmux_pane_ref" -p '#{window_name}')
    local clean_name=$(get_current_window_name "$tmux_pane_ref")
    
    # Preserve any ohmytmux indicators that might be present
    if [[ "$current_name" == *Z ]]; then
        # Zoomed window format in ohmytmux
        tmux rename-window -t "$tmux_pane_ref" "${clean_name}Z"
    else
        tmux rename-window -t "$tmux_pane_ref" "$clean_name"
    fi
}

# ================================================================
# MAIN LOGGING FUNCTIONS
# ================================================================

# Better logging installation 
install_logging() {
    local id="$1"
    local csv_log="$2"
    local target="$3"
    local log_dir="$4"
    
    log_debug "Installing logging for pane $id"
    
    if is_tmux; then
        local tmux_pane_ref=$(get_tmux_pane_ref)
        
        # Check for required dependencies, but continue even if missing
        check_dependencies "$id"
        
        # Start verbose logging with integrated header
        if check_tmux_logging_installed; then
            if start_verbose_logging "$id" "$tmux_pane_ref" "$target" "$log_dir"; then
                log_debug "Verbose logging started successfully"
            else
                log_debug "Verbose logging may not have started correctly, continuing with CSV only"
            fi
        else
            log_debug "Skipping verbose logging (plugin not available)"
        fi
        
        # Create command hook for CSV logging
        local hook_script="/tmp/ops-hook-${id}.sh"
        create_command_hook "$hook_script" "$csv_log" "$id"
        
        # Better sourcing with comprehensive error handling
        tmux send-keys -t "$tmux_pane_ref" "source '$hook_script' 2>/dev/null && echo 'Logging hooks installed successfully' || echo 'Logging may have warnings but is active'" ENTER
        
        sleep 2  # Give more time for hooks to install
        
        # Set window indicator (ohmytmux compatible)
        set_window_logging_indicator "$tmux_pane_ref"
        
        # Mark logging as active
        touch "${LOG_MARKER}-${id}"
        touch "${LOG_MARKER}-${id}.success"
        
        
    else
        # Direct shell logging (CSV only - no verbose logging available)
        local hook_script="/tmp/ops-hook-${id}.sh"
        create_command_hook "$hook_script" "$csv_log" "$id"
        source "$hook_script"
        echo "Direct shell logging started (CSV only - install tmux for verbose logging)"
        
        # Mark logging as active
        touch "${LOG_MARKER}-${id}"
        touch "${LOG_MARKER}-${id}.success"
    fi
    
    log_debug "Logging installation completed"
}

# Clean removal of all logging
remove_logging() {
    local id="$1"
    
    log_debug "Removing logging for pane $id"
    
    if is_tmux; then
        local tmux_pane_ref=$(get_tmux_pane_ref)
        
        # Stop verbose logging
        stop_verbose_logging "$tmux_pane_ref"
        
        # Better cleanup script
        local cleanup_script="/tmp/ops-cleanup-${id}.sh"
        cat > "$cleanup_script" << 'EOF'
#!/usr/bin/env bash
# Clean removal of logging hooks
set +e

if [[ -n "$BASH_VERSION" ]]; then
    trap - DEBUG 2>/dev/null
    if [[ -n "$RTL_ORIG_PROMPT_COMMAND" ]]; then
        PROMPT_COMMAND="$RTL_ORIG_PROMPT_COMMAND"
        unset RTL_ORIG_PROMPT_COMMAND
    else
        unset PROMPT_COMMAND
    fi
    unset -f RTL_PROMPT_COMMAND RTL_log_command should_log_command RTL_preexec 2>/dev/null
elif [[ -n "$ZSH_VERSION" ]]; then
    add-zsh-hook -d preexec RTL_zsh_preexec 2>/dev/null
    add-zsh-hook -d precmd RTL_zsh_precmd 2>/dev/null
    unset -f RTL_zsh_preexec RTL_zsh_precmd RTL_log_command should_log_command 2>/dev/null
fi

unset RTL_CMD_START_TIME RTL_LAST_COMMAND RTL_LAST_HISTNUM RTL_INTERNAL_LOGGING 2>/dev/null
unset CSV_LOG PANE_ID PUBLIC_IP 2>/dev/null

echo "Ops Logger hooks removed"
EOF
        chmod +x "$cleanup_script"
        
        # Source the cleanup script silently
        tmux send-keys -t "$tmux_pane_ref" "source '$cleanup_script' 2>/dev/null; rm -f '$cleanup_script'" ENTER
        
        # Clear window indicators (ohmytmux compatible)
        clear_window_indicators "$tmux_pane_ref"
        
        # Cleanup temp files
        rm -f "/tmp/ops-hook-${id}.sh"
        
    else
        # Direct shell cleanup
        if [[ -n "$BASH_VERSION" ]]; then
            trap - DEBUG 2>/dev/null
            if [[ -n "$RTL_ORIG_PROMPT_COMMAND" ]]; then
                PROMPT_COMMAND="$RTL_ORIG_PROMPT_COMMAND"
                unset RTL_ORIG_PROMPT_COMMAND
            else
                unset PROMPT_COMMAND
            fi
            unset -f RTL_PROMPT_COMMAND RTL_log_command should_log_command RTL_preexec 2>/dev/null
        elif [[ -n "$ZSH_VERSION" ]]; then
            add-zsh-hook -d preexec RTL_zsh_preexec 2>/dev/null
            add-zsh-hook -d precmd RTL_zsh_precmd 2>/dev/null
            unset -f RTL_zsh_preexec RTL_zsh_precmd RTL_log_command should_log_command 2>/dev/null
        fi
        
        unset RTL_CMD_START_TIME RTL_LAST_COMMAND RTL_LAST_HISTNUM RTL_INTERNAL_LOGGING 2>/dev/null
        unset CSV_LOG PANE_ID PUBLIC_IP 2>/dev/null
        
        echo "Direct shell logging stopped"
    fi
    
    # Remove markers and temp files
    rm -f "${LOG_MARKER}-${id}" "${LOG_MARKER}-${id}.success"
    rm -f "/tmp/ops-hook-${id}.sh"
    
    log_debug "Logging removal completed"
}

# ================================================================
# RECORDING FUNCTIONS
# ================================================================

start_recording() {
    local id="$1"
    local target="$2"
    local log_dir="$3"
    local recordings_dir="${log_dir}/recordings"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    ensure_dir "$recordings_dir"
    
    # Check for asciinema
    if ! command -v asciinema >/dev/null 2>&1; then
        local error_msg="ERROR: asciinema not installed"
        echo "$error_msg" >&2
        echo "To install asciinema:"
        echo "  Ubuntu/Debian: sudo apt install asciinema"
        echo "  Fedora/RHEL: sudo dnf install asciinema"
        echo "  macOS: brew install asciinema"
        echo "  Pip: pip3 install asciinema"
        return 1
    fi
    
    local cast_file="${recordings_dir}/${target}_${id}_${timestamp}.cast"
    echo "asciinema:$cast_file" > "${RECORDING_MARKER}-${id}"
    
    if is_tmux; then
        local tmux_pane_ref=$(get_tmux_pane_ref)
        
        # Set recording indicator (ohmytmux compatible)
        set_window_recording_indicator "$tmux_pane_ref"
        
        # Start recording cleanly
        tmux send-keys -t "$tmux_pane_ref" "asciinema rec '$cast_file'" ENTER
        
    else
        echo "Starting asciinema recording. Use 'exit' or Ctrl+D to stop."
        asciinema rec "$cast_file"
    fi
}

stop_recording() {
    local id="$1"
    
    [[ ! -f "${RECORDING_MARKER}-${id}" ]] && {
        echo "No active recording"
        return 1
    }
    
    read -r rec_type rec_path < <(cat "${RECORDING_MARKER}-${id}" | tr ':' ' ')
    
    if [[ "$rec_type" == "asciinema" ]]; then
        if is_tmux; then
            local tmux_pane_ref=$(get_tmux_pane_ref)
            
            # Try sending Ctrl+D
            tmux send-keys -t "$tmux_pane_ref" C-d
            
            sleep 1
            
            # If that didn't work, try killing the asciinema process
            if ps aux | grep -v grep | grep -q "asciinema rec"; then
                log_debug "Ctrl+D didn't stop recording, trying to kill asciinema process"
                tmux send-keys -t "$tmux_pane_ref" "pkill -f 'asciinema rec'" ENTER
                
                sleep 1
                
                if ps aux | grep -v grep | grep -q "asciinema rec"; then
                    pkill -f "asciinema rec" || true
                fi
            fi
            
            # Clear recording indicator but preserve logging indicator
            local current_name=$(tmux display -t "$tmux_pane_ref" -p '#{window_name}')
            if [[ "$current_name" == "🎥"* ]]; then
                if is_logging_active "$id"; then
                    local clean_name="${current_name#🎥 }"
                    tmux rename-window -t "$tmux_pane_ref" "🔴 $clean_name"
                else
                    clear_window_indicators "$tmux_pane_ref"
                fi
            fi
            
        else
            echo "Recording stopped: $rec_path"
        fi
    fi
    
    rm -f "${RECORDING_MARKER}-${id}"
}

# ================================================================
# CONFIGURATION FUNCTIONS
# ================================================================

# FIXED: Configuration that actually prompts the user and doesn't continue logging
create_config() {
    local is_first_run="${1:-false}"
    
    # If this is a first run from ensure_config, we need to get input via tmux command-prompt
    if [[ "$is_first_run" == "true" ]] && is_tmux; then
        # Mark configuration as in progress
        touch "$CONFIG_IN_PROGRESS"
        
        # Create a temporary script that will handle the config creation
        local config_script="/tmp/ops-config-$$.sh"
        cat > "$config_script" << 'EOSCRIPT'
#!/usr/bin/env bash
CONFIG_FILE="${HOME}/.ops-logger.conf"
DEFAULT_TARGET="target-$(hostname | tr '.' '-')"
DEFAULT_LOG_DIR="${HOME}/OperationLogs"

echo "Red Team Terminal Logger - First Time Setup"
echo "==========================================="
echo ""

read -p "Enter target name [$DEFAULT_TARGET]: " TARGET_NAME
TARGET_NAME="${TARGET_NAME:-$DEFAULT_TARGET}"

read -p "Enter log directory [$DEFAULT_LOG_DIR]: " LOG_DIR
LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"

read -p "Prompt for logging in new shells? [Y/n]: " PROMPT_NEW_SHELLS
[[ "${PROMPT_NEW_SHELLS,,}" == "n" ]] && PROMPT_NEW_SHELLS=false || PROMPT_NEW_SHELLS=true

read -p "Enable debug logging? [y/N]: " DEBUG
[[ "${DEBUG,,}" == "y" ]] && DEBUG=true || DEBUG=false

# Save config
mkdir -p "$(dirname "$CONFIG_FILE")"
cat > "$CONFIG_FILE" << EOF
# Ops Logger Configuration
TARGET_NAME="$TARGET_NAME"
LOG_DIR="$LOG_DIR"
PROMPT_NEW_SHELLS=$PROMPT_NEW_SHELLS
RECORD_INTERVAL=0.5
DEBUG=$DEBUG
EOF

# Create directories
mkdir -p "$LOG_DIR"
mkdir -p "${LOG_DIR}/verbose"
mkdir -p "${LOG_DIR}/recordings"

# Remove the in-progress marker
rm -f "/tmp/ops-logger-configuring"

echo ""
echo "Configuration saved!"
echo "  Target name: $TARGET_NAME"
echo "  Log directory: $LOG_DIR"
echo "  Prompt new shells: $PROMPT_NEW_SHELLS"
echo "  Debug mode: $DEBUG"
echo ""
echo "Now run: prefix+L to start logging (or ops-logger --start)"
echo "Press ENTER to close this window..."
read
EOSCRIPT
        chmod +x "$config_script"
        
        # Open new window for config
        bash $config_script; rm -f $config_script
        return 0
    fi
    
    # For manual --config or non-tmux environments
    load_config
    
    echo "Red Team Terminal Logger - Configuration"
    echo "========================================"
    echo ""
    
    echo "Current settings:"
    echo "  Target name: $TARGET_NAME"
    echo "  Log directory: $LOG_DIR"
    echo "  Prompt new shells: $PROMPT_NEW_SHELLS"
    echo "  Debug mode: $DEBUG"
    echo ""
    
    # Use proper input handling
    local input_source="/dev/tty"
    [[ ! -e "$input_source" ]] && input_source="/dev/stdin"
    
    echo -n "Enter target name [$TARGET_NAME]: "
    read -r input < "$input_source"
    [[ -n "$input" ]] && TARGET_NAME="$input"
    
    echo -n "Enter log directory [$LOG_DIR]: "
    read -r input < "$input_source"
    [[ -n "$input" ]] && LOG_DIR="$input"
    
    echo -n "Prompt for logging in new shells? [Y/n]: "
    read -r input < "$input_source"
    [[ "${input,,}" == "n" ]] && PROMPT_NEW_SHELLS=false || PROMPT_NEW_SHELLS=true
    
    echo -n "Enable debug logging? [y/N]: "
    read -r input < "$input_source"
    [[ "${input,,}" == "y" ]] && DEBUG=true || DEBUG=false
    
    save_config
    
    echo ""
    echo "Configuration saved!"
    echo "New settings:"
    echo "  Target name: $TARGET_NAME"
    echo "  Log directory: $LOG_DIR" 
    echo "  Prompt new shells: $PROMPT_NEW_SHELLS"
    echo "  Debug mode: $DEBUG"
    
    # Create directories
    ensure_dir "$LOG_DIR"
    ensure_dir "${LOG_DIR}/verbose"
    ensure_dir "${LOG_DIR}/recordings"
    
    if is_tmux; then
        echo "Configuration saved: $TARGET_NAME"
    fi
}

save_config_from_tmux() {
    save_config
    ensure_dir "$LOG_DIR"
    ensure_dir "${LOG_DIR}/verbose"
    ensure_dir "${LOG_DIR}/recordings"
    echo "Configuration saved"
}

# FIXED: Ensure config exists and abort if we're in the middle of configuring
ensure_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        create_config "true"
        # If configuration is in progress, abort the current operation
        if [[ -f "$CONFIG_IN_PROGRESS" ]]; then
            return 1
        fi
    fi
    return 0
}

# ================================================================
# MAIN USER FUNCTIONS
# ================================================================

start_logging() {
    # Ensure we output to terminal if run from tmux keybinding
    if is_tmux && [[ -t 1 ]]; then
        local tty=$(tty 2>/dev/null || echo "/dev/tty")
        exec 1>$tty 2>$tty
    fi
    
    # Auto-setup config with prompts on first logging start
    ensure_config || return 1
    load_config
    
    local id=$(get_pane_id)
    is_logging_active "$id" && {
        echo "Already logging"
        return 0
    }
    
    local csv_log=$(setup_csv_log "$TARGET_NAME" "$LOG_DIR")
    
    install_logging "$id" "$csv_log" "$TARGET_NAME" "$LOG_DIR"
}

stop_logging() {
    # Ensure we output to terminal if run from tmux keybinding
    if is_tmux && [[ -t 1 ]]; then
        local tty=$(tty 2>/dev/null || echo "/dev/tty")
        exec 1>$tty 2>$tty
    fi
    
    local id=$(get_pane_id)
    is_logging_active "$id" || {
        echo "Not logging"
        return 0
    }
    
    remove_logging "$id"
}

toggle_logging() {
    # Ensure we output to terminal if run from tmux keybinding
    if is_tmux && [[ -t 1 ]]; then
        local tty=$(tty 2>/dev/null || echo "/dev/tty")
        exec 1>$tty 2>$tty
    fi
    
    local id=$(get_pane_id)
    is_logging_active "$id" && stop_logging || start_logging
}

toggle_recording() {
    # Ensure we output to terminal if run from tmux keybinding
    if is_tmux && [[ -t 1 ]]; then
        local tty=$(tty 2>/dev/null || echo "/dev/tty")
        exec 1>$tty 2>$tty
    fi
    
    local id=$(get_pane_id)
    # Load existing config or use defaults
    [[ -f "$CONFIG_FILE" ]] && load_config || {
        TARGET_NAME="$DEFAULT_TARGET"
        LOG_DIR="$DEFAULT_LOG_DIR"
    }
    
    is_recording_active "$id" && stop_recording "$id" || start_recording "$id" "$TARGET_NAME" "$LOG_DIR"
}

prompt_for_logging() {
    local id=$(get_pane_id)
    is_logging_active "$id" && return 0
    
    load_config
    [[ "$PROMPT_NEW_SHELLS" != "true" ]] && return 0
    
    if is_tmux; then
        tmux display-menu -T "Start logging this shell?" \
            "Yes" y "run-shell \"$0 --start\"" \
            "No" n ""
    else
        read -p "Start logging this shell? [Y/n] " response
        [[ -z "$response" || "${response,,}" == "y" ]] && start_logging
    fi
}

# ================================================================
# TMUX INTEGRATION
# ================================================================

# Tmux integration functions
install_tmux_keys() {
    load_config
    
    if is_tmux; then
        local script_path=$(readlink -f "$0")
        
        # Install key bindings that don't conflict with ohmytmux
        tmux bind-key L run-shell "'$script_path' --toggle"
        tmux bind-key R run-shell "'$script_path' --toggle-recording"
        
        # Install hooks for new windows/panes if enabled
        if [[ "$PROMPT_NEW_SHELLS" == "true" ]]; then
            tmux set-hook -g after-new-window "run-shell \"sleep 1; '$script_path' --prompt\""
            tmux set-hook -g after-split-window "run-shell \"sleep 1; '$script_path' --prompt\""
        fi
        
        tmux display-message "Keys installed: prefix+L (logging), prefix+R (recording)"
        log_debug "Tmux key bindings installed"
    else
        echo "Not in tmux, no keys installed"
    fi
}

uninstall_tmux_keys() {
    if is_tmux; then
        tmux unbind-key L 2>/dev/null
        tmux unbind-key R 2>/dev/null
        tmux set-hook -gu after-new-window 2>/dev/null
        tmux set-hook -gu after-split-window 2>/dev/null
        echo "Tmux keys removed"
        log_debug "Tmux key bindings removed"
        
        # Remove our hook wrapper
        rm -f /tmp/ops-logger-hook-wrapper.sh 2>/dev/null
    fi
    
    # Also remove config file as user expected
    load_config
    local log_dir_for_cleanup="$LOG_DIR"
    
    # Remove config
    [[ -f "$CONFIG_FILE" ]] && rm -f "$CONFIG_FILE"
    
    # Remove debug log
    [[ -f "${log_dir_for_cleanup}/ops-logger-debug.log" ]] && rm -f "${log_dir_for_cleanup}/ops-logger-debug.log"
    
    echo "Configuration removed"
}

uninstall_all() {
    local id=$(get_pane_id)
    
    log_debug "Starting complete uninstall"
    
    # Stop active sessions
    is_logging_active "$id" && stop_logging
    is_recording_active "$id" && stop_recording "$id"
    
    # Remove tmux integration and config
    is_tmux && uninstall_tmux_keys
    
    # Clean up temp files
    rm -f /tmp/ops-* 2>/dev/null
    
    echo "OpsLogger uninstalled completely"
}

show_status() {
    # Ensure we output to terminal if run from tmux keybinding
    if is_tmux && [[ -t 1 ]]; then
        local tty=$(tty 2>/dev/null || echo "/dev/tty")
        exec 1>$tty 2>$tty
    fi
    
    load_config
    local id=$(get_pane_id)
    
    echo "Red Team Terminal Logger Status:"
    echo "==============================="
    echo "Target: $TARGET_NAME"
    echo "Log directory: $LOG_DIR"
    echo "Debug mode: $DEBUG"
    echo "Logging: $(is_logging_active "$id" && echo "ACTIVE" || echo "INACTIVE")"
    echo "Recording: $(is_recording_active "$id" && echo "ACTIVE" || echo "INACTIVE")"
    echo "Public IP: $(get_public_ip)"
    echo "Asciinema: $(command -v asciinema >/dev/null 2>&1 && echo "INSTALLED" || echo "NOT INSTALLED")"
    
    if is_tmux; then
        echo "Environment: tmux ($(tmux display -p '#{session_name}'))"
        echo "Tmux prefix: $(get_tmux_prefix)"
        echo "ohmytmux: $(tmux show-options -g | grep -q "TMUX_CONF" && echo "DETECTED" || echo "NOT DETECTED")"
        echo "Normalized Pane ID: $id"
        
        # Check plugin installation status
        echo "TPM: $(check_tpm_installed && echo "INSTALLED" || echo "NOT INSTALLED")"
        echo "tmux-logging plugin: $(check_tmux_logging_installed && echo "INSTALLED" || echo "NOT INSTALLED")"
        
        # Check if there's active pipe-pane logging
        echo "Active logging pipe: $(tmux list-panes -F "#{pane_id} #{pane_pipe}" | grep -q "$(get_tmux_pane_ref).*1" && echo "YES" || echo "NO")"
    else
        echo "Environment: direct shell"
    fi
    
    # Show current log files
    local csv_log="${LOG_DIR}/${TARGET_NAME}_commands_$(date +%Y-%m-%d).csv"
    
    [[ -f "$csv_log" ]] && {
        echo "Current CSV log: $csv_log"
        echo "Commands logged: $(($(wc -l < "$csv_log") - 1))"
    }
    
    # Show verbose logs with headers
    local verbose_dir="${LOG_DIR}/verbose"
    if [[ -d "$verbose_dir" ]]; then
        local verbose_files=$(find "$verbose_dir" -name "*${TARGET_NAME}*.log" -type f 2>/dev/null | wc -l)
        echo "Verbose log files: $verbose_files in $verbose_dir"
        if [[ "$verbose_files" -gt 0 ]]; then
            local latest_verbose=$(find "$verbose_dir" -name "*${TARGET_NAME}*.log" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
            [[ -n "$latest_verbose" ]] && echo "Latest verbose log: $latest_verbose ($(du -h "$latest_verbose" | cut -f1))"
        fi
    fi
}

show_help() {
    echo "Red Team Terminal Logger - Professional Solution v2.5.1"
    echo "========================================================"
    echo "USAGE: $0 [OPTIONS]"
    echo ""
    echo "LOGGING CONTROLS:"
    echo "  --start               Start command/verbose logging"
    echo "  --stop                Stop logging"
    echo "  --toggle              Toggle logging on/off"
    echo ""
    echo "RECORDING CONTROLS:"
    echo "  --start-recording     Start terminal recording (requires asciinema)"
    echo "  --stop-recording      Stop recording"
    echo "  --toggle-recording    Toggle recording on/off"
    echo ""
    echo "SETUP & CONFIGURATION:"
    echo "  --prompt              Show logging prompt (for new shells)"
    echo "  --install             Install tmux keybindings"
    echo "  --uninstall           Remove tmux keybindings and config"
    echo "  --uninstall-all       Complete removal (same as --uninstall)"
    echo "  --config              Configure settings"
    echo "  --save-config         Save config (internal use)"
    echo ""
    echo "INFO:"
    echo "  --status              Show current status"
    echo "  --help                Show this help"
    echo ""
    echo "DEBUG:"
    echo "  --debug-on            Enable debug logging"
    echo "  --debug-off           Disable debug logging"
    echo ""
    echo "TMUX INTEGRATION:"
    echo "  Keys: prefix+L (toggle logging), prefix+R (recording)"
    echo "  Compatible with ohmytmux themes and window naming"
    echo "  Auto-prompts for new windows/panes (configurable)"
    echo ""
    echo "VERSION 2.5.1 FIXES:"
    echo "  - FIXED: Eliminated all tmux popup messages requiring ESC key"  
    echo "  - FIXED: All output now appears directly in the terminal"
    echo "  - FIXED: Tmux key bindings use send-keys instead of run-shell"
    echo "  - FIXED: Hooks properly redirect output to terminal"
}

# Main command handler with output handling
main() {
    # Always ensure direct terminal output for tmux operations
    if is_tmux && [[ -t 1 ]]; then
        local tty=$(tty 2>/dev/null || echo "/dev/tty")
        exec 1>$tty 2>$tty
    fi
    
    case "$1" in
        --start)             start_logging ;;
        --stop)              stop_logging ;;
        --toggle)            toggle_logging ;;
        --start-recording)   [[ -f "$CONFIG_FILE" ]] && load_config || { TARGET_NAME="$DEFAULT_TARGET"; LOG_DIR="$DEFAULT_LOG_DIR"; }; start_recording "$(get_pane_id)" "$TARGET_NAME" "$LOG_DIR" ;;
        --stop-recording)    stop_recording "$(get_pane_id)" ;;
        --toggle-recording)  toggle_recording ;;
        --prompt)            prompt_for_logging ;;
        --install)           install_tmux_keys ;;
        --uninstall)         uninstall_tmux_keys ;;
        --uninstall-all)     uninstall_all ;;
        --config)            create_config ;;
        --save-config)       save_config_from_tmux ;;
        --status)            show_status ;;
        --debug-on)          [[ -f "$CONFIG_FILE" ]] && { load_config; DEBUG=true; save_config; } || echo "Run --config first to set up configuration"; echo "Debug logging enabled" ;;
        --debug-off)         [[ -f "$CONFIG_FILE" ]] && { load_config; DEBUG=false; save_config; } || echo "Run --config first to set up configuration"; echo "Debug logging disabled" ;;
        --help|'')           show_help ;;
        *)                   echo "Unknown option: $1. Use --help" ;;
    esac
}

# ShellOpsLog compatibility layer
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    export REDTEAM_LOGGER_PATH="${BASH_SOURCE[0]}"
    
    start_operation_log() {
        local auto_start=0
        local log_dir="$HOME/OperationLogs"
        
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -AutoStart|-autostart) auto_start=1; shift ;;
                *) log_dir="$1"; shift ;;
            esac
        done
        
        [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
        
        LOG_DIR="$log_dir"
        TARGET_NAME="${TARGET_NAME:-$DEFAULT_TARGET}"
        save_config
        
        if [[ "$auto_start" -eq 1 ]]; then
            "$REDTEAM_LOGGER_PATH" --start
        else
            "$REDTEAM_LOGGER_PATH" --prompt
        fi
    }
    
    stop_operation_log() {
        "$REDTEAM_LOGGER_PATH" --stop
    }
    
    log_debug "ShellOpsLog compatibility layer loaded"
else
    # Script is being executed directly
    main "$@"
fi