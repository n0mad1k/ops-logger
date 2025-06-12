# Ops Logger

A comprehensive terminal logging solution for red team operations with tmux integration.

## Info

**Version 2.5.3** - All major logging features are now working reliably! Command logging, verbose logging with proper command boundaries, and terminal recording are fully functional across bash/zsh environments with tmux integration.

## Overview

Ops Logger provides automated logging and recording of terminal sessions during security operations. It captures commands, outputs, and full terminal recordings for documentation, evidence gathering, and audit trails.

Key features:
- **Shell-Agnostic**: Works with bash and zsh shells running inside tmux
- **Command Logging**: Records all commands with timestamps, user, path, and output to CSV and verbose logs
- **Fixed Verbose Logging**: Proper command boundary detection prevents output mixing
- **Normalized Pane IDs**: Uses predictable session-window-pane format (e.g., `main-0-0`)
- **Terminal Recording**: Supports asciinema recordings with fallback to basic frame capture
- **tmux Integration**: Seamless integration with tmux including Oh My Tmux! configurations
- **Visual Feedback**: Shows 🔴 logging and 🎥 recording indicators in window names
- **Engagement-Aware**: Target-based organization for better log management
- **Enhanced Command Headers**: Verbose logs include formatted command execution headers
- **Reliable Command Boundaries**: Fixed command mixing issues in verbose output

## Installation

### Quick Install

```bash
# Download and make executable
curl -L -o ~/ops-logger.sh https://raw.githubusercontent.com/your-repo/ops-logger/main/ops-logger.sh
chmod +x ~/ops-logger.sh

# Install tmux integration
~/ops-logger.sh --install
```

### Manual Setup

```bash
# Clone the repository
git clone https://github.com/your-repo/ops-logger.git
cd ops-logger

# Make executable and install
chmod +x ops-logger.sh
./ops-logger.sh --install
```

## Usage

### Command-Line Options

```
Red Team Terminal Logger - Professional Solution v2.5.3
======================================================
USAGE: ./ops-logger.sh [OPTIONS]

LOGGING CONTROLS:
  --start               Start command/verbose logging
  --stop                Stop logging
  --toggle              Toggle logging on/off

RECORDING CONTROLS:
  --start-recording     Start terminal recording
  --stop-recording      Stop recording
  --toggle-recording    Toggle recording on/off

SETUP & CONFIGURATION:
  --prompt              Show logging prompt (for new shells)
  --install             Install tmux keybindings
  --uninstall           Remove tmux keybindings
  --uninstall-all       Complete removal (deletes all files)
  --config              Configure settings
  --save-config         Save config (internal use)

INFO:
  --status              Show current status
  --help                Show this help

DEBUG:
  --debug-on            Enable debug logging
  --debug-off           Disable debug logging

TMUX INTEGRATION:
  Keys: prefix+L (toggle logging), prefix+R (recording)
  Compatible with ohmytmux themes and window naming
  Auto-prompts for new windows/panes (configurable)

VERSION 2.5.3 FEATURES:
  - FIXED: Verbose logs now have proper command boundaries
  - FIXED: Commands no longer mix output between executions
  - FIXED: Enhanced command headers with full context
  - IMPROVED: Better separation of capture and formatting
```

### Key Bindings

Once installed, the following tmux key bindings are available:

- **Prefix + L**: Toggle command logging for the current pane
- **Prefix + R**: Toggle terminal recording for the current pane

Note: "Prefix" refers to your tmux prefix key (default: Ctrl+b, often Ctrl+a with Oh My Tmux!).

## What's New in 2.5.3

### Major Fixes
- **Fixed Command Boundary Detection**: Verbose logs no longer mix command output
- **Enhanced Command Headers**: Each command execution now has properly formatted headers
- **Improved Filter Logic**: Better separation between command capture and output formatting
- **Reliable Command Closure**: Commands are properly closed when new ones begin

### Enhanced Verbose Log Format

