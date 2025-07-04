#!/usr/bin/env bash
# OpsLogger - Complete logging solution for red team operations
# Version 2.5.3 - Merged config and prompt fixes

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
VERBOSE_CMD_MARKER="/tmp/ops-logger-cmd"

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
        # If TMUX_PANE is set (from hook), use that specific pane
        if [[ -n "$TMUX_PANE" ]]; then
            local session=$(tmux display -t "$TMUX_PANE" -p '#{session_name}')
            local window=$(tmux display -t "$TMUX_PANE" -p '#{window_index}')
            local pane=$(tmux display -t "$TMUX_PANE" -p '#{pane_index}')
            echo "${session}-${window}-${pane}"
        else
            local session=$(tmux display -p '#{session_name}')
            local window=$(tmux display -p '#{window_index}')
            local pane=$(tmux display -p '#{pane_index}')
            echo "${session}-${window}-${pane}"
        fi
    else
        echo "$$"
    fi
}

# Get tmux pane reference for tmux commands (% format for tmux commands)
get_tmux_pane_ref() {
    if is_tmux; then
        # If TMUX_PANE is set (from hook), use that specific pane
        if [[ -n "$TMUX_PANE" ]]; then
            echo "$TMUX_PANE"
        else
            tmux display -p '#{pane_id}'
        fi
    else
        echo ""
    fi
}

# Get the actual tmux prefix key instead of hardcoding C-b
get_tmux_prefix() {
    # First check if we're using oh-my-tmux which often uses C-a
    if tmux show-options -g | grep -q "TMUX_CONF"; then
        # Check if prefix has been overridden in .local config
        local prefix=$(tmux show-options -g prefix 2>/dev/null | awk '{print $2}')
        if [[ -n "$prefix" ]]; then
            case "$prefix" in
                "C-q") echo "C-q" ;;
                "C-a") echo "C-a" ;;
                "C-b") echo "C-b" ;;
                *) echo "$prefix" ;;
            esac
        else
            echo "C-a"  # oh-my-tmux default
        fi
    else
        # Try to get the actual prefix from tmux config
        local prefix=$(tmux show-options -g prefix 2>/dev/null | awk '{print $2}')
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
    local verbose_log="$4"
    
    cat > "$hook_script" << 'EOF'
#!/usr/bin/env bash
# Command hook - FIXED version with proper function timing

# IMMEDIATELY set all variables and disable errexit
set +e

# Set variables first before anything else
CSV_LOG="__CSV_LOG__"
VERBOSE_LOG="__VERBOSE_LOG__"
PANE_ID="__PANE_ID__"
PUBLIC_IP=$(timeout 5 curl -s ifconfig.me 2>/dev/null || echo "unknown")
RTL_INTERNAL_LOGGING=true
RTL_CMD_START_TIME=""
VERBOSE_CMD_MARKER="__VERBOSE_CMD_MARKER__"

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

# Function to write verbose command header
write_verbose_header() {
    local cmd="$1"
    local start_time="$2"
    local user=$(whoami)
    local path=$(pwd)
    
    # Create a marker file with command info for the verbose processor
    echo "$cmd|$start_time|$user|$path|$PUBLIC_IP|$PANE_ID" > "${VERBOSE_CMD_MARKER}-${PANE_ID}"
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
            write_verbose_header "$cmd" "$RTL_CMD_START_TIME"
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
            write_verbose_header "$cmd" "$RTL_CMD_START_TIME"
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
    sed -i "s|__VERBOSE_LOG__|$verbose_log|g" "$hook_script"
    sed -i "s|__PANE_ID__|$pane_id|g" "$hook_script"
    sed -i "s|__LOG_MARKER__|$LOG_MARKER|g" "$hook_script"
    sed -i "s|__VERBOSE_CMD_MARKER__|$VERBOSE_CMD_MARKER|g" "$hook_script"
    
    chmod +x "$hook_script"
}

# ================================================================
# UNIFIED VERBOSE LOGGING WITH COMMAND HEADERS
# ================================================================

