# Shell aliases for kubectl tools (see scripts/kubectl-tools.sh).
# Source this file in your ~/.zshrc or ~/.bashrc:
#   source /path/to/kind/shell-aliases.sh

# kubectl (colorized when kubecolor is installed)
if command -v kubecolor >/dev/null 2>&1; then
  K=kubecolor
else
  K=kubectl
fi
alias k="$K"
alias kg="$K get"
alias kd="$K describe"
alias kapply="$K apply"
alias kdelete="$K delete"
alias klogs="$K logs"
alias kexec="$K exec"

# krew plugins (installed via scripts/kubectl-tools.sh)
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
alias kctx='kubectl ctx'    # switch clusters
alias kns='kubectl ns'      # switch namespaces

# Shortcuts for common commands and this repo's cluster
alias kall="$K get all"
alias kpo="$K get pods"
alias ksv="$K get svc"
alias knd="$K get nodes"
alias kdep="$K get deployments"
alias kkind="kubectl --context kind-kind"
alias kgw="kubectl --context kind-kind -n agentgateway-system"

echo "kubectl aliases loaded (k, kg, kd, kctx, kns, kkind, kgw, ...)"
