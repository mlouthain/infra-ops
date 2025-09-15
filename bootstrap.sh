#!/bin/bash

set -euo pipefail

# Default values
ENVIRONMENT="${1:-local}"
CLUSTER_NAME="${2:-infra-ops-${ENVIRONMENT}}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_CLUSTER_CREATE="${SKIP_CLUSTER_CREATE:-false}"

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
log_header() { echo -e "\n${BLUE}🚀 $1${NC}\n$(printf '=%.0s' {1..50})"; }

# Detect if running in GitHub Codespaces
is_codespaces() {
    [[ -n "${CODESPACES:-}" ]] || [[ -n "${GITHUB_CODESPACE_TOKEN:-}" ]]
}

main() {
    log_header "Infra-Ops Platform Bootstrap"
    log_info "Environment: ${ENVIRONMENT}"
    log_info "Cluster: ${CLUSTER_NAME}"
    log_info "Dry Run: ${DRY_RUN}"
    
    if is_codespaces; then
        log_info "🌐 Running in GitHub Codespaces"
    fi
    
    validate_environment
    
    execute_step "Prerequisites Check" check_prerequisites
    execute_step "Cluster Setup" setup_cluster "${ENVIRONMENT}" "${CLUSTER_NAME}"
    execute_step "ArgoCD Installation" install_argocd
    execute_step "Crossplane Installation" install_crossplane
    execute_step "Self-Management Setup" setup_self_management
    execute_step "Validation" validate_installation
    
    show_success_message
}

execute_step() {
    local step_name="$1"
    local function_name="$2"
    shift 2
    
    log_header "${step_name}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "DRY RUN: Would execute ${function_name}"
        return 0
    fi
    
    if ! "${function_name}" "$@"; then
        log_error "Failed at step: ${step_name}"
        show_rollback_help
        exit 1
    fi
    
    log_success "${step_name} completed"
}

validate_environment() {
    case "${ENVIRONMENT}" in
        "local"|"staging"|"production")
            log_info "Valid environment: ${ENVIRONMENT}"
            ;;
        *)
            log_error "Invalid environment: ${ENVIRONMENT}"
            log_error "Valid environments: local, staging, production"
            exit 1
            ;;
    esac
}

check_prerequisites() {
    log_info "Checking required tools..."
    
    local required_tools=("kubectl" "helm" "k3d" "docker")
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "Required tool not found: $tool"
            exit 1
        fi
        local version=$(${tool} version --short 2>/dev/null | head -1 || ${tool} version 2>/dev/null | head -1 || echo "installed")
        log_info "✓ ${tool}: ${version}"
    done
}

setup_cluster() {
    local env="$1"
    local cluster_name="$2"
    
    case "${env}" in
        "local")
            setup_k3d_cluster "${cluster_name}"
            ;;
        "staging"|"production")
            setup_cloud_cluster "${cluster_name}" "${env}"
            ;;
    esac
}

setup_k3d_cluster() {
    local cluster_name="$1"
    
    if [[ "${SKIP_CLUSTER_CREATE}" == "true" ]]; then
        log_info "Skipping cluster creation (SKIP_CLUSTER_CREATE=true)"
        return 0
    fi
    
    # Check if cluster already exists
    if k3d cluster list | grep -q "${cluster_name}"; then
        log_warning "k3d cluster '${cluster_name}' already exists"
        log_info "Starting existing cluster..."
        k3d cluster start "${cluster_name}" 2>/dev/null || true
    else
        log_info "Creating k3d cluster: ${cluster_name}"
        k3d cluster create "${cluster_name}" \
            --port "8080:80@loadbalancer" \
            --wait \
            --timeout 300s
    fi
    
    log_info "Waiting for cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
    
    # Verify cluster
    kubectl cluster-info --context "k3d-${cluster_name}"
    log_success "k3d cluster '${cluster_name}' is ready"
}

install_argocd() {
    log_info "Installing ArgoCD..."
    
    # Check if already installed
    if kubectl get namespace argocd &> /dev/null; then
        log_warning "ArgoCD namespace already exists, skipping installation"
        configure_argocd_for_codespaces
        return 0
    fi
    
    kubectl create namespace argocd
    
    log_info "Applying ArgoCD manifests..."
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    
    # Wait for ArgoCD to be ready
    log_info "Waiting for ArgoCD to be ready..."
    kubectl wait --for=condition=available --timeout=300s \
        deployment/argocd-server \
        deployment/argocd-repo-server \
        deployment/argocd-application-controller \
        -n argocd
    
    # Configure for Codespaces/development environments
    configure_argocd_for_codespaces
    
    log_success "ArgoCD installed successfully"
}