# Create single master verbose log file for all panes
create_master_verbose_log() {
    local target="$1"
    local log_dir="$2"
    local timestamp=$(date +%Y%m%d)
    
    local verbose_dir="${log_dir}/verbose"
    ensure_dir "$verbose_dir"
    
    # Create single log file for entire target
    local log_file="${verbose_dir}/${target}_master_${timestamp}.log"
    
    # Create the file with header if it doesn't exist
    if [[ ! -f "$log_file" ]]; then
        cat > "$log_file" << EOF
================================================================================
                           RED TEAM TERMINAL LOGGER
                              Master Verbose Log
================================================================================
Target: $target
Date: $(date +%Y-%m-%d)
Host: $(hostname)
Public IP: $(get_public_ip)
Started: $(date '+%Y-%m-%d %H:%M:%S')
================================================================================

EOF
    fi
    
    echo "$log_file"
}

# Create debug filter that captures EVERYTHING (no filtering)
create_debug_filter_script() {
    local filter_script="/tmp/ops-debug-filter-$$.sh"
    
    cat > "$filter_script" << 'EODEBUG'
#!/usr/bin/env bash
# DEBUG: Raw pipe-pane output capture

LOGFILE="$1"
PANE_ID="$2"
DEBUG_RAW_FILE="${LOGFILE}.debug-raw"

mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null

echo "[$(date)] DEBUG FILTER STARTED for pane $PANE_ID" >> "$DEBUG_RAW_FILE"
echo "=================================================" >> "$DEBUG_RAW_FILE"

line_count=0
while IFS= read -r line; do
    line_count=$((line_count + 1))
    
    # Write EVERYTHING to debug file with line numbers
    printf "[%04d][$(date +%H:%M:%S)] RAW: %s\n" "$line_count" "$line" >> "$DEBUG_RAW_FILE"
    
    # Also write to main log (no filtering at all)
    echo "$line" >> "$LOGFILE"
done

echo "[$(date)] DEBUG FILTER ENDED - Total lines: $line_count" >> "$DEBUG_RAW_FILE"
EODEBUG
    
    chmod +x "$filter_script"
    echo "$filter_script"
}

# Add debug start function
start_debug_verbose_logging() {
    local id="$1"
    local tmux_pane_ref="$2"
    local target="$3"
    local log_dir="$4"
    
    local debug_log="${log_dir}/debug-${target}-${id}-$(date +%H%M%S).log"
    local filter_script=$(create_debug_filter_script)
    
    echo "Starting DEBUG verbose logging to: $debug_log"
    
    # Use simple pipe-pane with debug filter
    tmux pipe-pane -t "$tmux_pane_ref" "bash '$filter_script' '$debug_log' '$id'"
    
    sleep 1
    
    # Check if logging started
    if tmux list-panes -F "#{pane_id} #{pane_pipe}" | grep -q "$tmux_pane_ref.*1"; then
        echo "DEBUG logging started successfully"
        echo "Raw output file: ${debug_log}.debug-raw"
        echo "Filtered output file: $debug_log"
        
        echo "$filter_script" > "/tmp/ops-debug-filter-script-${id}"
        return 0
    else
        echo "ERROR: DEBUG logging failed to start"
        rm -f "$filter_script"
        return 1
    fi
}

