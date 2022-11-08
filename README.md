
# Cilium ClusterMesh

### Install the Cilium CLI

Install the latest version of the Cilium CLI. The Cilium CLI can be used to install Cilium, inspect the state of a Cilium installation, and enable/disable various features (e.g. clustermesh, Hubble).

```bash
curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm cilium-linux-amd64.tar.gz{,.sha256sum}
```
### Install helm
```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
```
To load completions in your current shell session:
```bash
source <(helm completion bash)
```
### Certificate for clustermesh
```bash
mkdir certDir/;cd certDir/

chmod +x kind-cilium-clustermesh.sh
./kind-cilium-clustermesh.sh

rm -rf remote-csr.pem
```
**Get the nodes IPs on both clusters:**
```bash
kubectl get nodes -owide 
```
Cluster1

![image](https://user-images.githubusercontent.com/3519706/158369583-50eae282-d0c3-4623-8959-71eb774688eb.png)

![image](https://user-images.githubusercontent.com/3519706/158369967-7ce85690-9bd8-4aae-b518-05530660fba4.png)


Cluster2

![image](https://user-images.githubusercontent.com/3519706/158369663-4b6777a3-ff5f-48f5-9a4e-100319b347a9.png)

![image](https://user-images.githubusercontent.com/3519706/158369842-86f3e9e4-1d61-42f3-b0f9-8bf7c5aaf762.png)


**Certificate information is added to cluster1-2.yml files**
```bash
vi cluster1.yml and vi cluster2.yml

cat certDir/cilium-ca-crt.pem | base64 | tr -d "\n"
cat certDir/cilium-ca-key.pem | base64 | tr -d "\n"
cat certDir/remote-crt.pem | base64 | tr -d "\n"
cat certDir/remote-key.pem | base64 | tr -d "\n"
```
![image](https://user-images.githubusercontent.com/3519706/158368463-42143440-dacd-4f5d-a177-35c2aea02e66.png)

**Add Helm repo for Cilium**
```bash
helm repo add cilium https://helm.cilium.io/
helm repo add isovalent https://helm.isovalent.com
helm repo update
```

**Run helm on both clusters:**
```bash
cluster1
helm upgrade --install cilium-enterprise isovalent/cilium-enterprise --version 1.10.8+3 --namespace kube-system -f cluster1.yml 

cluster2
helm upgrade --install cilium-enterprise isovalent/cilium-enterprise --version 1.10.8+3 --namespace kube-system -f cluster2.yml 
```

### Deploy Application
```bash
kubectl create ns testcm
kubectl apply -n testcm -f https://docs.isovalent.com/v1.10/public/cluster-mesh/cluster-info-deployment.yaml
```
```bash
cat <<EOF | kubectl -n testcm apply -f-
---
apiVersion: v1
kind: Service
metadata:
  annotations:
    # Make this a global service!
    io.cilium/global-service: "true"
  name: cluster-info
spec:
  selector:
    app.kubernetes.io/name: cluster-info
  type: ClusterIP
  ports:
  - port: 80
    targetPort: http
EOF
```
**Test clustermesh**
```bash
kubectl run netshoot -n testcm  -i --tty --image nicolaka/netshoot -- /bin/bash  
```
```bash
while true;do curl cluster-info;done
```