configure_argocd_for_codespaces() {
    if is_codespaces; then
        log_info "Configuring ArgoCD for Codespaces environment..."
        
        kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge \
            -p '{"data":{"server.insecure":"true"}}' 2>/dev/null || true
        
        kubectl patch configmap argocd-cm -n argocd --type merge \
            -p '{"data":{"url":"http://localhost:9090"}}' 2>/dev/null || true
        
        log_info "Restarting ArgoCD server with insecure mode..."
        kubectl rollout restart deployment/argocd-server -n argocd
        kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
        
        log_success "ArgoCD configured for Codespaces"
    elif [[ "${ENVIRONMENT}" == "local" ]]; then
        log_info "Configuring ArgoCD for local development..."
        
        kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge \
            -p '{"data":{"server.insecure":"true"}}' 2>/dev/null || true
        
        kubectl rollout restart deployment/argocd-server -n argocd
        kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
        
        log_success "ArgoCD configured for local development"
    fi
}

install_crossplane() {
    log_info "Installing Crossplane..."
    
    # Check if already installed
    if kubectl get namespace crossplane-system &> /dev/null; then
        log_warning "Crossplane namespace already exists, skipping installation"
        return 0
    fi
    
    helm repo add crossplane-stable https://charts.crossplane.io/stable
    helm repo update
    
    log_info "Installing Crossplane via Helm..."
    helm install crossplane crossplane-stable/crossplane \
        --namespace crossplane-system \
        --create-namespace \
        --wait \
        --timeout 300s
    
    log_success "Crossplane installed successfully"
}

setup_self_management() {
    log_info "Setting up GitOps self-management..."
    
    # Get Git repository URL
    local repo_url="${INFRA_OPS_REPO_URL:-}"
    if [[ -z "${repo_url}" ]]; then
        if git rev-parse --is-inside-work-tree &>/dev/null; then
            repo_url=$(git remote get-url origin 2>/dev/null || echo "")
        fi
    fi
    
    if [[ -z "${repo_url}" ]]; then
        log_warning "Cannot determine Git repository URL"
        log_warning "Self-management setup skipped"
        log_info "To enable later, set INFRA_OPS_REPO_URL and re-run"
        return 0
    fi
    
    log_info "Repository URL: ${repo_url}"
    log_warning "Self-management setup not implemented yet"
    log_info "Manual setup required - see docs/gitops-setup.md"
}

validate_installation() {
    log_info "Validating installation..."
    
    if kubectl get pods -n argocd | grep -q "Running"; then
        log_success "ArgoCD pods are running"
    else
        log_error "ArgoCD pods are not running"
        kubectl get pods -n argocd
        return 1
    fi
    
    if kubectl get pods -n crossplane-system | grep -q "Running"; then
        log_success "Crossplane pods are running"
    else
        log_error "Crossplane pods are not running"
        kubectl get pods -n crossplane-system
        return 1
    fi
}

show_success_message() {
    log_header "Bootstrap Complete! 🎉"
    
    if is_codespaces; then
        cat << EOF
Your Infra-Ops platform is ready in GitHub Codespaces!

🌐 Access ArgoCD UI:
   kubectl port-forward svc/argocd-server -n argocd 9090:80
   
   Then open the port 9090 URL in the Ports tab
   The URL will be: https://<your-codespace>-9090.app.github.dev/
   
🔑 Get ArgoCD admin password:
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

📊 Check status:
   kubectl get pods -n argocd
   kubectl get pods -n crossplane-system
   kubectl get providers

📚 Next steps:
   1. Access ArgoCD UI and explore
   2. Configure cloud provider secrets
   3. Create your first infrastructure resources
   4. Set up GitOps workflows

💡 Codespaces Tips:
   - All forwarded ports appear in the Ports tab at the bottom of VS Code
   - Click the globe icon to open in browser
   - ArgoCD runs in insecure mode to work with Codespaces proxy

EOF
    else
        cat << EOF
Your Infra-Ops platform is ready!

🌐 Access ArgoCD UI:
   kubectl port-forward svc/argocd-server -n argocd 9090:80
   URL: http://localhost:9090
   
🔑 Get ArgoCD admin password:
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

📊 Check status:
   kubectl get pods -n argocd
   kubectl get pods -n crossplane-system
   kubectl get providers

📚 Next steps:
   1. Access ArgoCD UI and explore
   2. Configure cloud provider secrets
   3. Create your first infrastructure resources
   4. Set up GitOps workflows

EOF
    fi
}

show_rollback_help() {
    cat << EOF

💥 Bootstrap failed! Cleanup options:

  Local environment cleanup:
    k3d cluster delete ${CLUSTER_NAME}
    
  Manual cleanup:
    kubectl delete namespace argocd crossplane-system --ignore-not-found
    
  Full reset:
    k3d cluster delete ${CLUSTER_NAME}
    docker system prune -f

EOF
}

main "$@"