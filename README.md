# Kubernetes Cluster Configurations

This repository contains Kubernetes manifests and configurations for various clusters.

## Quick Start

```bash
# Validate all manifests
make validate

# Validate specific directory
make validate-dir DIR=clusters/home-cluster

# Clean up temporary files
make clean
```

## Validation Script
The `clusters/validate.sh` script validates Kubernetes manifests by:

1. **YAML Syntax Validation** - Checks for valid YAML syntax
2. **Kustomize Build** - Builds any kustomize overlays
3. **Schema Validation** - Validates against Kubernetes API schemas
4. **Dry-run Validation** - Tests if manifests would deploy successfully

### Direct Usage

```bash
# Validate all manifests in clusters/
./clusters/validate.sh

# Validate specific directory
./clusters/validate.sh /path/to/manifests

# Show help
./clusters/validate.sh --help
```

### Requirements

- **kubectl** - Required for dry-run validation
- **python3** - Required for YAML validation
- **PyYAML** - Optional, for enhanced validation (`pip install PyYAML`)

The script will automatically download kustomize and kubeconform if needed.

## CI/CD

GitHub Actions automatically validates manifests on:
- Push to main
- Pull requests
- When YAML files in `clusters/` are modified