Commands are now cleanly separated with proper headers:
```
==============================================================================
COMMAND EXECUTION - 2025-06-11 21:59:56
==============================================================================
Command: pwd
User: n0mad1k
Path: /home/n0mad1k
Start: 2025-06-11 21:59:56
Pane: 0-1-1
Public IP: 98.98.163.173
------------------------------------------------------------------------------
OUTPUT:
21:59:56 /home/n0mad1k
==============================================================================

==============================================================================
COMMAND EXECUTION - 2025-06-11 21:59:59
==============================================================================
Command: whoami
User: n0mad1k
Path: /home/n0mad1k
Start: 2025-06-11 21:59:59
Pane: 0-1-1
Public IP: 98.98.163.173
------------------------------------------------------------------------------
OUTPUT:
21:59:59 n0mad1k
==============================================================================
```

## tmux Configuration Compatibility

### Oh My Tmux! Users

Ops Logger automatically detects and integrates with Oh My Tmux! configurations. The keybindings are installed without conflicting with existing Oh My Tmux! features.

### Custom tmux Configurations

If you have a custom tmux setup, the installer will add these keybindings:

```bash
# Automatically added by --install
bind-key L run-shell "'/path/to/ops-logger.sh' --toggle"
bind-key R run-shell "'/path/to/ops-logger.sh' --toggle-recording"
```

### Custom Key Bindings

You can manually set different keys if L and R conflict with your setup:

```bash
# Example with different keys in .tmux.conf
bind-key O run-shell "~/ops-logger.sh --toggle"
bind-key P run-shell "~/ops-logger.sh --toggle-recording"
```

## First-Time Setup

On first run, Ops Logger will:
1. Prompt for configuration setup
2. Ask for target name (defaults to `target-hostname`)
3. Set log directory (defaults to `~/OperationLogs`)
4. Create configuration file at `~/.ops-logger.conf`

Reconfigure at any time with:
```bash
./ops-logger.sh --config
```

## Workflow Examples

### Basic Operation Logging

1. Start tmux: `tmux`
2. Press `Prefix + L` to start logging
3. Window title shows 🔴 indicator when logging is active
4. All commands and outputs are automatically logged with proper boundaries
5. Logs saved to `~/OperationLogs/`

### Recording Remote Sessions

1. SSH to target: `ssh user@target`
2. Press `Prefix + R` to start recording
3. Window title shows 🎥 indicator when recording
4. Perform operations (everything is captured)
5. Press `Prefix + R` again to stop
6. Recording saved to `~/OperationLogs/recordings/`

### Multiple Pane Operations

Ops Logger works independently in each tmux pane:
- Each pane gets its own normalized ID (e.g., `main-0-0`, `main-0-1`)
- Logging and recording can be enabled per-pane
- Visual indicators show status for each pane

## Configuration

Configuration is stored in `~/.ops-logger.conf`:

```bash
# Ops Logger Configuration
TARGET_NAME="target-example"
LOG_DIR="/home/user/OperationLogs"
PROMPT_NEW_SHELLS=true
RECORD_INTERVAL=0.5
DEBUG=false
```

### Configuration Options

| Setting | Default | Description |
|---------|---------|-------------|
| `TARGET_NAME` | `target-hostname` | Identifier for logs and recordings |
| `LOG_DIR` | `~/OperationLogs` | Base directory for all logs |
| `PROMPT_NEW_SHELLS` | `true` | Ask to enable logging in new panes |
| `RECORD_INTERVAL` | `0.5` | Seconds between frames in basic recording |
| `DEBUG` | `false` | Enable debug logging to troubleshoot issues |

## Shell Compatibility

Ops Logger currently supports:
- **Bash**: Full support with history-based command detection
- **Zsh**: Full support with preexec/precmd hooks
- **Other shells**: May work but not specifically tested

The tool hooks into shell command execution and tmux output capture, making it work across different shell environments.

## Log Structure

```
~/OperationLogs/
├── target-name_commands_YYYY-MM-DD.csv        # CSV command log
├── verbose/
│   └── target-name_master_YYYYMMDD.log        # Master verbose log with headers
└── recordings/
    ├── target-name_main-0-0_YYYYMMDD_HHMMSS.cast      # Asciinema files
    └── target-name_main-0-0_YYYYMMDD_HHMMSS/           # Basic recordings
        ├── info.txt                            # Recording metadata
        └── frames/                             # Individual frame captures
```

### CSV Log Format

The CSV log contains essential command information:
```csv
"StartTime","EndTime","SourceIP","User","Path","Command"
"2025-06-11 21:59:56","2025-06-11 21:59:59","98.98.163.173","n0mad1k","/home/n0mad1k","pwd"
```

