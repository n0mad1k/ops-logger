**# Red Team Terminal Logger (OpsLogger) Project Management**

**## Project Overview**
**Red Team Terminal Logger (OpsLogger)** - A comprehensive terminal logging solution for red team operations that captures commands, output, and sessions across multiple shells with easy toggle controls, combining the best features of ShellOpsLog, Asciinema, and custom verbose logging.

---

**## 🎯 Current Focus**
**Goal:** Maintain stable, reliable logging across all environments (bash/zsh, tmux/standalone, Ubuntu/Kali)
**Last Updated:** December 2024

---

**## 📈 CHANGELOG & HISTORY**

**### Version 2.4.4 (Latest)**
- FIXED: RTL_preexec function definition order issue
- FIXED: Better error handling in hook installation  
- FIXED: --config now always works, auto-prompts on first run
- IMPROVED: All functions defined before traps are set
- IMPROVED: Better ZSH function naming (RTL_zsh_preexec, RTL_zsh_precmd)

**### Version 2.4.3**
- FIXED: Function definitions no longer show in terminal
- FIXED: Configuration input now works properly
- FIXED: --uninstall now removes config file as expected
- IMPROVED: Silent hook installation and cleanup

**### Version 2.4.2**
- FIXED: Verbose logs now include headers directly in the log file
- FIXED: Configuration uses clean terminal interface instead of tmux prompts
- IMPROVED: More reliable verbose logging startup

**### Version 2.4.1**
- FIXED: The temporary command script issue completely eliminated
- FIXED: Now uses in-shell functions to avoid file sourcing errors
- IMPROVED: Better method for logging start/stop with multiple fallbacks

---

**### 📍 Where I Left Off**
- [x] Working on: Fixed RTL_preexec command not found error
- [ ] Next Priority: Test comprehensive functionality across different environments
- [ ] Blockers: Need to verify tmux-logging plugin compatibility in various setups

---

**## 📊 Project Status Dashboard**

**### Overall Progress**
- **Core Infrastructure:** 95% ✅
- **Security Features:** 90% ✅  
- **Documentation:** 85% ✅
- **Testing Coverage:** 70% 🔄
- **Bug Fixes:** 90% ✅

**### Quick Stats**
- ✅ **Working:** 5 features (CSV logging, verbose logging, recording, tmux integration, config)
- 🔄 **In Progress:** 1 feature (comprehensive testing)
- ❌ **Broken:** 0 features
- 🧪 **Needs Testing:** 2 features (multi-environment compatibility, edge cases)
- 📝 **TODO:** 3 features (auto-cleanup, advanced filtering, reporting)

---

**## 💡 IDEAS & FUTURE CONSIDERATIONS**

**### Potential Improvements**
- Auto-cleanup of old log files based on age/size
- Advanced filtering options for command logging
- Integration with popular red team frameworks (Cobalt Strike, Metasploit)
- Log encryption for sensitive operations
- Remote log shipping capabilities
- Better ANSI color preservation in verbose logs

**### Architecture Changes**
- Modular plugin system for different logging backends
- Configuration profiles for different operation types
- Centralized logging server integration
- Real-time log streaming capabilities

**### Integration Opportunities**
- SIEM integration (Splunk, ELK stack)
- Cloud storage backends (AWS S3, Azure Blob)
- Secure tunneling for log exfiltration
- Integration with existing red team tools

---

**## 📝 TODO**
- [ ] Test across different tmux versions
- [ ] Verify ohmytmux compatibility edge cases
- [ ] Add configuration validation
- [ ] Implement log rotation features
- [ ] Create installation script for dependencies
- [ ] Add encrypted logging option
- [ ] Performance optimization for high-volume logging

---

**## 📚 RESEARCH & INVESTIGATION**

**### Current Research Topics**
- [ ] **tmux-logging plugin alternatives** - Research other logging mechanisms if plugin unavailable
- [ ] **Cross-platform compatibility** - Testing on macOS and other Unix variants
- [ ] **Performance impact analysis** - Measure overhead of logging on system performance

**### Completed Research**
- [x] **ShellOpsLog integration** - Successfully maintained backward compatibility
- [x] **ohmytmux compatibility** - Implemented proper window name management
- [x] **ANSI filtering techniques** - Found optimal balance between clean logs and preserved formatting

---

**## 🎪 Major Features**

**### CSV Command Logging**
**Status:** ✅ COMPLETE
**Priority:** HIGH
**Description:** Logs all executed commands with timestamps, user, path, IP, start/end times to CSV format
**#### Tasks:**
- [x] ✅ Basic command capture for bash
- [x] ✅ ZSH support with proper hooks
- [x] ✅ Timing information (start/end times)
- [x] ✅ Public IP detection
- [x] ✅ Command filtering to avoid recursion
- [x] ✅ CSV format compatibility with original ShellOpsLog
**Notes:** Fully functional with proper duplicate prevention and timing

### Verbose Terminal Logging
**Status:** ✅ COMPLETE
**Priority:** HIGH  
**Description:** Captures complete terminal output including commands and responses with session headers
**#### Tasks:**
- [x] ✅ tmux pipe-pane integration
- [x] ✅ Header generation with session metadata
- [x] ✅ ANSI filtering for clean logs
- [x] ✅ Fallback when tmux-logging plugin unavailable
- [x] ✅ Direct file integration (header + content in same file)
**Notes:** Headers now properly integrated into log files, works with and without plugin

