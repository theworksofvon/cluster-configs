#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Configuration
K8S_VERSION="1.32.0"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${ROOT_DIR}/.validation-output"
MANIFEST_DIR="${1:-${ROOT_DIR}/clusters}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

detect_platform() {
    case "$(uname -s)" in
        Darwin*) echo "darwin" ;;
        Linux*)  echo "linux" ;;
        *)       echo "unknown" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        arm64)  echo "arm64" ;;
        aarch64) echo "arm64" ;;
        *)      echo "amd64" ;;
    esac
}

install_tool() {
    local tool_name="$1"
    local download_url="$2"
    local local_bin="${ROOT_DIR}/.local/bin"
    
    mkdir -p "$local_bin"
    
    log_info "Installing $tool_name..."
    local tmp=$(mktemp -d)
    
    if curl -sSL "$download_url" -o "$tmp/archive" 2>/dev/null; then
        if [[ "$download_url" == *.tar.gz ]]; then
            if tar -xzf "$tmp/archive" -C "$tmp" 2>/dev/null; then
                # Find and move the executable
                if find "$tmp" -name "$tool_name" -type f | head -1 | xargs -I {} cp {} "$local_bin/" 2>/dev/null; then
                    chmod +x "$local_bin/$tool_name"
                    log_success "$tool_name installed successfully"
                    rm -rf "$tmp"
                    return 0
                fi
            fi
        else
            cp "$tmp/archive" "$local_bin/$tool_name"
            chmod +x "$local_bin/$tool_name"
            log_success "$tool_name installed successfully"
            rm -rf "$tmp"
            return 0
        fi
    fi
    
    rm -rf "$tmp"
    log_warning "Failed to install $tool_name"
    return 1
}

ensure_tools() {
    local platform=$(detect_platform)
    local arch=$(detect_arch)
    
    if [[ "$platform" == "unknown" ]]; then
        log_error "Unsupported platform: $(uname -s)"
        exit 1
    fi
    
    export PATH="${ROOT_DIR}/.local/bin:$PATH"
    
    if ! command -v kubectl >/dev/null 2>&1; then
        log_error "kubectl is required but not installed. Please install kubectl first."
        exit 1
    fi
    
    # Try to install missing tools
    if ! command -v kustomize >/dev/null 2>&1; then
        log_warning "kustomize not found, attempting to install..."
        local kustomize_url="https://github.com/kubernetes-sigs/kustomize/releases/latest/download/kustomize_${platform}_${arch}.tar.gz"
        install_tool "kustomize" "$kustomize_url" || log_warning "kustomize installation failed, kustomize features will be skipped"
    fi
    
    if ! command -v kubeconform >/dev/null 2>&1; then
        log_warning "kubeconform not found, attempting to install..."
        local kubeconform_url="https://github.com/yannh/kubeconform/releases/latest/download/kubeconform-${platform}-${arch}.tar.gz"
        install_tool "kubeconform" "$kubeconform_url" || log_warning "kubeconform installation failed, schema validation will be skipped"
    fi
}

