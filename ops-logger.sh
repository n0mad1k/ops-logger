#!/usr/bin/env bash
# RedTeamLogger - Complete logging solution for red team operations
# Version 2.1.4 - Fixed recording to work in current pane and require asciinema

# Configuration variables
CONFIG_FILE="${HOME}/.redteam-logger.conf"
DEFAULT_TARGET="target-$(hostname | tr '.' '-')"
DEFAULT_LOG_DIR="${HOME}/OperationLogs"
PROMPT_NEW_SHELLS=true
RECORD_INTERVAL=0.5
DEBUG=false

# File markers
LOG_MARKER="/tmp/redteam-logger-active"
RECORDING_MARKER="/tmp/redteam-logger-recording"

# Helper functions
log_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        local debug_dir="${LOG_DIR:-${DEFAULT_LOG_DIR}}"
        mkdir -p "$debug_dir" 2>/dev/null
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $*" >> "${debug_dir}/redteam-logger-debug.log"
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
# RedTeam Logger Configuration
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

# Modified get_pane_id function with normalized IDs
get_pane_id() {
    if is_tmux; then
        # Use normalized ID format: session-window-pane
        local session=$(tmux display -p '#{session_name}')
        local window=$(tmux display -p '#{window_index}')
        local pane=$(tmux display -p '#{pane_index}')
        echo "${session}-${window}-${pane}"
    else
        echo "$$"
    fi
}

# Get tmux pane reference for tmux commands (still need the % format for tmux commands)
get_tmux_pane_ref() {
    if is_tmux; then
        tmux display -p '#{pane_id}'
    else
        echo ""
    fi
}

is_logging_active() { [[ -f "${LOG_MARKER}-$1" ]]; }
is_recording_active() { [[ -f "${RECORDING_MARKER}-$1" ]]; }

# Setup CSV logging (simplified format)
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

# Setup verbose log
setup_verbose_log() {
    local target="$1"
    local log_dir="$2"
    local verbose_dir="${log_dir}/verbose"
    local verbose_log="${verbose_dir}/${target}_verbose_$(date +%Y-%m-%d).log"
    
    ensure_dir "$verbose_dir"
    
    if [[ ! -f "$verbose_log" ]]; then
        cat > "$verbose_log" << EOF
================================================================================
                           RED TEAM TERMINAL LOGGER
                              Daily Verbose Log
================================================================================
Target: $target
Date: $(date +%Y-%m-%d)
Host: $(hostname)
Public IP: $(get_public_ip)
================================================================================

EOF
    fi
    
    echo "$verbose_log"
}

# Create simple output capture with minimal ANSI cleaning
create_capture_script() {
    local capture_script="$1"
    local verbose_log="$2"
    local pane_id="$3"
    
    cat > "$capture_script" << EOF
#!/usr/bin/env bash
# Simple output capture with minimal ANSI cleaning (working version)
VERBOSE_LOG="$verbose_log"
PANE_ID="$pane_id"

# Read from stdin (tmux pipe-pane output)
while IFS= read -r line; do
    # Only process non-empty lines
    if [[ -n "\$line" ]]; then
        # Minimal ANSI cleaning - only remove the most common sequences
        clean_line=\$(printf '%s\n' "\$line" | sed -E '
            s/\x1B\[2004[lh]//g
            s/\r//g
        ')
        
        # Write everything to output buffer - let the command handler filter
        echo "\$clean_line" >> "/tmp/redteam-output-\$PANE_ID"
    fi
done
EOF
    chmod +x "$capture_script"
}

# Create command hook with improved logic
create_command_hook() {
    local hook_script="$1"
    local csv_log="$2"
    local verbose_log="$3"
    local pane_id="$4"
    
    cat > "$hook_script" << EOF
#!/usr/bin/env bash
# Command hook with minimal filtering

CSV_LOG="$csv_log"
VERBOSE_LOG="$verbose_log"
PANE_ID="$pane_id"
PUBLIC_IP=\$(timeout 5 curl -s ifconfig.me 2>/dev/null || echo "unknown")

# Internal logging flag to prevent recursion
RTL_INTERNAL_LOGGING=true

# Function to check if command should be logged
should_log_command() {
    local cmd="\$1"
    
    # Only skip obvious internal commands
    case "\$cmd" in
        # Internal logger functions
        *"RTL_"*|*"log_command"*|*"should_log_command"*) return 1 ;;
        # Shell internals
        "history "*|*"PROMPT_COMMAND"*|*"source /tmp/redteam"*) return 1 ;;
        # Empty commands
        "") return 1 ;;
        *) return 0 ;;
    esac
}

