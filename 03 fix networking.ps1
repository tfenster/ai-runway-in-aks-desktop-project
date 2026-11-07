kubectl apply -f .\network-policy.yaml
.\fix-gateway-model-names.ps1 -Namespace llm-demo
kubectl apply -f .\network-policy-chat.yaml