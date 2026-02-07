#!/bin/bash

# Hank for Claude Code - Global Installation Script
set -e

# Configuration
INSTALL_DIR="$HOME/.local/bin"
HANK_HOME="$HOME/.hank"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    local level=$1
    local message=$2
    local color=""
    
    case $level in
        "INFO")  color=$BLUE ;;
        "WARN")  color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "SUCCESS") color=$GREEN ;;
    esac
    
    echo -e "${color}[$(date '+%H:%M:%S')] [$level] $message${NC}"
}

# Check dependencies
check_dependencies() {
    log "INFO" "Checking dependencies..."

    local missing_deps=()
    local os_type
    os_type=$(uname)

    if ! command -v node &> /dev/null && ! command -v npx &> /dev/null; then
        missing_deps+=("Node.js/npm")
    fi

    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi

    if ! command -v git &> /dev/null; then
        missing_deps+=("git")
    fi

    # Check for timeout command (platform-specific)
    if [[ "$os_type" == "Darwin" ]]; then
        # macOS: check for gtimeout from coreutils
        if ! command -v gtimeout &> /dev/null && ! command -v timeout &> /dev/null; then
            missing_deps+=("coreutils (for timeout command)")
        fi
    else
        # Linux: check for standard timeout command
        if ! command -v timeout &> /dev/null; then
            missing_deps+=("coreutils")
        fi
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        log "ERROR" "Missing required dependencies: ${missing_deps[*]}"
        echo "Please install the missing dependencies:"
        echo "  Ubuntu/Debian: sudo apt-get install nodejs npm jq git coreutils"
        echo "  macOS: brew install node jq git coreutils"
        echo "  CentOS/RHEL: sudo yum install nodejs npm jq git coreutils"
        exit 1
    fi

    # Additional macOS-specific warning for coreutils
    if [[ "$os_type" == "Darwin" ]]; then
        if command -v gtimeout &> /dev/null; then
            log "INFO" "GNU coreutils detected (gtimeout available)"
        elif command -v timeout &> /dev/null; then
            log "INFO" "timeout command available"
        fi
    fi

    # Claude Code CLI will be downloaded automatically when first used
    log "INFO" "Claude Code CLI (@anthropic-ai/claude-code) will be downloaded when first used."

    # Check tmux (optional)
    if ! command -v tmux &> /dev/null; then
        log "WARN" "tmux not found. Install for integrated monitoring: apt-get install tmux / brew install tmux"
    fi

    log "SUCCESS" "Dependencies check completed"
}

# Create installation directory
create_install_dirs() {
    log "INFO" "Creating installation directories..."
    
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$HANK_HOME"
    mkdir -p "$HANK_HOME/templates"
    mkdir -p "$HANK_HOME/lib"

    log "SUCCESS" "Directories created: $INSTALL_DIR, $HANK_HOME"
}

# Install Hank scripts
install_scripts() {
    log "INFO" "Installing Hank scripts..."
    
    # Copy templates to Hank home
    cp -r "$SCRIPT_DIR/templates/"* "$HANK_HOME/templates/"

    # Copy lib scripts (response_analyzer.sh, circuit_breaker.sh)
    cp -r "$SCRIPT_DIR/lib/"* "$HANK_HOME/lib/"
    
    # Create the main hank command
    cat > "$INSTALL_DIR/hank" << 'EOF'
#!/bin/bash
# Hank for Claude Code - Main Command

HANK_HOME="$HOME/.hank"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the actual hank loop script with global paths
exec "$HANK_HOME/hank_loop.sh" "$@"
EOF

    # Create hank-setup command
    cat > "$INSTALL_DIR/hank-setup" << 'EOF'
#!/bin/bash
# Hank Project Setup - Global Command

HANK_HOME="$HOME/.hank"

exec "$HANK_HOME/setup.sh" "$@"
EOF

    # Create hank-import command
    cat > "$INSTALL_DIR/hank-import" << 'EOF'
#!/bin/bash
# Hank PRD Import - Global Command

HANK_HOME="$HOME/.hank"

exec "$HANK_HOME/hank_import.sh" "$@"
EOF

    # Create hank-migrate command
    cat > "$INSTALL_DIR/hank-migrate" << 'EOF'
#!/bin/bash
# Hank Migration - Global Command
# Migrates existing projects from flat structure to .hank/ subfolder

HANK_HOME="$HOME/.hank"

exec "$HANK_HOME/migrate_to_hank_folder.sh" "$@"
EOF

    # Create hank-enable command (interactive wizard)
    cat > "$INSTALL_DIR/hank-enable" << 'EOF'
#!/bin/bash
# Hank Enable - Interactive Wizard for Existing Projects
# Adds Hank configuration to an existing codebase

HANK_HOME="$HOME/.hank"

exec "$HANK_HOME/hank_enable.sh" "$@"
EOF

    # Create hank-enable-ci command (non-interactive)
    cat > "$INSTALL_DIR/hank-enable-ci" << 'EOF'
#!/bin/bash
# Hank Enable CI - Non-Interactive Version for Automation
# Adds Hank configuration with sensible defaults

HANK_HOME="$HOME/.hank"

exec "$HANK_HOME/hank_enable_ci.sh" "$@"
EOF

    # Copy PRD import script to Hank home
    cp "$SCRIPT_DIR/hank_import.sh" "$HANK_HOME/"

    # Copy migration script to Hank home
    cp "$SCRIPT_DIR/migrate_to_hank_folder.sh" "$HANK_HOME/"

    # Copy enable scripts to Hank home
    cp "$SCRIPT_DIR/hank_enable.sh" "$HANK_HOME/"
    cp "$SCRIPT_DIR/hank_enable_ci.sh" "$HANK_HOME/"

    # Make all commands executable
    chmod +x "$INSTALL_DIR/hank"
    chmod +x "$INSTALL_DIR/hank-setup"
    chmod +x "$INSTALL_DIR/hank-import"
    chmod +x "$INSTALL_DIR/hank-migrate"
    chmod +x "$INSTALL_DIR/hank-enable"
    chmod +x "$INSTALL_DIR/hank-enable-ci"
    chmod +x "$HANK_HOME/hank_import.sh"
    chmod +x "$HANK_HOME/migrate_to_hank_folder.sh"
    chmod +x "$HANK_HOME/hank_enable.sh"
    chmod +x "$HANK_HOME/hank_enable_ci.sh"
    chmod +x "$HANK_HOME/lib/"*.sh

    log "SUCCESS" "Hank scripts installed to $INSTALL_DIR"
}