# Create the MINIMAL FIX verbose filter script
# Create the FIXED verbose filter script
create_verbose_filter_script() {
    local filter_script="/tmp/ops-verbose-filter-$$.sh"
    
    cat > "$filter_script" << 'EOFILTER'
#!/usr/bin/env bash
# FIXED: Proper command boundary detection

LOGFILE="$1"
PANE_ID="$2"
TARGET="$3"
VERBOSE_CMD_MARKER="$4"

mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null

# Command tracking
CURRENT_COMMAND=""
IN_COMMAND=false
OUTPUT_LINE_COUNT=0
MAX_LINES_PER_COMMAND=22
LAST_MARKER_CHECK=""

# Function to properly close a command
close_current_command() {
    if [[ "$IN_COMMAND" == "true" ]]; then
        echo "==============================================================================" >> "$LOGFILE"
        echo "" >> "$LOGFILE"
        IN_COMMAND=false
        OUTPUT_LINE_COUNT=0
        CURRENT_COMMAND=""
    fi
}

# Function to check for new command markers
check_command_marker() {
    local marker_file="${VERBOSE_CMD_MARKER}-${PANE_ID}"
    if [[ -f "$marker_file" ]]; then
        # Read the marker content
        local marker_content=$(cat "$marker_file" 2>/dev/null)
        
        # Only process if this is a new marker (different from last check)
        if [[ "$marker_content" != "$LAST_MARKER_CHECK" ]]; then
            LAST_MARKER_CHECK="$marker_content"
            
            # FIXED: Always close previous command first
            close_current_command
            
            # Read command info
            IFS='|' read -r cmd start_time user path public_ip pane_marker <<< "$marker_content"
            
            # Start new command if it's for this pane
            if [[ "$pane_marker" == "$PANE_ID" && -n "$cmd" ]]; then
                CURRENT_COMMAND="$cmd"
                IN_COMMAND=true
                OUTPUT_LINE_COUNT=0
                
                # Write command header
                cat >> "$LOGFILE" << EOCMD
==============================================================================
COMMAND EXECUTION - $start_time
==============================================================================
Command: $cmd
User: $user
Path: $path
Start: $start_time
Pane: $PANE_ID
Public IP: $public_ip
------------------------------------------------------------------------------
OUTPUT:
EOCMD
                
                # Remove the marker file after processing
                rm -f "$marker_file" 2>/dev/null
            fi
        fi
    fi
}

# Simple ANSI stripping
strip_ansi() {
    local line="$1"
    # Remove bracketed paste mode
    line="${line//[?2004h/}"
    line="${line//[?2004l/}"
    # Remove ANSI escape sequences
    line=$(echo "$line" | sed -E 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[?]?[0-9]*[hlc]//g')
    echo "$line"
}

# Check if line looks like a shell prompt
is_prompt_line() {
    local line="$1"
    # More specific prompt detection patterns
    if [[ "$line" =~ .*@.*:.*[\$#][[:space:]]*$ ]] || \
       [[ "$line" =~ ^[[:space:]]*[\$#][[:space:]]*$ ]] || \
       [[ "$line" =~ .*[\$#][[:space:]]+[a-zA-Z] ]]; then
        return 0
    fi
    return 1
}

# Main processing loop
while IFS= read -r line; do
    # ALWAYS check for new commands first, before any processing
    check_command_marker
    
    # Clean the line
    clean_line=$(strip_ansi "$line")
    
    # Skip completely empty lines
    [[ -z "$clean_line" ]] && continue
    
    # If we're in a command, log the output
    if [[ "$IN_COMMAND" == "true" ]]; then
        OUTPUT_LINE_COUNT=$((OUTPUT_LINE_COUNT + 1))
        
        # Check if this looks like a prompt (indicating command end)
        if is_prompt_line "$clean_line" && [[ $OUTPUT_LINE_COUNT -gt 1 ]]; then
            # Don't log the prompt line, just close the command
            close_current_command
            continue
        fi
        
        # Log the output line with timestamp
        if [[ $OUTPUT_LINE_COUNT -le $MAX_LINES_PER_COMMAND ]]; then
            echo "$(date '+%H:%M:%S') $clean_line" >> "$LOGFILE"
        elif [[ $OUTPUT_LINE_COUNT -eq $(($MAX_LINES_PER_COMMAND + 1)) ]]; then
            echo "... [OUTPUT TRUNCATED - showing first $MAX_LINES_PER_COMMAND lines only] ..." >> "$LOGFILE"
        fi
    fi
done

# End any active command on exit
close_current_command

EOFILTER
    
    chmod +x "$filter_script"
    echo "$filter_script"
}

# Enhanced command hook that integrates with verbose logging
create_enhanced_command_hook() {
    local hook_script="$1"
    local csv_log="$2"
    local pane_id="$3"
    local verbose_log="$4"
    
    cat > "$hook_script" << 'EOF'
#!/usr/bin/env bash
# Enhanced command hook with verbose integration

set +e

# Configuration
CSV_LOG="__CSV_LOG__"
VERBOSE_LOG="__VERBOSE_LOG__"
PANE_ID="__PANE_ID__"
PUBLIC_IP=$(timeout 5 curl -s ifconfig.me 2>/dev/null || echo "unknown")
RTL_INTERNAL_LOGGING=true
RTL_CMD_START_TIME=""
VERBOSE_CMD_MARKER="__VERBOSE_CMD_MARKER__"

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

# Enhanced function to write verbose command header
write_verbose_header() {
    local cmd="$1"
    local start_time="$2"
    local user=$(whoami)
    local path=$(pwd)
    
    # Create marker for verbose filter
    echo "$cmd|$start_time|$user|$path|$PUBLIC_IP|$PANE_ID" > "${VERBOSE_CMD_MARKER}-${PANE_ID}"
}

# Function to log command to CSV (unchanged)
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
    [[ -z "$RTL_ORIG_PROMPT_COMMAND" ]] && RTL_ORIG_PROMPT_COMMAND="$PROMPT_COMMAND"
    
    RTL_LAST_COMMAND=""
    RTL_LAST_HISTNUM=""
    
    RTL_preexec() {
        local cmd="$BASH_COMMAND"
        if should_log_command "$cmd" 2>/dev/null; then
            RTL_CMD_START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
            write_verbose_header "$cmd" "$RTL_CMD_START_TIME"
        fi
    }
    
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
    
    trap 'RTL_preexec 2>/dev/null || true' DEBUG 2>/dev/null
    
    if [[ -n "$RTL_ORIG_PROMPT_COMMAND" ]]; then
        PROMPT_COMMAND="RTL_PROMPT_COMMAND; $RTL_ORIG_PROMPT_COMMAND"
    else
        PROMPT_COMMAND="RTL_PROMPT_COMMAND"
    fi
    
# ZSH-specific setup  
elif [[ -n "$ZSH_VERSION" ]]; then
    RTL_zsh_preexec() {
        local cmd="$1"
        if should_log_command "$cmd" 2>/dev/null; then
            RTL_CMD_START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
            write_verbose_header "$cmd" "$RTL_CMD_START_TIME"
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
    
    if autoload -Uz add-zsh-hook 2>/dev/null; then
        add-zsh-hook preexec RTL_zsh_preexec 2>/dev/null || true
        add-zsh-hook precmd RTL_zsh_precmd 2>/dev/null || true
    fi
fi

# Mark as active
echo "$$" > "__LOG_MARKER__-${PANE_ID}"
echo "Enhanced Ops Logger with verbose integration installed for pane $PANE_ID" >&2
EOF

    # Replace placeholders
    sed -i "s|__CSV_LOG__|$csv_log|g" "$hook_script"
    sed -i "s|__VERBOSE_LOG__|$verbose_log|g" "$hook_script"
    sed -i "s|__PANE_ID__|$pane_id|g" "$hook_script"
    sed -i "s|__LOG_MARKER__|$LOG_MARKER|g" "$hook_script"
    sed -i "s|__VERBOSE_CMD_MARKER__|$VERBOSE_CMD_MARKER|g" "$hook_script"
    
    chmod +x "$hook_script"
}

# Start unified verbose logging
# Start unified verbose logging (add delay for stability)
start_unified_verbose_logging() {
    local id="$1"
    local tmux_pane_ref="$2"
    local target="$3"
    local log_dir="$4"
    
    # Create master log file
    local master_log=$(create_master_verbose_log "$target" "$log_dir")
    
    # Create filter script
    local filter_script=$(create_verbose_filter_script)
    
    log_debug "Starting unified verbose logging to: $master_log"
    
    # Use pipe-pane with our filter script
    tmux pipe-pane -t "$tmux_pane_ref" "bash '$filter_script' '$master_log' '$id' '$target' '$VERBOSE_CMD_MARKER'"
    
    # Give pipe-pane time to establish
    sleep 0.5
    
    # Check if logging started successfully
    if tmux list-panes -F "#{pane_id} #{pane_pipe}" | grep -q "$tmux_pane_ref.*1"; then
        log_debug "Unified verbose logging started successfully"
        
        # Store filter script path for cleanup
        echo "$filter_script" > "/tmp/ops-filter-script-${id}"
        
        return 0
    else
        log_debug "ERROR: Unified verbose logging failed to start"
        rm -f "$filter_script"
        return 1
    fi
}

# Stop unified verbose logging
stop_unified_verbose_logging() {
    local tmux_pane_ref="$1"
    local id="$2"
    
    # Stop pipe-pane
    tmux pipe-pane -t "$tmux_pane_ref" 2>/dev/null || true
    
    # Clean up filter script
    if [[ -f "/tmp/ops-filter-script-${id}" ]]; then
        local filter_script=$(cat "/tmp/ops-filter-script-${id}")
        rm -f "$filter_script" 2>/dev/null
        rm -f "/tmp/ops-filter-script-${id}"
    fi
    
    # Clean up markers
    rm -f "${VERBOSE_CMD_MARKER}-${id}" 2>/dev/null
    rm -f "/tmp/ops-cmd-active-${id}" 2>/dev/null
    
    log_debug "Stopped unified verbose logging for pane: $tmux_pane_ref"
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

# Enhanced logging installation with unified verbose logging
install_logging() {
    local id="$1"
    local csv_log="$2"
    local target="$3"
    local log_dir="$4"
    
    log_debug "Installing enhanced logging for pane $id"
    
    if is_tmux; then
        local tmux_pane_ref=$(get_tmux_pane_ref)
        
        # Get master verbose log path
        local master_log=$(create_master_verbose_log "$target" "$log_dir")
        
        # Start unified verbose logging
        if start_unified_verbose_logging "$id" "$tmux_pane_ref" "$target" "$log_dir"; then
            log_debug "Unified verbose logging started successfully"
        else
            log_debug "Verbose logging failed, continuing with CSV only"
        fi
        
        # Create enhanced command hook
        local hook_script="/tmp/ops-hook-${id}.sh"
        create_enhanced_command_hook "$hook_script" "$csv_log" "$id" "$master_log"
        
        # Install the hook
        tmux send-keys -t "$tmux_pane_ref" "source '$hook_script' 2>/dev/null && echo 'Enhanced logging hooks installed successfully' || echo 'Logging may have warnings but is active'" ENTER
        
        sleep 2
        
        # Set window indicator
        set_window_logging_indicator "$tmux_pane_ref"
        
        # Mark as active
        touch "${LOG_MARKER}-${id}"
        touch "${LOG_MARKER}-${id}.success"
        
    else
        # Direct shell logging (CSV only)
        local hook_script="/tmp/ops-hook-${id}.sh"
        create_enhanced_command_hook "$hook_script" "$csv_log" "$id" ""
        source "$hook_script"
        echo "Direct shell logging started (CSV only)"
        
        touch "${LOG_MARKER}-${id}"
        touch "${LOG_MARKER}-${id}.success"
    fi
    
    log_debug "Enhanced logging installation completed"
}

# Enhanced removal function
remove_logging() {
    local id="$1"
    
    log_debug "Removing enhanced logging for pane $id"
    
    if is_tmux; then
        local tmux_pane_ref=$(get_tmux_pane_ref)
        
        # Stop unified verbose logging
        stop_unified_verbose_logging "$tmux_pane_ref" "$id"
        
        # Clean up command hooks (same as before)
        local cleanup_script="/tmp/ops-cleanup-${id}.sh"
        cat > "$cleanup_script" << 'EOF'
#!/usr/bin/env bash
set +e

if [[ -n "$BASH_VERSION" ]]; then
    trap - DEBUG 2>/dev/null
    if [[ -n "$RTL_ORIG_PROMPT_COMMAND" ]]; then
        PROMPT_COMMAND="$RTL_ORIG_PROMPT_COMMAND"
        unset RTL_ORIG_PROMPT_COMMAND
    else
        unset PROMPT_COMMAND
    fi
    unset -f RTL_PROMPT_COMMAND RTL_log_command should_log_command RTL_preexec write_verbose_header 2>/dev/null
elif [[ -n "$ZSH_VERSION" ]]; then
    add-zsh-hook -d preexec RTL_zsh_preexec 2>/dev/null
    add-zsh-hook -d precmd RTL_zsh_precmd 2>/dev/null
    unset -f RTL_zsh_preexec RTL_zsh_precmd RTL_log_command should_log_command write_verbose_header 2>/dev/null
fi

unset RTL_CMD_START_TIME RTL_LAST_COMMAND RTL_LAST_HISTNUM RTL_INTERNAL_LOGGING 2>/dev/null
unset CSV_LOG VERBOSE_LOG PANE_ID PUBLIC_IP VERBOSE_CMD_MARKER 2>/dev/null

echo "Enhanced Ops Logger hooks removed"
EOF
        chmod +x "$cleanup_script"
        
        tmux send-keys -t "$tmux_pane_ref" "source '$cleanup_script' 2>/dev/null; rm -f '$cleanup_script'" ENTER
        
        # Clear window indicators
        clear_window_indicators "$tmux_pane_ref"
        
        # Clean up temp files
        rm -f "/tmp/ops-hook-${id}.sh"
        
    else
        # Direct shell cleanup (same as before)
        if [[ -n "$BASH_VERSION" ]]; then
            trap - DEBUG 2>/dev/null
            if [[ -n "$RTL_ORIG_PROMPT_COMMAND" ]]; then
                PROMPT_COMMAND="$RTL_ORIG_PROMPT_COMMAND"
                unset RTL_ORIG_PROMPT_COMMAND
            else
                unset PROMPT_COMMAND
            fi
            unset -f RTL_PROMPT_COMMAND RTL_log_command should_log_command RTL_preexec write_verbose_header 2>/dev/null
        elif [[ -n "$ZSH_VERSION" ]]; then
            add-zsh-hook -d preexec RTL_zsh_preexec 2>/dev/null
            add-zsh-hook -d precmd RTL_zsh_precmd 2>/dev/null
            unset -f RTL_zsh_preexec RTL_zsh_precmd RTL_log_command should_log_command write_verbose_header 2>/dev/null
        fi
        
        echo "Direct shell logging stopped"
    fi
    
    # Remove markers
    rm -f "${LOG_MARKER}-${id}" "${LOG_MARKER}-${id}.success"
    rm -f "/tmp/ops-hook-${id}.sh"
    
    log_debug "Enhanced logging removal completed"
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

create_config() {
    local is_first_run="${1:-false}"
    
    # If this is a first run from ensure_config in tmux, use the local version's approach
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
mkdir -p "$LOG_DIR" "$LOG_DIR/verbose" "$LOG_DIR/recordings"

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
    
    # For manual --config or non-tmux environments (GitHub version approach)
    echo "Red Team Terminal Logger - First Time Setup"
    echo "==========================================="
    echo ""

    CONFIG_FILE="${HOME}/.ops-logger.conf"
    DEFAULT_TARGET="target-$(hostname | tr '.' '-')"
    DEFAULT_LOG_DIR="${HOME}/OperationLogs"

    # Detect whether we're in a tty
    if [[ ! -t 0 ]]; then
        echo "Error: Cannot prompt user in non-interactive shell."
        return 1
    fi

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
    cat > "$CONFIG_FILE" <<EOF
# Ops Logger Configuration
TARGET_NAME="$TARGET_NAME"
LOG_DIR="$LOG_DIR"
PROMPT_NEW_SHELLS=$PROMPT_NEW_SHELLS
RECORD_INTERVAL=0.5
DEBUG=$DEBUG
EOF

    mkdir -p "$LOG_DIR" "$LOG_DIR/verbose" "$LOG_DIR/recordings"

    echo ""
    echo "Configuration saved!"
    echo "  Target name: $TARGET_NAME"
    echo "  Log directory: $LOG_DIR"
    echo "  Prompt new shells: $PROMPT_NEW_SHELLS"
    echo "  Debug mode: $DEBUG"
    echo ""
    echo "Now run: prefix+L to start logging (or ops-logger --start)"
}

# Keep the ensure_config from local version
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
    local id
    id=$(get_pane_id)

    # ✅ Debug logging to see what's happening
    echo "[$(date)] prompt_for_logging called for pane: $id" >> /tmp/ops-logger-prompt-debug.log
    echo "[$(date)] TMUX_PANE: ${TMUX_PANE:-'not set'}" >> /tmp/ops-logger-prompt-debug.log

    # ✅ Avoid recursion with a pane-specific lock - BUT with timeout
    local lock_file="/tmp/ops-logger-prompted-${id}"
    if [[ -f "$lock_file" ]]; then
        # Check if lock file is stale (older than 30 seconds)
        if [[ $(find "$lock_file" -mmin +0.5 2>/dev/null) ]]; then
            echo "[$(date)] Removing stale lock file" >> /tmp/ops-logger-prompt-debug.log
            rm -f "$lock_file"
        else
            echo "[$(date)] Recent lock file exists, returning" >> /tmp/ops-logger-prompt-debug.log
            return 0
        fi
    fi
    touch "$lock_file"

    # ✅ Cleanup function to ensure lock file is always removed
    cleanup_lock() {
        rm -f "$lock_file"
        echo "[$(date)] Lock file cleaned up" >> /tmp/ops-logger-prompt-debug.log
    }
    trap cleanup_lock EXIT

    is_logging_active "$id" && {
        echo "[$(date)] Already logging, returning" >> /tmp/ops-logger-prompt-debug.log
        cleanup_lock
        return 0
    }

    load_config
    echo "[$(date)] Config loaded - PROMPT_NEW_SHELLS: $PROMPT_NEW_SHELLS" >> /tmp/ops-logger-prompt-debug.log
    
    [[ "$PROMPT_NEW_SHELLS" != "true" ]] && {
        echo "[$(date)] Prompting disabled, returning" >> /tmp/ops-logger-prompt-debug.log
        cleanup_lock
        return 0
    }

    # ✅ FIXED: Use tmux display-popup for proper interaction in tmux
    if is_tmux; then
        echo "[$(date)] In tmux, creating popup" >> /tmp/ops-logger-prompt-debug.log
        
        # Create a temporary script for the popup
        local popup_script="/tmp/ops-prompt-${id}.sh"
        local script_path=$(readlink -f "$0")
        
        cat > "$popup_script" << 'EOPOPUP'
#!/bin/bash
echo "Start logging this shell?"
echo ""
echo "  [Y]es - Start logging"
echo "  [N]o  - Skip logging"
echo ""

read -n 1 -p "Choice [Y/n]: " response
echo ""

if [[ -z "$response" || "${response,,}" == "y" ]]; then
    echo "Starting logging..."
    __SCRIPT_PATH__ --start
    echo "Logging started!"
    sleep 2
else
    echo "Logging skipped."
    sleep 1
fi
EOPOPUP
        
        # Replace placeholder with actual script path
        sed -i "s|__SCRIPT_PATH__|$script_path|g" "$popup_script"
        chmod +x "$popup_script"
        
        echo "[$(date)] Popup script created, calling display-popup" >> /tmp/ops-logger-prompt-debug.log
        
        # Use tmux display-popup for proper interaction
        tmux display-popup -E -w 50 -h 10 -T "Ops Logger" "bash '$popup_script'; rm -f '$popup_script'"
        
        echo "[$(date)] display-popup completed" >> /tmp/ops-logger-prompt-debug.log
        
    else
        echo "[$(date)] Not in tmux, using direct prompt" >> /tmp/ops-logger-prompt-debug.log
        
        # Direct shell - standard approach
        echo "Start logging this shell?"
        echo ""
        echo "  [Y]es - Start logging"
        echo "  [N]o  - Skip logging"
        echo ""
        
        if read -t 10 -n 1 -p "Choice [Y/n]: " response; then
            echo ""
            if [[ -z "$response" || "${response,,}" == "y" ]]; then
                start_logging
                echo "Logging started!"
            else
                echo "Logging skipped."
            fi
        else
            echo ""
            echo "Timeout - logging skipped."
        fi
    fi
    
    # Clean up will be handled by trap
    echo "[$(date)] prompt_for_logging completed" >> /tmp/ops-logger-prompt-debug.log
}

# ================================================================
# TMUX INTEGRATION
# ================================================================

install_tmux_keys() {
    load_config

    if is_tmux; then
        local script_path
        script_path=$(readlink -f "$0")

        # Bind keys
        tmux bind-key L run-shell "bash -c '[ -f ~/.ops-logger.conf ] && tmux run-shell \"$script_path --toggle\" || tmux display-popup -E -w 80% -h 60% -T \"Ops Logger Config\" \"bash $script_path --toggle\"'"
        tmux bind-key R run-shell "'$script_path' --toggle-recording"

        # ✅ FIXED: Create a wrapper script that exports the pane context
        if [[ "$PROMPT_NEW_SHELLS" == "true" ]]; then
            local hook_wrapper="/tmp/ops-logger-pane-wrapper.sh"
            cat > "$hook_wrapper" << EOWRAPPER
#!/bin/bash
# Wrapper that sets pane context and calls the prompt

# Sleep to let pane initialize
sleep 1

# Check config
if [ -f ~/.ops-logger.conf ]; then
    source ~/.ops-logger.conf
    if [ "\$PROMPT_NEW_SHELLS" = "true" ]; then
        # Get pane info in tmux context
        PANE_ID=\$(tmux display-message -p "#{session_name}-#{window_index}-#{pane_index}")
        
        # Check if already logging
        if [ ! -f "/tmp/ops-logger-active-\$PANE_ID" ]; then
            # Export the tmux pane reference for the script to use
            export TMUX_PANE=\$(tmux display-message -p "#{pane_id}")
            
            # Call the script with the pane context
            $script_path --prompt
        fi
    fi
fi
EOWRAPPER
            chmod +x "$hook_wrapper"
            
            tmux set-hook -g after-new-window "run-shell '$hook_wrapper'"
            tmux set-hook -g after-split-window "run-shell '$hook_wrapper'"
            echo "Hooks installed for new windows/panes"
        fi

        echo "Keys installed: $(get_tmux_prefix)+L (logging), $(get_tmux_prefix)+R (recording)"
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
        
        # Remove our hook scripts
        rm -f /tmp/ops-logger-hook-wrapper.sh 2>/dev/null
        rm -f /tmp/ops-logger-tmux-hook.sh 2>/dev/null
        rm -f /tmp/ops-logger-pane-wrapper.sh 2>/dev/null
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
    echo "Red Team Terminal Logger - Professional Solution v2.5.2"
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
    echo "VERSION 2.5.2 FIXES:"
    echo "  - FIXED: Verbose logs now include formatted command headers"
    echo "  - FIXED: Configuration uses interactive tmux windows"
    echo "  - FIXED: Command metadata properly captured and formatted"
    echo "  - IMPROVED: Better separation of capture and formatting"
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
        --debug-pipe)        
            load_config || { TARGET_NAME="$DEFAULT_TARGET"; LOG_DIR="$DEFAULT_LOG_DIR"; }
            local id=$(get_pane_id)
            local tmux_pane_ref=$(get_tmux_pane_ref)
            start_debug_verbose_logging "$id" "$tmux_pane_ref" "$TARGET_NAME" "$LOG_DIR"
            ;;
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