### Verbose Log Format

Detailed logs with command context and clean output separation:
```
==============================================================================
COMMAND EXECUTION - 2025-06-11 21:59:56
==============================================================================
Command: pwd
User: n0mad1k
Path: /home/n0mad1k
Start: 2025-06-11 21:59:56
Pane: 0-1-1
Public IP: 98.98.163.173
------------------------------------------------------------------------------
OUTPUT:
21:59:56 /home/n0mad1k
==============================================================================
```

## Viewing Recordings

### Asciinema Recordings

```bash
# Play recording
asciinema play ~/OperationLogs/recordings/target-name_*.cast

# Upload to asciinema.org (if appropriate)
asciinema upload ~/OperationLogs/recordings/target-name_*.cast
```

### Basic Recordings

Basic recordings are stored as individual frame captures with metadata. They can be processed or viewed using the captured frame data.

## Status Indicators

Ops Logger provides visual feedback through tmux window names:
- **🔴 [window-name]**: Logging is active in this window
- **🎥 [window-name]**: Recording is active in this window
- **🔴🎥 [window-name]**: Both logging and recording are active

## Requirements

- **tmux** (required)
- **bash** or **zsh** (for command hooks)
- **curl** (for public IP detection)
- **asciinema** (optional, for high-quality recordings)

## Troubleshooting

### Enable Debug Mode

```bash
./ops-logger.sh --debug-on
./ops-logger.sh --status
# Check ~/OperationLogs/ops-logger-debug.log for details
```

### Common Issues

1. **Keybindings not working:**
   ```bash
   # Check if bindings are installed
   tmux list-keys | grep ops
   
   # Manually reinstall
   ./ops-logger.sh --uninstall
   ./ops-logger.sh --install
   ```

2. **No output in logs:**
   - Enable debug mode to see what's happening
   - Check that shell hooks are properly installed
   - Verify the pane ID matches between status and logs

3. **Recording issues:**
   ```bash
   # Check asciinema installation
   which asciinema
   
   # Try basic recording mode if asciinema fails
   # (automatically falls back)
   ```

4. **Command boundary issues:**
   - Version 2.5.3 fixes most boundary detection problems
   - Enable debug mode if commands still appear mixed
   - Check for unusual prompt configurations

5. **Permission issues:**
   ```bash
   # Check log directory permissions
   ls -la ~/OperationLogs/
   
   # Recreate if needed
   rm -rf ~/OperationLogs/
   ./ops-logger.sh --start
   ```

### Complete Removal

```bash
# Stop all logging and remove everything
./ops-logger.sh --uninstall-all

# This removes:
# - tmux keybindings
# - configuration file
# - debug logs
# - temporary files
```

## ShellOpsLog Compatibility

Ops Logger includes compatibility with the ShellOpsLog API:

```bash
# Source the script for compatibility functions
source ops-logger.sh

# Use ShellOpsLog-style commands
start_operation_log
start_operation_log -AutoStart
stop_operation_log
```

## Security Considerations

- **Sensitive Data**: Logs may contain passwords, API keys, or other sensitive information
- **Log Storage**: Consider encrypting logs at rest for sensitive operations
- **Network Traffic**: Public IP detection makes outbound connections
- **File Permissions**: Log files inherit standard user permissions
- **Remote Logging**: Be aware of what's being captured during SSH sessions

## Performance

Ops Logger is designed to be lightweight:
- Minimal CPU overhead during normal operation
- Output buffering prevents excessive I/O
- Configurable recording intervals for basic recording mode
- Automatic cleanup of temporary files
- Efficient command boundary detection

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/amazing-feature`
3. Test thoroughly in both bash and zsh
4. Commit changes: `git commit -am 'Add amazing feature'`
5. Push to branch: `git push origin feature/amazing-feature`
6. Submit a pull request

## License

This project is licensed under the MIT License.

## Disclaimer

This tool is intended for authorized red team operations only. Users are responsible for:
- Obtaining proper authorization before use
- Protecting sensitive logged information
- Complying with applicable laws and regulations
- Using the tool ethically and responsibly

Ops Logger captures and stores everything typed and displayed in terminal sessions. Exercise appropriate caution when handling the resulting log files.