# Install global hank_loop.sh
install_hank_loop() {
    log "INFO" "Installing global hank_loop.sh..."
    
    # Create modified hank_loop.sh for global operation
    sed \
        -e "s|HANK_HOME=\"\$HOME/.hank\"|HANK_HOME=\"\$HOME/.hank\"|g" \
        -e "s|\$script_dir/hank_loop.sh|\$HANK_HOME/hank_loop.sh|g" \
        "$SCRIPT_DIR/hank_loop.sh" > "$HANK_HOME/hank_loop.sh"
    
    chmod +x "$HANK_HOME/hank_loop.sh"
    
    log "SUCCESS" "Global hank_loop.sh installed"
}

# Install global setup.sh
install_setup() {
    log "INFO" "Installing global setup script..."

    # Copy the actual setup.sh from hank root directory so setup information will be consistent
    if [[ -f "$SCRIPT_DIR/setup.sh" ]]; then
        cp "$SCRIPT_DIR/setup.sh" "$HANK_HOME/setup.sh"
        chmod +x "$HANK_HOME/setup.sh"
        log "SUCCESS" "Global setup script installed (copied from $SCRIPT_DIR/setup.sh)"
    else
        log "ERROR" "setup.sh not found in $SCRIPT_DIR"
        return 1
    fi
}

# Check PATH
check_path() {
    log "INFO" "Checking PATH configuration..."
    
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        log "WARN" "$INSTALL_DIR is not in your PATH"
        echo ""
        echo "Add this to your ~/.bashrc, ~/.zshrc, or ~/.profile:"
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo ""
        echo "Then run: source ~/.bashrc (or restart your terminal)"
        echo ""
    else
        log "SUCCESS" "$INSTALL_DIR is already in PATH"
    fi
}

# Main installation
main() {
    echo "🚀 Installing Hank for Claude Code globally..."
    echo ""
    
    check_dependencies
    create_install_dirs
    install_scripts
    install_hank_loop
    install_setup
    check_path
    
    echo ""
    log "SUCCESS" "🎉 Hank for Claude Code installed successfully!"
    echo ""
    echo "Global commands available:"
    echo "  hank --monitor          # Start Hank with integrated monitoring"
    echo "  hank --help            # Show Hank options"
    echo "  hank-setup my-project  # Create new Hank project"
    echo "  hank-enable            # Enable Hank in existing project (interactive)"
    echo "  hank-enable-ci         # Enable Hank in existing project (non-interactive)"
    echo "  hank-import prd.md     # Convert PRD to Hank project"
    echo "  hank-migrate           # Migrate existing project to .hank/ structure"
    echo ""
    echo "Quick start:"
    echo "  1. hank-setup my-awesome-project"
    echo "  2. cd my-awesome-project"
    echo "  3. # Edit .hank/PROMPT.md with your requirements"
    echo "  4. hank --monitor"
    echo ""
    
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        echo "⚠️  Don't forget to add $INSTALL_DIR to your PATH (see above)"
    fi
}

# Handle command line arguments
case "${1:-install}" in
    install)
        main
        ;;
    uninstall)
        log "INFO" "Uninstalling Hank for Claude Code..."
        rm -f "$INSTALL_DIR/hank" "$INSTALL_DIR/hank-setup" "$INSTALL_DIR/hank-import" "$INSTALL_DIR/hank-migrate" "$INSTALL_DIR/hank-enable" "$INSTALL_DIR/hank-enable-ci"
        rm -rf "$HANK_HOME"
        log "SUCCESS" "Hank for Claude Code uninstalled"
        ;;
    --help|-h)
        echo "Hank for Claude Code Installation"
        echo ""
        echo "Usage: $0 [install|uninstall]"
        echo ""
        echo "Commands:"
        echo "  install    Install Hank globally (default)"
        echo "  uninstall  Remove Hank installation"
        echo "  --help     Show this help"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac