# Shell aliases for kubectl tools
# Source this file in your ~/.zshrc or ~/.bashrc:
#   source /path/to/kind/shell-aliases.sh

# kubectl colorized output
if command -v kubecolor >/dev/null 2>&1; then
  alias k='kubecolor'
  alias kg='kubecolor get'
  alias kd='kubecolor describe'
  alias kapply='kubecolor apply'
  alias kdelete='kubecolor delete'
  alias klogs='kubecolor logs'
  alias kexec='kubecolor exec'
else
  alias k='kubectl'
  alias kg='kubectl get'
  alias kd='kubectl describe'
  alias kapply='kubectl apply'
  alias kdelete='kubectl delete'
  alias klogs='kubectl logs'
  alias kexec='kubectl exec'
fi

# krew plugins
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"

# Short aliases for common kubectl commands
alias kctx='kubectl ctx'    # switch clusters
alias kns='kubectl ns'      # switch namespaces
alias kp='kubectl pods'     # list pods (if you have the pods plugin)
alias ksys='kubectl --namespace=kube-system'

# Quick aliases for this kind cluster
alias kkind="kubectl --context kind-kind"
alias kprod="kubectl --context kind-kind --namespace production"
alias kdev="kubectl --context kind-kind --namespace development"

# Common workflow aliases
alias kall='kubectl get all'
alias kpo='kubectl get pods'
alias ksv='kubectl get svc'
alias knd='kubectl get nodes'
alias kns='kubectl get namespaces'
alias kdep='kubectl get deployments'

# Namespace shortcuts
alias k_default='kubectl --namespace=default'
alias k_kube_sys='kubectl --namespace=kube-system'
alias k_agent_gateway='kubectl --namespace=agentgateway-system'

echo "✅ kubectl aliases loaded (k, kg, kd, kctx, kns, etc.)"