### Tmux Integration
**Status:** ✅ COMPLETE
**Priority:** HIGH
**Description:** Seamless integration with tmux including ohmytmux compatibility
**#### Tasks:**
- [x] ✅ Key bindings (prefix+L, prefix+R)
- [x] ✅ Window name indicators (🔴 for logging, 🎥 for recording)
- [x] ✅ ohmytmux compatibility
- [x] ✅ Auto-prompt for new windows/panes
- [x] ✅ Hook installation without visible functions
**Notes:** Fully compatible with ohmytmux themes and window management

### Asciinema Recording
**Status:** ✅ COMPLETE
**Priority:** MEDIUM
**Description:** Terminal session recording using asciinema with proper lifecycle management
**#### Tasks:**
- [x] ✅ Recording start/stop functionality
- [x] ✅ File naming with target/session info
- [x] ✅ Process cleanup on stop
- [x] ✅ Window indicator management
- [x] ✅ Error handling for missing asciinema
**Notes:** Clean recording with proper cleanup and error handling

### Configuration Management
**Status:** ✅ COMPLETE
**Priority:** MEDIUM
**Description:** User-friendly configuration system with auto-setup on first run
**#### Tasks:**
- [x] ✅ Interactive terminal-based config
- [x] ✅ Auto-prompt on first use
- [x] ✅ Configuration persistence
- [x] ✅ Directory creation
- [x] ✅ TTY input handling
**Notes:** Clean terminal interface, auto-prompts work correctly

---

**## 🐛 KNOWN BUGS & ISSUES**

**### High Priority Bugs**
- [ ] **Potential tmux version compatibility** - Some older tmux versions may not support all features
  - *Impact:* Reduced functionality on older systems
  - *Found:* Theoretical - needs testing
  - *Next Step:* Test on tmux < 2.6

**### Medium Priority Bugs**
- [ ] **Public IP detection timeout** - Slow network may cause timeouts
  - *Impact:* "unknown" IP in logs instead of actual IP
  - *Workaround:* Increase timeout or add offline detection
- [ ] **Log file permissions** - May create files with restrictive permissions
  - *Impact:* Logs may not be readable by other tools
  - *Workaround:* Manual permission adjustment

**### Low Priority Issues**
- [ ] **Verbose log file size** - No automatic rotation or cleanup
- [ ] **Debug log accumulation** - Debug logs grow indefinitely  
- [ ] **Multiple session overlap** - Same-named sessions may overwrite logs

---

**## 🧪 TESTING BACKLOG**

**### Needs Comprehensive Testing**
- [ ] **Multi-environment compatibility** - Test across Ubuntu/Kali/CentOS/macOS
- [ ] **Different tmux versions** - Test compatibility with older/newer versions
- [ ] **Edge case scenarios** - Network disconnections, permission issues, disk full
- [ ] **Performance under load** - High-frequency command execution
- [ ] **Plugin dependency handling** - Behavior when tmux-logging plugin missing/broken

**### Tested & Working**
- [x] **Basic functionality** - Start/stop logging works correctly
- [x] **ohmytmux integration** - Window indicators work properly
- [x] **CSV format** - Output matches expected format
- [x] **Function cleanup** - No visible function definitions
- [x] **Configuration system** - Interactive setup works

---

**## 🎯 GOALS & MILESTONES**

**### Goals**
- [ ] 100% compatibility across target environments (Ubuntu/Kali + bash/zsh)
- [ ] Zero visible artifacts during normal operation  
- [ ] Complete documentation and deployment guide
- [ ] Performance benchmarking and optimization
- [ ] Automated testing suite
- [ ] Package for easy distribution

---

**## 🔗 USEFUL LINKS & REFERENCES**

**### Documentation**
- [Tmux Manual](https://github.com/tmux/tmux/wiki) - Tmux functionality reference
- [Asciinema Docs](https://asciinema.org/docs/) - Recording format specifications

**### External Resources**
- [ShellOpsLog](https://github.com/DrorDvash/ShellOpsLog) - Original inspiration and compatibility target
- [ohmytmux](https://github.com/gpakosz/.tmux) - Tmux configuration framework
- [tmux-logging plugin](https://github.com/tmux-plugins/tmux-logging) - Verbose logging backend

**### Related Projects**
- [Tmux Plugin Manager](https://github.com/tmux-plugins/tpm) - Plugin management system
- [Red Team Tools](https://github.com/topics/red-team) - Related offensive security tools

---

**## 📝 NOTES & LESSONS LEARNED**

**### What's Working Well**
- In-shell function approach eliminates file sourcing issues
- Template-based script generation allows dynamic configuration
- Silent operation maintains professional appearance
- Backward compatibility preserved with ShellOpsLog
- Graceful degradation when dependencies missing

**### What Needs Improvement**
- Error handling could be more comprehensive
- Performance impact measurement needed
- Log management (rotation/cleanup) features
- Better feedback for troubleshooting issues
- More comprehensive testing across environments

**### Lessons Learned**
- Function definition order matters critically in shell scripts
- tmux integration requires careful handling of escape sequences and timing
- Configuration UX is crucial for adoption - terminal prompts work better than tmux prompts
- Silent installation/removal is essential for professional tools
- Compatibility layers need extensive testing across environments