### Install Helm
```
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
```
### Add Helm cilium repo
```
helm repo add cilium https://helm.cilium.io/
helm repo update
```
### Deploy cilium with eBPF enable
```
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set operator.replicas=1 \
    --set kubeProxyReplacement=strict \
    --set externalIPs.enabled=true \
    --set k8sServicePort=6443 \
    --set bpf.hostLegacyRouting=false \
    --set bpf.masquerade=true 
```
**Notes :**

| | |
|--|--|
| ExternalIPs.enabled | Not using kubeproxy |
| kubeProxyReplacement | Allow external IP to access internal |
| bpf.hostLegacyRouting | Using eBPF host routing, to fully bypass iptables |
| bpf.masquerade | eBPF based masquerading |

### Testing create deployment
```
kubectl apply -f https://k8s.io/examples/controllers/nginx-deployment.yaml
kubectl expose deployment nginx-deployment --type=ClusterIP --name=nginx-service
kubectl get svc 
```
### Enable Hubble (observability)
```
helm upgrade cilium cilium/cilium \
    --namespace kube-system \
    --reuse-values \
    --set hubble.enabled=true \
    --set hubble.listenAddress=":4244" \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    --set hubble.metrics.enableOpenMetrics=true \
    --set hubble.metrics.enabled="{dns:query;ignoreAAAA,drop,flow,flows-to-world,httpV2:exemplars=true;labelsContext=source_ip\,source_namespace\,source_workload\,destination_ip\,destination_namespace\,destination_workload\,traffic_direction,icmp,port-distribution,tcp}"
```
```
kubectl -n kube-system rollout restart deployment/cilium-operator
kubectl -n kube-system rollout restart ds/cilium
```
### Enable Metrics & Grafana
```
helm upgrade cilium cilium/cilium \
    --namespace kube-system \
    --reuse-values \
    --set prometheus.enabled=true \
    --set operator.prometheus.enabled=true 
```
```
kubectl -n kube-system rollout restart deployment/cilium-operator
kubectl -n kube-system rollout restart ds/cilium
```
### Deploy Grafana dashboard
```
kubectl apply -f https://raw.githubusercontent.com/cilium/cilium/1.13.0/examples/kubernetes/addons/prometheus/monitoring-example.yaml
```
