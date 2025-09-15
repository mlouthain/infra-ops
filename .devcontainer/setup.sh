#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

echo "🚀 Setting up Infra-Ops development environment..."

# Detect environment
if [[ -n "${CODESPACES:-}" ]] || [[ -n "${GITHUB_CODESPACE_TOKEN:-}" ]]; then
    log_info "Running in GitHub Codespaces"
    log_info "Codespace name: ${CODESPACE_NAME:-unknown}"
    IS_CODESPACES=true
else
    log_info "Running in local devcontainer"
    IS_CODESPACES=false
fi

# Detect architecture
ARCH=$(uname -m)
case $ARCH in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    arm64) ARCH="arm64" ;;
    *) log_error "Unsupported architecture: $ARCH" && exit 1 ;;
esac
log_info "Detected architecture: $ARCH"

# Ensure Docker permissions
log_info "Configuring Docker permissions..."
sudo chgrp docker /var/run/docker.sock 2>/dev/null || true
sudo chmod 664 /var/run/docker.sock 2>/dev/null || true
sudo usermod -aG docker vscode 2>/dev/null || true

# Verify devcontainer features are working
log_info "Verifying base tools from devcontainer features..."
for tool in kubectl helm docker node npm; do
    if command -v $tool &> /dev/null; then
        echo "  ✓ $tool installed"
    else
        log_warning "$tool missing - check devcontainer features"
    fi
done

# Configure npm for safe global installs (Claude Code dependency)
log_info "Configuring npm for safe global installs..."
mkdir -p ~/.npm-global
npm config set prefix '~/.npm-global'

# Add npm global bin to PATH if not already there
if ! echo "$PATH" | grep -q "$HOME/.npm-global/bin"; then
    echo 'export PATH=~/.npm-global/bin:$PATH' >> ~/.bashrc
fi

# Source the updated PATH for this session
export PATH=~/.npm-global/bin:$PATH

log_info "Installing Claude Code..."
if ! command -v claude &> /dev/null; then
    npm install -g @anthropic-ai/claude-code
    if ! command -v claude &> /dev/null; then
        log_warning "Failed to install Claude Code"
    else
        log_success "Claude Code installed"
    fi
else
    log_success "Claude Code already installed"
fi

log_info "Installing k3d..."
if ! command -v k3d &> /dev/null; then
    curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
    if ! command -v k3d &> /dev/null; then
        log_error "Failed to install k3d"
        exit 1
    else
        log_success "k3d installed"
    fi
else
    log_success "k3d already installed"
fi

log_info "Installing yq..."
if ! command -v yq &> /dev/null; then
    YQ_VERSION=$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest | grep -Po '"tag_name": "v\K[^"]*' || echo "4.35.2")
    sudo wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}"
    sudo chmod +x /usr/local/bin/yq
    if ! command -v yq &> /dev/null; then
        log_warning "Failed to install yq"
    else
        log_success "yq installed"
    fi
else
    log_success "yq already installed"
fi

log_info "Installing ArgoCD CLI..."
if ! command -v argocd &> /dev/null; then
    curl -sSL -o argocd-linux-${ARCH} "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-${ARCH}"
    sudo install -m 555 argocd-linux-${ARCH} /usr/local/bin/argocd
    rm argocd-linux-${ARCH}
    if ! command -v argocd &> /dev/null; then
        log_warning "Failed to install ArgoCD CLI"
    else
        log_success "ArgoCD CLI installed"
    fi
else
    log_success "ArgoCD CLI already installed"
fi

