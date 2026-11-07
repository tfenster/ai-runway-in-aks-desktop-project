$NS = "llm-demo"
$AKS_ID = az aks show -g "rg-airunway-aksd" -n "aks-airunway-aksd" --query id -o tsv

az role assignment create --role "Azure Kubernetes Service Cluster User Role" --assignee $ME --scope $AKS_ID
az role assignment create --role "Azure Kubernetes Service Namespace User" --assignee $ME --scope "$AKS_ID/namespaces/$NS"
az role assignment create --role "Azure Kubernetes Service RBAC Writer" --assignee $ME --scope "$AKS_ID/namespaces/$NS"

kubectl apply -f limitrange.yaml -n $NS
