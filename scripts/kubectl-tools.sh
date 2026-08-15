#!/usr/bin/env bash
#
# Install kubectl plugins and tools for better developer experience:
# - kubecolor: colored kubectl output
# - kctx (kubectl-krew): switch between clusters
# - kns (kubectl-krew): switch between namespaces
#
set -euo pipefail

echo "🔧 Installing kubectl plugins and tools..."

# Check if Homebrew is installed
if ! command -v brew >/dev/null 2>&1; then
  echo "❌ Homebrew not found. Please install from https://brew.sh/"
  exit 1
fi

# Install kubecolor
if ! command -v kubecolor >/dev/null 2>&1; then
  echo "📦 Installing kubecolor..."
  brew install kubecolor
else
  echo "✅ kubecolor already installed"
fi

# Install krew (kubectl plugin manager)
if ! kubectl plugin list >/dev/null 2>&1; then
  echo "📦 Installing krew (kubectl plugin manager)..."

  # Set up krew directory structure
  KREW_ROOT="${KREW_ROOT:-$HOME/.krew}"
  PATH="$KREW_ROOT/bin:$PATH"

  # Download and install krew
  cd "$(mktemp -d)"
  curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew-darwin_$(uname -m | tr '[:upper:]' '[:lower:]').tar.gz"
  tar zxvf krew-darwin_*.tar.gz
  ./krew-"darwin_$(uname -m | tr '[:upper:]' '[:lower:]')" install krew

  echo "✅ krew installed"
else
  echo "✅ krew already installed"
fi

# Add krew to PATH if not already there
KREW_ROOT="${KREW_ROOT:-$HOME/.krew}"
export PATH="$KREW_ROOT/bin:$PATH"

# Install kctx and kns plugins
if ! kubectl krew >/dev/null 2>&1; then
  echo "⚠️  krew not found in PATH. Please add this to your shell profile:"
  echo "   export PATH=\"\$HOME/.krew/bin:\$PATH\""
  exit 1
fi

# Install ctx plugin (kctx)
if ! kubectl ctx >/dev/null 2>&1; then
  echo "📦 Installing kubectl-ctx plugin..."
  kubectl krew install ctx
  echo "✅ kubectl-ctx installed"
else
  echo "✅ kubectl-ctx already installed"
fi

# Install ns plugin (kns)
if ! kubectl ns >/dev/null 2>&1; then
  echo "📦 Installing kubectl-ns plugin..."
  kubectl krew install ns
  echo "✅ kubectl-ns installed"
else
  echo "✅ kubectl-ns already installed"
fi

echo ""
echo "✨ Installation complete!"
echo ""
echo "📝 Add these aliases to your ~/.zshrc or ~/.bashrc:"
echo ""
echo "  # kubectl tools"
echo "  alias k='kubecolor'"
echo "  alias kc='kubectl' # fallback if needed"
echo "  export PATH=\"\$HOME/.krew/bin:\$PATH\""
echo ""
echo "🎯 Usage:"
echo "  kubectl get pods              # colored output via kubecolor"
echo "  kubectl ctx                   # switch clusters"
echo "  kubectl ns                    # switch namespaces"
echo ""
