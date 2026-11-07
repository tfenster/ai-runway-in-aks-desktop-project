# already expected:
# az login
# az extension add --name aks-preview

az group create --name rg-airunway-aksd --location germanywestcentral

az aks create --resource-group rg-airunway-aksd --name aks-airunway-aksd --location germanywestcentral --tier standard --enable-aad --enable-azure-rbac --network-plugin azure --network-plugin-mode overlay --network-dataplane cilium --network-policy cilium --enable-azure-monitor-metrics --enable-oidc-issuer --node-count 3 --node-vm-size Standard_D4s_v5 --no-ssh-key --ssh-access disabled

$AKS_ID = az aks show -g rg-airunway-aksd -n aks-airunway-aksd --query id -o tsv
$ME = az ad signed-in-user show --query id -o tsv
az role assignment create --role "Azure Kubernetes Service RBAC Cluster Admin" --assignee $ME --scope $AKS_ID

az aks get-credentials -g rg-airunway-aksd -n aks-airunway-aksd --overwrite-existing
kubelogin convert-kubeconfig -l azurecli

helm repo add kaito https://kaito-project.github.io/kaito/charts/kaito
helm install kaito-workspace kaito/workspace --version 0.10.0 --namespace kaito-workspace --create-namespace --set featureGates.disableNodeAutoProvisioning=true

kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.7.0/standard-install.yaml
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.6.2/manifests.yaml
istioctl install --set profile=minimal --set values.pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true -y
kubectl create namespace gateway
kubectl apply -f inference-gateway.yaml
helm install body-based-router -n gateway --set provider.name=istio --version v1.5.0 oci://registry.k8s.io/gateway-api-inference-extension/charts/body-based-routing

kubectl apply -f https://raw.githubusercontent.com/ai-runway/airunway/refs/tags/v0.8.0/deploy/controller.yaml
kubectl apply -f https://raw.githubusercontent.com/ai-runway/airunway/refs/tags/v0.8.0/deploy/dashboard.yaml
kubectl apply -f https://raw.githubusercontent.com/ai-runway/airunway/refs/tags/v0.8.0/providers/kaito/deploy/kaito.yaml

kubectl set env deployment/airunway -n airunway-system AUTH_ENABLED=false
kubectl rollout status deployment/airunway -n airunway-system

$WORKSPACE = az alerts-management prometheus-rule-group list -g rg-airunway-aksd --query "[?clusterName=='aks-airunway-aksd'] | [0].scopes[0]" -o tsv
az role assignment create --role "Monitoring Data Reader" --assignee $ME --scope $WORKSPACE