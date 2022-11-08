![Animation](https://user-images.githubusercontent.com/3519706/200585282-dcbee5c9-dcd9-42d8-b34d-5649ef182f85.gif)

 
```env
resourceGroup="aks-test"
vnet="vnet1"
location="westcentralus"
subscription="############################"
k8s_version="1.24.6"
CLUSTER1=aks1
CLUSTER2=aks2
```

### Create the resource group
```bash
az group create --name $resourceGroup --location $location
```
  

### Create a VNet and a subnet for the cluster1 nodes
```bash
az network vnet create -g $resourceGroup --location $location --name $vnet --address-prefixes 192.168.10.0/24 -o none
```
```bash
az network vnet subnet create -g $resourceGroup --vnet-name $vnet --name nodesubnet --address-prefix 192.168.10.0/24 -o none
``` 

### Create a VNet and a subnet for the cluster2 nodes
```bash
az network vnet create -g "${resourceGroup}" --location "${location}" --name vnet2 --address-prefixes 192.168.20.0/24 -o none
```
```bash
az network vnet subnet create -g "${resourceGroup}" --vnet-name vnet2 --name nodesubnet --address-prefixes 192.168.20.0/24 -o none
```
### Peering virtual networks
```bash
export VNET_ID=$(az network vnet show \
--resource-group $resourceGroup \
--name "${CLUSTER2}-cluster-net" \
--query id -o tsv)
```
```bash
az network vnet peering create \
-g $resourceGroup \
--name "peering-${CLUSTER1}-to-${CLUSTER2}" \
--vnet-name "${CLUSTER1}-cluster-net" \
--remote-vnet "${VNET_ID}" \
--allow-vnet-access
```
### Create AKS cluster1
```bash
az aks create -l ${location} \
-g ${resourceGroup} -n $CLUSTER1 \
--network-plugin none \
--kubernetes-version $k8s_version \
--max-pods 80 \
--node-count 1 \
--vnet-subnet-id "/subscriptions/$subscription/resourceGroups/${resourceGroup}/providers/Microsoft.Network/virtualNetworks/vnet1/subnets/nodesubnet"
```
### Create AKS cluster2
```bash
az aks create -l ${location} \
-g ${resourceGroup} -n $CLUSTER2 \
--network-plugin none \
--max-pods 80 \
--node-count 1 \
--kubernetes-version $k8s_version \
--vnet-subnet-id "/subscriptions/$subscription/resourceGroups/${resourceGroup}/providers/Microsoft.Network/virtualNetworks/vnet2/subnets/nodesubnet"
```
### Permission for virtual network
```bash
Authorize "custom contributer" role to vnet1 fot aks1

Authorize "custom contributer" role to vnet2 fot aks2
```

### Install the Cilium CLI
```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/master/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
```
  
### Login the clusters
```bash
az aks get-credentials --resource-group ${resourceGroup} --name $CLUSTER1
```
```bash
az aks get-credentials --resource-group ${resourceGroup} --name $CLUSTER2
```  

### Install cilium into the cluster
```bash
cilium install --cluster-name $CLUSTER1 --azure-resource-group $resourceGroup --cluster-id 1
```
```bash
cilium install --cluster-name $CLUSTER2 --azure-resource-group $resourceGroup --cluster-id 2
``` 

### Enable Cluster Mesh
```bash
cilium clustermesh enable --context $CLUSTER1
```
```bash
cilium clustermesh enable --context $CLUSTER2
```
  
### Connect Clusters
```bash
cilium clustermesh connect --context $CLUSTER1 --destination-context $CLUSTER2
```  

### Check status of clustermesh
```bash
cilium clustermesh status --context $CLUSTER1 --wait
```
```bash
cilium clustermesh status --context $CLUSTER2 --wait
``` 

###  test cluster mesh
```bash
kubectl create ns testcm --context $CLUSTER1
kubectl apply -n testcm -f https://docs.isovalent.com/v1.10/public/cluster-mesh/cluster-info-deployment.yaml --context $CLUSTER1
```
```bash
kubectl create ns testcm --context $CLUSTER2
kubectl apply -n testcm -f https://docs.isovalent.com/v1.10/public/cluster-mesh/cluster-info-deployment.yaml --context $CLUSTER2
```
```yaml
cat <<EOF  |  kubectl  -n  testcm  apply  -f-
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
```bash
kubectl run netshoot -n testcm -i --tty --image nicolaka/netshoot -- /bin/bash
```
```bash
while true;do curl cluster-info;sleep 0.5;done
```