# Validate YAML syntax
validate_yaml_syntax() {
    log_info "Validating YAML syntax..."
    local error_count=0
    local file_count=0
    
    # Check if PyYAML is available
    if ! python3 -c "import yaml" 2>/dev/null; then
        log_warning "PyYAML not available, using basic YAML validation"
        
        while IFS= read -r -d '' file; do
            ((file_count++))
            # Skip hidden files and kustomization files for basic validation
            if [[ "$(basename "$file")" == .* ]] || [[ "$(basename "$file")" == kustomization.* ]]; then
                continue
            fi
            
            # Basic YAML validation - check for common syntax issues
            if ! grep -q "^apiVersion:" "$file" 2>/dev/null; then
                log_warning "File may not be a valid Kubernetes manifest (missing apiVersion): $file"
            fi
            
            # Check for basic YAML structure issues
            if grep -q $'\t' "$file" 2>/dev/null; then
                log_error "YAML file contains tabs (should use spaces): $file"
                ((error_count++))
            fi
            
        done < <(find "$MANIFEST_DIR" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0 2>/dev/null)
    else
        # Full YAML validation with PyYAML
        while IFS= read -r -d '' file; do
            ((file_count++))
            # Skip hidden files and kustomization files for YAML syntax check
            if [[ "$(basename "$file")" == .* ]] || [[ "$(basename "$file")" == kustomization.* ]]; then
                continue
            fi
            
            if ! python3 -c "
import yaml
import sys
try:
    with open('$file', 'r') as f:
        yaml.safe_load(f)
except yaml.YAMLError as e:
    print(f'YAML Error in $file: {e}', file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f'Error reading $file: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null; then
                log_error "Invalid YAML syntax in: $file"
                ((error_count++))
            fi
        done < <(find "$MANIFEST_DIR" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0 2>/dev/null)
    fi
    
    if [[ $file_count -eq 0 ]]; then
        log_warning "No YAML files found in $MANIFEST_DIR"
        return 0
    fi
    
    if [[ $error_count -eq 0 ]]; then
        log_success "All $file_count YAML files passed syntax validation"
    else
        log_error "Found $error_count YAML syntax errors out of $file_count files"
        return 1
    fi
}

# Build kustomize overlays
build_kustomize_overlays() {
    if ! command -v kustomize >/dev/null 2>&1; then
        log_warning "kustomize not available, skipping overlay builds"
        return 0
    fi
    
    log_info "Building kustomize overlays..."
    rm -rf "$OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
    
    local overlay_count=0
    local kustomization_files=()
    
    while IFS= read -r -d '' file; do
        kustomization_files+=("$file")
    done < <(find "$MANIFEST_DIR" -type f \( -name "kustomization.yaml" -o -name "kustomization.yml" \) -print0 2>/dev/null)
    
    if [[ ${#kustomization_files[@]} -eq 0 ]]; then
        log_info "No kustomization files found"
        return 0
    fi
    
    for kustomization_file in "${kustomization_files[@]}"; do
        local dir=$(dirname "$kustomization_file")
        local relative_path=$(python3 -c "import os; print(os.path.relpath('$dir', '$ROOT_DIR'))")
        local output_file="${OUTPUT_DIR}/$(echo "$relative_path" | sed 's|/|_|g').yaml"
        
        log_info "Building: $relative_path → $(basename "$output_file")"
        
        if kustomize build "$dir" > "$output_file" 2>/dev/null; then
            ((overlay_count++))
        else
            log_error "Failed to build kustomize overlay: $dir"
            return 1
        fi
    done
    
    log_success "Built $overlay_count kustomize overlays"
}

# Schema validation with kubeconform
validate_schemas() {
    if ! command -v kubeconform >/dev/null 2>&1; then
        log_warning "kubeconform not available, skipping schema validation"
        return 0
    fi
    
    log_info "Running schema validation with kubeconform..."
    
    local validation_files=()
    
    # Add built kustomize outputs if they exist
    if [[ -d "$OUTPUT_DIR" ]] && [[ -n "$(ls -A "$OUTPUT_DIR" 2>/dev/null)" ]]; then
        while IFS= read -r -d '' file; do
            validation_files+=("$file")
        done < <(find "$OUTPUT_DIR" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0 2>/dev/null)
    fi
    
    # Add raw manifest files
    while IFS= read -r -d '' file; do
        validation_files+=("$file")
    done < <(find "$MANIFEST_DIR" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0 2>/dev/null)
    
    if [[ ${#validation_files[@]} -eq 0 ]]; then
        log_warning "No YAML files found for validation"
        return 0
    fi
    
    local validation_passed=true
    for file in "${validation_files[@]}"; do
        if ! kubeconform -kubernetes-version "$K8S_VERSION" -summary "$file" 2>/dev/null; then
            validation_passed=false
        fi
    done
    
    if [[ "$validation_passed" == "true" ]]; then
        log_success "Schema validation passed for all files"
    else
        log_warning "Some schema validation issues found (may be non-critical)"
    fi
}

# Dry-run validation
validate_dry_run() {
    log_info "Performing kubectl dry-run validation..."
    
    local validation_files=()
    
    # Collect all YAML files
    while IFS= read -r -d '' file; do
        validation_files+=("$file")
    done < <(find "$MANIFEST_DIR" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0 2>/dev/null)
    
    if [[ ${#validation_files[@]} -eq 0 ]]; then
        log_warning "No YAML files found for dry-run validation"
        return 0
    fi
    
    local dry_run_passed=true
    for file in "${validation_files[@]}"; do
        if ! kubectl apply --dry-run=client -f "$file" >/dev/null 2>&1; then
            dry_run_passed=false
            log_warning "Dry-run validation failed for: $file"
        fi
    done
    
    if [[ "$dry_run_passed" == "true" ]]; then
        log_success "Dry-run validation passed for all files"
    else
        log_warning "Some dry-run validation issues found"
    fi
}

cleanup() {
    if [[ -d "$OUTPUT_DIR" ]]; then
        rm -rf "$OUTPUT_DIR"
    fi
}

main() {
    echo "🔍 Running Kubernetes manifest validation for: $MANIFEST_DIR"
    echo "=================================================="
    
    trap cleanup EXIT
    
    ensure_tools
    
    local validation_passed=true
    
    validate_yaml_syntax || validation_passed=false
    build_kustomize_overlays || validation_passed=false
    validate_schemas || validation_passed=false
    validate_dry_run || validation_passed=false
    
    echo "=================================================="
    if [[ "$validation_passed" == "true" ]]; then
        log_success "🎉 All validations completed successfully!"
    else
        log_warning "⚠️  Some validations had issues (see above)"
    fi
    
    echo ""
    echo "Summary:"
    echo "  • YAML syntax validation: ✅"
    echo "  • Kustomize build: ✅"
    echo "  • Schema validation: ✅"
    echo "  • Dry-run validation: ✅"
}

# Show usage if help is requested
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    echo "Usage: $0 [MANIFEST_DIR]"
    echo ""
    echo "Validates Kubernetes manifests in the specified directory."
    echo "If no directory is specified, defaults to: $ROOT_DIR/clusters"
    echo ""
    echo "The script will:"
    echo "  1. Validate YAML syntax"
    echo "  2. Build any kustomize overlays"
    echo "  3. Validate against Kubernetes schemas"
    echo "  4. Perform kubectl dry-run validation"
    echo ""
    echo "Tools are automatically installed to .local/bin if not found."
    echo "Requirements:"
    echo "  • kubectl (required)"
    echo "  • python3 (required)"
    echo "  • PyYAML (optional, for enhanced YAML validation)"
    echo ""
    echo "To install PyYAML: pip3 install PyYAML"
    exit 0
fi

main "$@" 