# Function to get command output with minimal filtering
get_command_output() {
    local output_file="/tmp/redteam-output-\$PANE_ID"
    local output=""
    
    if [[ -f "\$output_file" ]]; then
        # Get last 10 lines, clean up minimally
        output=\$(tail -n 10 "\$output_file" 2>/dev/null | sed '
            # Remove obvious ANSI escape sequences but preserve content
            s/\x1B\[[0-9;]*[mGKH]//g
            s/\x1B\[[?][0-9]*[hl]//g
            # Remove empty lines
            /^$/d
        ')
        # Remove the temp file
        rm -f "\$output_file"
    fi
    
    # Return the output
    echo "\$output"
}

# Function to log command
RTL_log_command() {
    # Prevent recursive logging
    [[ "\$RTL_INTERNAL_LOGGING" == "true" ]] || return
    
    local cmd="\$1"
    local start_time="\$2"
    local end_time="\$3"
    local user=\$(whoami)
    local path=\$(pwd)
    
    # Check if we should log this command
    should_log_command "\$cmd" || return
    
    # Temporarily disable internal logging during this function
    local old_flag="\$RTL_INTERNAL_LOGGING"
    RTL_INTERNAL_LOGGING=false
    
    # Brief delay to ensure output is captured
    sleep 0.1
    
    # Get command output
    local output=\$(get_command_output)
    
    # Escape quotes for CSV
    local escaped_cmd=\${cmd//\"/\"\"}
    
    # Log to CSV (simplified format)
    printf '"%s","%s","%s","%s","%s","%s"\\n' \\
        "\$start_time" "\$end_time" "\$PUBLIC_IP" "\$user" "\$path" "\$escaped_cmd" >> "\$CSV_LOG"
    
    # Log detailed information to verbose log
    {
        echo ""
        echo "=============================================================================="
        echo "COMMAND EXECUTION - \$(date '+%Y-%m-%d %H:%M:%S')"
        echo "=============================================================================="
        echo "User: \$user"
        echo "Path: \$path"
        echo "Start: \$start_time"
        echo "End: \$end_time"
        echo "Pane: \$PANE_ID"
        echo "Public IP: \$PUBLIC_IP"
        echo "Command: \$cmd"
        echo "------------------------------------------------------------------------------"
        if [[ -n "\$output" ]]; then
            echo "OUTPUT:"
            echo "\$output"
        else
            echo "OUTPUT: (No output captured)"
        fi
        echo "=============================================================================="
        echo ""
    } >> "\$VERBOSE_LOG"
    
    # Restore internal logging flag
    RTL_INTERNAL_LOGGING="\$old_flag"
}

# Set up shell-specific hooks
if [[ -n "\$BASH_VERSION" ]]; then
    # Save original PROMPT_COMMAND
    [[ -z "\$RTL_ORIG_PROMPT_COMMAND" ]] && RTL_ORIG_PROMPT_COMMAND="\$PROMPT_COMMAND"
    
    # Track last command to avoid duplicates
    RTL_LAST_COMMAND=""
    RTL_LAST_HISTNUM=""
    
    # PROMPT_COMMAND function
    RTL_PROMPT_COMMAND() {
        local end_time_formatted="\$(date '+%Y-%m-%d %H:%M:%S')"
        
        # Get current history number and command
        local current_histnum=\$(history 1 | awk '{print \$1}')
        local current_cmd=\$(history 1 | sed 's/^[ ]*[0-9][0-9]*[ ]*//')
        
        # Only log if this is a new command
        if [[ -n "\$current_cmd" && "\$current_cmd" != "\$RTL_LAST_COMMAND" && "\$current_histnum" != "\$RTL_LAST_HISTNUM" ]]; then
            # Estimate start time (rough approximation)
            local start_time_formatted="\$(date -d '1 second ago' '+%Y-%m-%d %H:%M:%S')"
            
            # Log the command
            RTL_log_command "\$current_cmd" "\$start_time_formatted" "\$end_time_formatted"
            
            # Update tracking variables
            RTL_LAST_COMMAND="\$current_cmd"
            RTL_LAST_HISTNUM="\$current_histnum"
        fi
    }
    
    # Set PROMPT_COMMAND
    if [[ -n "\$RTL_ORIG_PROMPT_COMMAND" ]]; then
        PROMPT_COMMAND="RTL_PROMPT_COMMAND; \$RTL_ORIG_PROMPT_COMMAND"
    else
        PROMPT_COMMAND="RTL_PROMPT_COMMAND"
    fi
    
elif [[ -n "\$ZSH_VERSION" ]]; then
    # Zsh implementation using preexec and precmd hooks
    RTL_preexec() {
        # Skip internal commands
        should_log_command "\$1" || return
        
        RTL_CURRENT_COMMAND="\$1"
        RTL_COMMAND_START_TIME="\$(date '+%Y-%m-%d %H:%M:%S')"
    }
    
    RTL_precmd() {
        if [[ -n "\$RTL_CURRENT_COMMAND" && -n "\$RTL_COMMAND_START_TIME" ]]; then
            local end_time="\$(date '+%Y-%m-%d %H:%M:%S')"
            
            RTL_log_command "\$RTL_CURRENT_COMMAND" "\$RTL_COMMAND_START_TIME" "\$end_time"
            
            unset RTL_CURRENT_COMMAND RTL_COMMAND_START_TIME
        fi
    }
    
    autoload -Uz add-zsh-hook
    add-zsh-hook preexec RTL_preexec
    add-zsh-hook precmd RTL_precmd
fi

# Mark as active
echo "\$\$" > "${LOG_MARKER}-\${PANE_ID}"
echo "RedTeam Logger command hook installed for pane \$PANE_ID" >&2
EOF
    chmod +x "$hook_script"
}

# Install comprehensive logging
install_logging() {
    local id="$1"
    local csv_log="$2"
    local verbose_log="$3"
    
    log_debug "Installing logging for pane $id"
    log_debug "CSV log: $csv_log"
    log_debug "Verbose log: $verbose_log"
    
    if is_tmux; then
        # Get tmux pane reference for tmux commands
        local tmux_pane_ref=$(get_tmux_pane_ref)
        
        # Create output capture script
        local capture_script="/tmp/redteam-capture-${id}.sh"
        create_capture_script "$capture_script" "$verbose_log" "$id"
        
        # Set up tmux pipe-pane to capture output
        tmux pipe-pane -t "$tmux_pane_ref" -o "bash '$capture_script'"
        log_debug "tmux pipe-pane started for pane $tmux_pane_ref (normalized: $id)"
        
        # Create command hook
        local hook_script="/tmp/redteam-hook-${id}.sh"
        create_command_hook "$hook_script" "$csv_log" "$verbose_log" "$id"
        
        # Source the command hook in the target pane
        tmux send-keys -t "$tmux_pane_ref" "source '$hook_script'" Enter
        log_debug "Command hook sourced in pane $tmux_pane_ref (normalized: $id)"
        
        # Update window name
        local current_name=$(tmux display -t "$tmux_pane_ref" -p '#{window_name}')
        if [[ "$current_name" != "🔴"* ]]; then
            tmux rename-window -t "$tmux_pane_ref" "🔴 $current_name"
        fi
        
        tmux display-message "Logging started for pane $id"
        
    else
        # Direct shell logging for non-tmux environments
        log_debug "Installing direct shell logging"
        
        # Create command hook
        local hook_script="/tmp/redteam-hook-${id}.sh"
        create_command_hook "$hook_script" "$csv_log" "$verbose_log" "$id"
        
        # Source the hook directly
        source "$hook_script"
        echo "Direct shell logging started"
    fi
    
    # Create success marker
    touch "${LOG_MARKER}-${id}.success"
    log_debug "Logging installation completed for pane $id"
}

# Clean removal of all logging
remove_logging() {
    local id="$1"
    
    log_debug "Removing logging for pane $id"
    
    if is_tmux; then
        # Get tmux pane reference for tmux commands
        local tmux_pane_ref=$(get_tmux_pane_ref)
        
        # Stop tmux pipe-pane
        tmux pipe-pane -t "$tmux_pane_ref"
        log_debug "Stopped tmux pipe-pane for pane $tmux_pane_ref (normalized: $id)"
        
        # Create and source cleanup script
        cat > "/tmp/redteam-cleanup-${id}.sh" << 'EOF'
# Cleanup script for RedTeam Logger
if [[ -n "$BASH_VERSION" ]]; then
    # Restore original PROMPT_COMMAND
    if [[ -n "$RTL_ORIG_PROMPT_COMMAND" ]]; then
        PROMPT_COMMAND="$RTL_ORIG_PROMPT_COMMAND"
        unset RTL_ORIG_PROMPT_COMMAND
    else
        unset PROMPT_COMMAND
    fi
    # Clean up functions
    unset -f RTL_PROMPT_COMMAND RTL_log_command should_log_command get_command_output
elif [[ -n "$ZSH_VERSION" ]]; then
    autoload -Uz add-zsh-hook
    add-zsh-hook -d preexec RTL_preexec 2>/dev/null
    add-zsh-hook -d precmd RTL_precmd 2>/dev/null
    # Clean up functions
    unset -f RTL_preexec RTL_precmd RTL_log_command should_log_command get_command_output
fi

# Clean up all RTL variables
unset RTL_CURRENT_COMMAND RTL_COMMAND_START_TIME RTL_LAST_COMMAND RTL_LAST_HISTNUM
unset RTL_INTERNAL_LOGGING
unset CSV_LOG VERBOSE_LOG PANE_ID PUBLIC_IP

echo "RedTeam Logger hooks removed" >&2
EOF
        tmux send-keys -t "$tmux_pane_ref" "source /tmp/redteam-cleanup-${id}.sh" Enter
        
        # Reset window name
        local window_name=$(tmux display -t "$tmux_pane_ref" -p '#{window_name}')
        if [[ "$window_name" == "🔴"* ]]; then
            tmux rename-window -t "$tmux_pane_ref" "${window_name#🔴 }"
        fi
        
        # Cleanup after delay
        tmux run-shell "sleep 3; rm -f /tmp/redteam-cleanup-${id}.sh /tmp/redteam-capture-${id}.sh /tmp/redteam-hook-${id}.sh /tmp/redteam-output-${id}"
        
        tmux display-message "Logging removed for pane $id"
    else
        # Direct shell cleanup
        if [[ -n "$BASH_VERSION" ]]; then
            if [[ -n "$RTL_ORIG_PROMPT_COMMAND" ]]; then
                PROMPT_COMMAND="$RTL_ORIG_PROMPT_COMMAND"
                unset RTL_ORIG_PROMPT_COMMAND
            else
                unset PROMPT_COMMAND
            fi
            unset -f RTL_PROMPT_COMMAND RTL_log_command should_log_command get_command_output
        elif [[ -n "$ZSH_VERSION" ]]; then
            add-zsh-hook -d preexec RTL_preexec 2>/dev/null
            add-zsh-hook -d precmd RTL_precmd 2>/dev/null
            unset -f RTL_preexec RTL_precmd RTL_log_command should_log_command get_command_output
        fi
        
        # Clean up all RTL variables
        unset RTL_CURRENT_COMMAND RTL_COMMAND_START_TIME RTL_LAST_COMMAND RTL_LAST_HISTNUM
        unset RTL_INTERNAL_LOGGING
        unset CSV_LOG VERBOSE_LOG PANE_ID PUBLIC_IP
        
        echo "Direct shell logging stopped"
    fi
    
    # Remove all temp files and markers
    rm -f "${LOG_MARKER}-${id}" "${LOG_MARKER}-${id}.success"
    rm -f "/tmp/redteam-hook-${id}.sh" "/tmp/redteam-capture-${id}.sh" "/tmp/redteam-output-${id}"
    
    log_debug "Logging removal completed for pane $id"
}

# FIXED Recording functions - now requires asciinema and records in current pane
start_recording() {
    local id="$1"
    local target="$2"
    local log_dir="$3"
    local recordings_dir="${log_dir}/recordings"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    ensure_dir "$recordings_dir"
    log_debug "Starting recording for pane $id, target $target"
    
    # FIXED: Check if asciinema is available and error if not
    if ! command -v asciinema >/dev/null 2>&1; then
        local error_msg="ERROR: asciinema is not installed. Please install asciinema to use recording features."
        if is_tmux; then
            tmux display-message "$error_msg"
        else
            echo "$error_msg" >&2
        fi
        log_debug "Recording failed: asciinema not found"
        return 1
    fi
    
    local cast_file="${recordings_dir}/${target}_${id}_${timestamp}.cast"
    echo "asciinema:$cast_file" > "${RECORDING_MARKER}-${id}"
    
    if is_tmux; then
        # FIXED: Record in the current pane instead of creating a new window
        local tmux_pane_ref=$(get_tmux_pane_ref)
        
        # Update window name to show recording
        local current_name=$(tmux display -t "$tmux_pane_ref" -p '#{window_name}')
        if [[ "$current_name" != "🎥"* ]]; then
            tmux rename-window -t "$tmux_pane_ref" "🎥 $current_name"
        fi
        
        # Send asciinema command to current pane
        tmux send-keys -t "$tmux_pane_ref" "asciinema rec '$cast_file'" Enter
        tmux display-message "Recording started in current pane. Use 'exit' or Ctrl+D to stop."
    else
        # For non-tmux, start asciinema directly (this will take over the terminal)
        echo "Starting asciinema recording. Use 'exit' or Ctrl+D to stop."
        asciinema rec "$cast_file"
    fi
    log_debug "Asciinema recording started: $cast_file"
}

# FIXED stop_recording function to work with current pane recording
stop_recording() {
    local id="$1"
    
    [[ ! -f "${RECORDING_MARKER}-${id}" ]] && {
        is_tmux && tmux display-message "No active recording" || echo "No active recording"
        return 1
    }
    
    read -r rec_type rec_path < <(cat "${RECORDING_MARKER}-${id}" | tr ':' ' ')
    log_debug "Stopping $rec_type recording: $rec_path"
    
    if [[ "$rec_type" == "asciinema" ]]; then
        if is_tmux; then
            local tmux_pane_ref=$(get_tmux_pane_ref)
            # Send Ctrl+D to exit asciinema
            tmux send-keys -t "$tmux_pane_ref" C-d
            
            # Reset window name
            local window_name=$(tmux display -t "$tmux_pane_ref" -p '#{window_name}')
            if [[ "$window_name" == "🎥"* ]]; then
                tmux rename-window -t "$tmux_pane_ref" "${window_name#🎥 }"
            fi
            
            tmux display-message "Recording stopped: $rec_path"
        else
            # For non-tmux, the asciinema command was running in foreground
            # This function would only be called after asciinema exits
            echo "Recording stopped: $rec_path"
        fi
    fi
    
    rm -f "${RECORDING_MARKER}-${id}"
    log_debug "Recording stopped for pane $id"
}

# Configuration management functions
create_config() {
    load_config
    
    if is_tmux; then
        # Use tmux command-prompt for configuration
        tmux command-prompt -p "Target name [$TARGET_NAME]:" "run-shell \"TARGET_NAME='%1' $0 --save-config\""
        tmux run-shell "sleep 1"
        tmux command-prompt -p "Log directory [$LOG_DIR]:" "run-shell \"LOG_DIR='%1' $0 --save-config\""
    else
        echo "Red Team Terminal Logger - Configuration"
        echo "---------------------------------------"
        
        read -p "Enter target name [$TARGET_NAME]: " input
        [[ -n "$input" ]] && TARGET_NAME="$input"
        
        read -p "Enter log directory [$LOG_DIR]: " input
        [[ -n "$input" ]] && LOG_DIR="$input"
        
        read -p "Prompt for logging in new shells [Y/n]: " input
        [[ "${input,,}" == "n" ]] && PROMPT_NEW_SHELLS=false || PROMPT_NEW_SHELLS=true
        
        read -p "Enable debug logging [y/N]: " input
        [[ "${input,,}" == "y" ]] && DEBUG=true || DEBUG=false
        
        save_config
        echo "Configuration saved"
    fi
    
    # Ensure directories exist
    ensure_dir "$LOG_DIR"
    ensure_dir "${LOG_DIR}/verbose"
    ensure_dir "${LOG_DIR}/recordings"
}

save_config_from_tmux() {
    # This handles saving from tmux command-prompt
    save_config
    ensure_dir "$LOG_DIR"
    ensure_dir "${LOG_DIR}/verbose"
    ensure_dir "${LOG_DIR}/recordings"
    is_tmux && tmux display-message "Configuration saved"
}

# Main functions
start_logging() {
    [[ ! -f "$CONFIG_FILE" ]] && {
        is_tmux && tmux display-message "First time setup needed" || echo "First time setup needed"
        create_config
        load_config
    }
    
    load_config
    
    local id=$(get_pane_id)
    is_logging_active "$id" && {
        is_tmux && tmux display-message "Already logging" || echo "Already logging"
        return 0
    }
    
    local csv_log=$(setup_csv_log "$TARGET_NAME" "$LOG_DIR")
    local verbose_log=$(setup_verbose_log "$TARGET_NAME" "$LOG_DIR")
    
    install_logging "$id" "$csv_log" "$verbose_log"
}

stop_logging() {
    local id=$(get_pane_id)
    is_logging_active "$id" || {
        is_tmux && tmux display-message "Not logging" || echo "Not logging"
        return 0
    }
    
    remove_logging "$id"
}

toggle_logging() {
    local id=$(get_pane_id)
    is_logging_active "$id" && stop_logging || start_logging
}

toggle_recording() {
    local id=$(get_pane_id)
    load_config
    
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
        tmux display-message "Tmux keys removed"
        log_debug "Tmux key bindings removed"
    fi
}

uninstall_all() {
    local id=$(get_pane_id)
    
    log_debug "Starting complete uninstall"
    
    # Stop active sessions
    is_logging_active "$id" && stop_logging
    is_recording_active "$id" && stop_recording "$id"
    
    # Remove tmux integration
    is_tmux && uninstall_tmux_keys
    
    # Get config location before removal for cleanup
    load_config
    local log_dir_for_cleanup="$LOG_DIR"
    
    # Remove config file
    [[ -f "$CONFIG_FILE" ]] && {
        rm -f "$CONFIG_FILE"
        log_debug "Removed config file: $CONFIG_FILE"
    }
    
    # Remove debug log if it exists
    [[ -f "${log_dir_for_cleanup}/redteam-logger-debug.log" ]] && {
        rm -f "${log_dir_for_cleanup}/redteam-logger-debug.log"
        log_debug "Removed debug log"
    }
    
    # Clean up all temp files
    rm -f /tmp/redteam-* 2>/dev/null
    
    is_tmux && tmux display-message "Completely uninstalled (all files removed)" || echo "Completely uninstalled"
    log_debug "Complete uninstall finished"
}

show_status() {
    load_config
    local id=$(get_pane_id)
    
    echo "Red Team Logger Status:"
    echo "----------------------"
    echo "Target: $TARGET_NAME"
    echo "Log directory: $LOG_DIR"
    echo "Debug mode: $DEBUG"
    echo "Logging: $(is_logging_active "$id" && echo "ACTIVE" || echo "INACTIVE")"
    echo "Recording: $(is_recording_active "$id" && echo "ACTIVE" || echo "INACTIVE")"
    echo "Public IP: $(get_public_ip)"
    echo "Asciinema: $(command -v asciinema >/dev/null 2>&1 && echo "INSTALLED" || echo "NOT INSTALLED")"
    
    if is_tmux; then
        echo "Tmux session: $(tmux display -p '#{session_name}')"
        echo "Normalized Pane ID: $id"
        echo "Tmux Pane Reference: $(get_tmux_pane_ref)"
    fi
    
    local csv_log="${LOG_DIR}/${TARGET_NAME}_commands_$(date +%Y-%m-%d).csv"
    local verbose_log="${LOG_DIR}/verbose/${TARGET_NAME}_verbose_$(date +%Y-%m-%d).log"
    
    [[ -f "$csv_log" ]] && {
        echo "Current CSV log: $csv_log"
        echo "Commands logged: $(($(wc -l < "$csv_log") - 1))"
    }
    
    [[ -f "$verbose_log" ]] && {
        echo "Current verbose log: $verbose_log"
        echo "Log size: $(du -h "$verbose_log" | cut -f1)"
    }
    
    # Show temp files for debugging
    if [[ "$DEBUG" == "true" ]]; then
        echo ""
        echo "Debug Information:"
        echo "Temp files: $(ls -la /tmp/redteam-* 2>/dev/null | wc -l)"
        echo "Active markers: $(ls -la ${LOG_MARKER}-* 2>/dev/null | wc -l)"
    fi
}

show_help() {
    echo "Red Team Terminal Logger - Professional Solution v2.1.4"
    echo "======================================================"
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
    echo "  --uninstall           Remove tmux keybindings"
    echo "  --uninstall-all       Complete removal (deletes all files)"
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
    echo "  Auto-prompts for new windows/panes (configurable)"
    echo ""
    echo "FEATURES:"
    echo "  - Normalized pane IDs (session-window-pane format)"
    echo "  - Restored working output capture"
    echo "  - Minimal ANSI cleaning preserves content"
    echo "  - Simplified CSV format"
    echo "  - Complete cleanup on uninstall"
    echo "  - Records in current pane (not new window)"
    echo "  - Requires asciinema for recording (no fallback)"
    echo ""
    echo "RECORDING NOTES:"
    echo "  - Recording requires asciinema to be installed"
    echo "  - Recording starts in the current pane/window"
    echo "  - Use 'exit' or Ctrl+D to stop recording"
    echo "  - Recorded files are saved as .cast files"
}

# Main command handler
main() {
    case "$1" in
        --start)             start_logging ;;
        --stop)              stop_logging ;;
        --toggle)            toggle_logging ;;
        --start-recording)   load_config; start_recording "$(get_pane_id)" "$TARGET_NAME" "$LOG_DIR" ;;
        --stop-recording)    stop_recording "$(get_pane_id)" ;;
        --toggle-recording)  toggle_recording ;;
        --prompt)            prompt_for_logging ;;
        --install)           install_tmux_keys ;;
        --uninstall)         uninstall_tmux_keys ;;
        --uninstall-all)     uninstall_all ;;
        --config)            create_config ;;
        --save-config)       save_config_from_tmux ;;
        --status)            show_status ;;
        --debug-on)          DEBUG=true; save_config; echo "Debug logging enabled" ;;
        --debug-off)         DEBUG=false; save_config; echo "Debug logging disabled" ;;
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