log_info "Installing Crossplane CLI..."
if ! command -v kubectl-crossplane &> /dev/null; then
    CROSSPLANE_VERSION=$(curl -s https://api.github.com/repos/crossplane/crossplane/releases/latest | grep -Po '"tag_name": "v\K[^"]*' || echo "1.14.0")
    curl -sLo kubectl-crossplane "https://releases.crossplane.io/stable/v${CROSSPLANE_VERSION}/bin/linux_${ARCH}/crank" 2>/dev/null || \
    curl -sLo kubectl-crossplane "https://releases.crossplane.io/stable/current/bin/linux_${ARCH}/crank" 2>/dev/null || \
    curl -sLo kubectl-crossplane "https://github.com/crossplane/crossplane/releases/download/v${CROSSPLANE_VERSION}/crank_linux_${ARCH}" 2>/dev/null
    
    if [[ -f kubectl-crossplane ]]; then
        chmod +x kubectl-crossplane
        sudo mv kubectl-crossplane /usr/local/bin/
        if ! command -v kubectl-crossplane &> /dev/null; then
            log_warning "Failed to install Crossplane CLI"
        else
            log_success "Crossplane CLI installed"
        fi
    else
        log_warning "Could not download Crossplane CLI"
    fi
else
    log_success "Crossplane CLI already installed"
fi

log_info "Installing jq..."
if ! command -v jq &> /dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y jq
    log_success "jq installed"
else
    log_success "jq already installed"
fi

# Make bootstrap script executable if it exists
if [[ -f bootstrap.sh ]]; then
    chmod +x bootstrap.sh
    log_success "bootstrap.sh is executable"
fi

log_info "Setting up helpful aliases..."
cat >> ~/.bashrc << 'EOF'

# Infra-Ops aliases
alias k='kubectl'
alias kg='kubectl get'
alias kd='kubectl describe'
alias kl='kubectl logs'
alias kaf='kubectl apply -f'
alias kdf='kubectl delete -f'
alias argopass='kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d'

# ArgoCD port-forward helper
argocd-ui() {
    echo "🌐 Starting ArgoCD UI port-forward on port ${ARGOCD_PORT:-9090}..."
    kubectl port-forward svc/argocd-server -n argocd ${ARGOCD_PORT:-9090}:80
}

# Quick cluster info
cluster-info() {
    echo "📊 Cluster Information:"
    kubectl cluster-info
    echo ""
    echo "📦 Nodes:"
    kubectl get nodes
    echo ""
    echo "🚀 ArgoCD Status:"
    kubectl get pods -n argocd
    echo ""
    echo "🔧 Crossplane Status:"
    kubectl get pods -n crossplane-system
}

EOF

# Codespaces-specific setup
if [[ "$IS_CODESPACES" == "true" ]]; then
    log_info "Configuring Codespaces-specific settings..."
    
    cat >> ~/.bashrc << 'EOF'

# Codespaces-specific configuration
export CODESPACES=true

# Helper function to show port URLs
show-ports() {
    echo "🌐 Available ports:"
    echo "  ArgoCD UI: https://${CODESPACE_NAME}-9090.app.github.dev"
    echo "  k3d LB:    https://${CODESPACE_NAME}-8080.app.github.dev"
}

EOF
    
    log_success "Codespaces configuration added"
fi

echo ""
log_success "Development environment setup complete!"
echo ""

if [[ "$IS_CODESPACES" == "true" ]]; then
    cat << EOF
${BLUE}📚 Codespaces Quick Start:${NC}
   1. Run: ${GREEN}./bootstrap.sh${NC} to set up the cluster
   2. ArgoCD will be configured for Codespaces automatically
   3. Use port 9090 for ArgoCD UI
   4. Check the Ports tab in VS Code for all forwarded services

${BLUE}💡 Tips for Codespaces:${NC}
   - All services are accessible via the Ports tab
   - ArgoCD runs in insecure mode to work with Codespaces proxy
   - Your connection is still secure via HTTPS
   
EOF
else
    cat << EOF
${BLUE}📚 Local Development Quick Start:${NC}
   1. Run: ${GREEN}./bootstrap.sh${NC} to set up the cluster
   2. Access ArgoCD on port 9090
   3. Use ${GREEN}argocd-ui${NC} alias to start port-forward
   
EOF
fi

echo "${BLUE}Available aliases:${NC}"
echo "  k, kg, kd, kl         - kubectl shortcuts"
echo "  argopass              - get ArgoCD admin password"
echo "  argocd-ui             - start ArgoCD port-forward"
echo "  cluster-info          - show cluster status"
[[ "$IS_CODESPACES" == "true" ]] && echo "  show-ports            - show Codespaces port URLs"

echo ""
echo "${GREEN}✨ Happy deploying!${NC}"