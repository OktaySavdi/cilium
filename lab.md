### Two Kind Clusters
In this lab, we will create two Kind clusters and mesh them using Cilium.

We'll have two requirements for these clusters:

1-disable default CNI so we can easily install Cilium
2-use disjoint pods and services subnets

### Koornacht Cluster
Let's have a look at the configuration for the first cluster, which we will be calling Koornacht:

cat kind_koornacht.yaml
---
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
networking:
  disableDefaultCNI: true
  podSubnet: 10.1.0.0/16
  serviceSubnet: 172.20.1.0/24
nodes:
- role: control-plane
  extraPortMappings:
  # localhost.run proxy
  - containerPort: 32042
    hostPort: 32042
  # Hubble relay
  - containerPort: 31234
    hostPort: 31234
  # Hubble UI
  - containerPort: 31235
    hostPort: 31235
- role: worker
- role: worker

This cluster will feature one control-plane node and 2 worker nodes, and use 10.1.0.0/16 for the Pod network, and 172.20.1.0/24 for the Services.

Create the Koornacht first cluster with:
kind create cluster --name koornacht --config kind_koornacht.yaml

This usually takes about 1 minute.
Verify that all 3 nodes are up:
kubectl config use kind-koornacht
kubectl get nodes

The nodes are marked as NotReady because there is not CNI plugin set up yet.
Then install Cilium on it:
cilium install --cluster-name koornacht --cluster-id 1 --ipam kubernetes

Let's also enable Hubble for observability, only on the Koornacht cluster:
cilium hubble enable
Verify that everything is fine with:
cilium status

### Tion Cluster
Let's now create a second Kind cluster —which we will call Tion— with the following configuration:

cat kind_tion.yaml
---
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
networking:
  disableDefaultCNI: true
  podSubnet: 10.2.0.0/16
  serviceSubnet: 172.20.2.0/24
nodes:
- role: control-plane
- role: worker
- role: worker

This Tion cluster will also feature one control-plane node and 2 worker nodes, but it will use 10.2.0.0/16 for the Pod network, and 172.20.2.0/24 for the Services.
Create the Tion cluster with:
kind create cluster --name tion --config kind_tion.yaml

Verify that all 3 nodes are up:
kubectl config use kind-tion
kubectl get nodes

Then install Cilium on it:
cilium install --cluster-name tion --cluster-id 2 --ipam kubernetes

Verify that everything is fine with:
cilium status

Now that we have two Kind clusters installed with Cilium, let's get them meshed!

### Enable Cluster Mesh
Enable Cluster Mesh on both clusters with:
cilium clustermesh enable --context kind-koornacht --service-type NodePort
cilium clustermesh enable --context kind-tion --service-type NodePort

🛈 Note

Several types of connectivity can be set up. We're using NodePort in our case as it's easier and we don't have dynamic load balancers available.
For production clusters, it is strongly recommended to use LoadBalancer instead.

Wait for Cluster Mesh to be ready on both clusters:

cilium clustermesh status --context kind-koornacht --wait
cilium clustermesh status --context kind-tion --wait

You can also verify the Cluster Mesh status with cilium status:

cilium status --context kind-koornacht
cilium status --context kind-tion

You should see a ClusterMesh: OK field.

### Mesh Cluster
Let's now connect the clusters by instructing one cluster to mesh with the second one:

cilium clustermesh connect --context kind-koornacht --destination-context kind-tion

Wait for the Koornacht cluster to be ready:

cilium clustermesh status --context kind-koornacht --wait

And similarly for the Tion cluster:

cilium clustermesh status --context kind-tion --wait

Our two clusters are now meshed together. Let's deploy applications on them!

🌌 Deploying an application
We will now deploy a sample application on both Kubernetes clusters.

This application will contain two deployments:

a simple HTTP application called rebel-base, which will return a static JSON document
an x-wing pod which we will use to make requests to the rebel-base service from within the cluster
The only difference between the two deployments will be the ConfigMap resource deployed, which will contain the static JSON document served by rebel-base, and whose content will depend on the cluster.

Are you ready? Let's go!


### Koornacht Cluster
Let's prepare to deploy on the Koornacht Cluster:
kubectl config use kind-koornacht

We will deploy a simple HTTP application returning a JSON, including the name of the cluster:
kubectl apply -f deployment.yaml
cat deployment.yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rebel-base
spec:
  selector:
    matchLabels:
      name: rebel-base
  replicas: 2
  template:
    metadata:
      labels:
        name: rebel-base
    spec:
      containers:
      - name: rebel-base
        image: docker.io/nginx:1.15.8
        volumeMounts:
          - name: html
            mountPath: /usr/share/nginx/html/
        livenessProbe:
          httpGet:
            path: /
            port: 80
          periodSeconds: 1
        readinessProbe:
          httpGet:
            path: /
            port: 80
      volumes:
        - name: html
          configMap:
            name: rebel-base-response
            items:
              - key: message
                path: index.html
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: x-wing
spec:
  selector:
    matchLabels:
      name: x-wing
  replicas: 2
  template:
    metadata:
      labels:
        name: x-wing
    spec:
      containers:
      - name: x-wing-container
        image: docker.io/cilium/json-mock:1.2
        livenessProbe:
          exec:
            command:
            - curl
            - -sS
            - -o
            - /dev/null
            - localhost
        readinessProbe:
          exec:
            command:
            - curl
            - -sS
            - -o
            - /dev/null
            - localhost

The ConfigMap for this service contains the JSON reply, with the name of the Cluster hardcoded (-o yaml is added here to show you the content of the resource):
kubectl apply -f configmap_koornacht.yaml -o yaml
cat configmap_koornacht.yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: rebel-base-response
data:
  message: "{\"Cluster\": \"Koornacht\", \"Planet\": \"N'Zoth\"}\n"

Check that the pods are running properly (launch until all 4 pods are Running):
kubectl get pod

You should see something like:
NAME                          READY   STATUS    RESTARTS   AGE
rebel-base-6985d8f76f-n6qmm   1/1     Running   0          44s
rebel-base-6985d8f76f-rn4ht   1/1     Running   0          44s
x-wing-6d58648f95-2mrpc       1/1     Running   0          40s
x-wing-6d58648f95-nw927       1/1     Running   0          40s

Apply the Service for the application:
kubectl apply -f service.yaml
cat service.yaml 
---
apiVersion: v1
kind: Service
metadata:
  name: rebel-base
spec:
  type: ClusterIP
  ports:
  - port: 80
  selector:
    name: rebel-base

Let's test this service, using the x-wing pod deployed alongside the rebel-base deployment:
kubectl exec -ti deployments/x-wing -- /bin/sh -c 'for i in $(seq 1 10); do curl rebel-base; done'

You should see 10 lines of log, all containing:

{"Cluster": "Koornacht", "Planet": "N'Zoth"}

### Tion Cluster
We will deploy the same application and service on the Tion cluster, with a small difference: the JSON answer will reply with Tion since we're using a slightly different ConfigMap:
kubectl config use kind-tion
kubectl apply -f deployment.yaml
kubectl apply -f configmap_tion.yaml -o yaml
kubectl apply -f service.yaml

cat configmap_tion.yaml 
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: rebel-base-response
data:
  message: "{\"Cluster\": \"Tion\", \"Planet\": \"Foran Tutha\"}\n"

Wait until the pods are ready (run kubectl get po until all pods are Ready) and check this second service:
kubectl exec -ti deployments/x-wing -- /bin/sh -c 'for i in $(seq 1 10); do curl rebel-base; done'

After the pods start, you should see 10 lines of log, all containing:
{"Cluster": "Tion", "Planet": "Foran Tutha"}

We now have similar applications running on both our clusters. Wouldn't it be great if we could load-balance traffic between them? This is precisely what we'll be doing in the next challenge!

![image](https://user-images.githubusercontent.com/3519706/210509708-4f2f2652-83fe-4ee1-922d-6507728681be.png)

![image](https://user-images.githubusercontent.com/3519706/210509802-306f917c-4bf4-49d1-a27a-cf5bcba520bb.png)

![image](https://user-images.githubusercontent.com/3519706/210509963-217cebe0-7d90-425a-bbbd-f0fe9c14c820.png)

### Global Service on Clusters

Let's make the service on the Koornacht cluster global. Add the annotation to the service metadata:
kubectl --context kind-koornacht annotate service rebel-base io.cilium/global-service="true"

The service should still work the same when probed from the Tion cluster:
kubectl --context kind-tion exec -ti deployments/x-wing -- /bin/sh -c 'for i in $(seq 1 10); do curl rebel-base; done'

This should still return only:
{"Cluster": "Tion", "Planet": "Foran Tutha"}

When accessing the service from the Koornacht cluster however, the service should be load-balanced between the two clusters, since the service on the Koornacht cluster is now marked as global:
kubectl --context kind-koornacht exec -ti deployments/x-wing -- /bin/sh -c 'for i in $(seq 1 10); do curl rebel-base; done'

You should see a mix of replies from the Koornacht and Tion clusters:
{"Cluster": "Koornacht", "Planet": "N'Zoth"}
{"Cluster": "Koornacht", "Planet": "N'Zoth"}
{"Cluster": "Koornacht", "Planet": "N'Zoth"}
{"Cluster": "Tion", "Planet": "Foran Tutha"}
{"Cluster": "Tion", "Planet": "Foran Tutha"}
{"Cluster": "Koornacht", "Planet": "N'Zoth"}
{"Cluster": "Tion", "Planet": "Foran Tutha"}

Let's now make the same change on the Tion cluster:
kubectl --context kind-tion annotate service rebel-base io.cilium/global-service="true"

Testing again from the Tion cluster, you should see requests being load-balanced between the two clusters:
kubectl --context kind-tion exec -ti deployments/x-wing -- /bin/sh -c 'for i in $(seq 1 10); do curl rebel-base; done'

The service is now global on both clusters!

### Fault Resilience
With this setup in place, let's scale down the deployment on the Koornacht cluster:
kubectl --context kind-koornacht scale deployment rebel-base --replicas 0

Now check the replies when querying from the Koornacht cluster:
kubectl --context kind-koornacht exec -ti deployments/x-wing -- /bin/sh -c 'for i in $(seq 1 10); do curl rebel-base; done'

And from the Tion cluster:
kubectl --context kind-tion exec -ti deployments/x-wing -- /bin/sh -c 'for i in $(seq 1 10); do curl rebel-base; done'

You should see only entries like:
{"Cluster": "Tion", "Planet": "Foran Tutha"}

You can see that requesting the service on both clusters now only yields answers from the Tion cluster, effectively making up for the missing pods on the Koornacht cluster.
We've now seen how clusters can access all instances of an identical service across meshed cluster. What if we want to remove one specific instance of the service from the global service? We'll see how to do this in the next challenge!

![image](https://user-images.githubusercontent.com/3519706/210511927-1db9eec7-b3eb-492c-9107-2c96f6968902.png)

![image](https://user-images.githubusercontent.com/3519706/210511974-b9658abe-1521-4d26-bcca-052e8337d6c1.png)

### Scale back Service on Koornacht
First, let's scale deployment on the Koornacht cluster back to two:
kubectl --context kind-koornacht scale deployment rebel-base --replicas 2

Verify that the service is properly load-balanced from the Koornacht cluster:
kubectl --context kind-koornacht exec -ti deployments/x-wing -- /bin/sh -c 'for i in $(seq 1 10); do curl rebel-base; done'

And from the Tion cluster:
kubectl --context kind-tion exec -ti deployments/x-wing -- /bin/sh -c 'for i in $(seq 1 10); do curl rebel-base; done'

### Disable Global Service on Koornacht Cluster
Now we want to prevent the Tion cluster from accessing the service running on the Koornacht cluster. Let's add the io.`cilium/shared-service=false` annotation to the service on Koornacht to opt out of the global service:
```
kubectl --context kind-koornacht annotate service rebel-base io.cilium/shared-service="false"
```
From the Koornacht cluster, requests are still load-balanced, as the service is global and the Tion cluster is allowing its service to be shared:
kubectl --context kind-koornacht exec -ti deployments/x-wing -- /bin/sh -c 'for i in $(seq 1 10); do curl rebel-base; done'

From the Tion cluster however, you should only see requests going to the Tion service, since Koornacht is preventing access to its service now:
kubectl --context kind-tion exec -ti deployments/x-wing -- /bin/sh -c 'for i in $(seq 1 10); do curl rebel-base; done'

![image](https://user-images.githubusercontent.com/3519706/210512975-8837b24e-78f6-4910-98cb-48fa864dd73d.png)

![image](https://user-images.githubusercontent.com/3519706/210513090-d398b8d6-b1ee-4cb6-802f-fe64f8e24ecd.png)

### Adding a Local Affinity
Let's consider the Koornacht service, which currently load balances to both clusters.
We would like to make it so that it always sends traffic to the Koornacht pods if available, but sends to the Tion pods if no pods are found on the Koornacht cluster.

In order to achieve this, let's add a new annotation to the Koornacht service:
kubectl --context kind-koornacht annotate service rebel-base io.cilium/service-affinity=local

Test the requests to the Koornacht service, which now only target the Koornacht pods:
kubectl --context kind-koornacht exec -ti deployments/x-wing -- /bin/sh -c 'for i in $(seq 1 10); do curl rebel-base; done'

Now scale down the Koornacht deployment:
kubectl --context kind-koornacht scale deployment rebel-base --replicas 0

And try again:
kubectl --context kind-koornacht exec -ti deployments/x-wing -- /bin/sh -c 'for i in $(seq 1 10); do curl rebel-base; done'

All traffic now goes to the Tion cluster.
When the pods come back up on the Koornacht cluster, the service will send traffic to them again:
```
kubectl --context kind-koornacht scale deployment rebel-base --replicas 2
kubectl --context kind-koornacht rollout status deployment/rebel-base
kubectl --context kind-koornacht exec -ti deployments/x-wing -- /bin/sh -c 'for i in $(seq 1 10); do curl rebel-base; done'
```
ⓘ Note:
The opposite effect can be obtained by using remote as the annotation value.

![image](https://user-images.githubusercontent.com/3519706/210514561-5e40bbab-3b9b-4ba2-85cc-d6d2cc971a68.png)

### Remove Affinity

For this challenge, let's start by removing the local affinity we placed on the Koornacht service earlier:
kubectl --context kind-koornacht annotate service rebel-base io.cilium/service-affinity-

Check that the service balances again to both clusters:
kubectl --context kind-koornacht exec -ti deployments/x-wing -- /bin/sh -c 'for i in $(seq 1 10); do curl --max-time 2 rebel-base; done'

### Default Deny
By default, all communication is allowed between the pods. In order to implement Network Policies, we thus need to start with a default deny rule, which will disallow communication. We will then add specific rules to add the traffic we want to allow.

Adding a default deny rule is achieved by selecting all pods (using `{}` as the value for the `endpointSelector` field) and using empty rules for ingress and egress fields.

However, blocking all egress traffic would prevent nodes from performing DNS requests to Kube DNS, which is something we want to avoid. For this reason, our default deny policy will include an egress rule to allow access to Kube DNS on UDP/53, so all pods are able to resolve service names:

---yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: "default-deny"
spec:
  description: "Default Deny"
  endpointSelector: {}
  ingress:
    - {}
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
          rules:
            dns:
              - matchPattern: "*"
---

Copy this Kubernetes manifest, paste it to the default-deny.yaml using the </> Editor tab, and save it with the 💾 button.

Then head back to the >_ Terminal tab and apply the manifest to both clusters:
kubectl --context kind-koornacht apply -f default-deny.yaml
kubectl --context kind-tion apply -f default-deny.yaml

Now test the requests again:
kubectl --context kind-koornacht exec -ti deployments/x-wing -- /bin/sh -c 'for i in $(seq 1 10); do curl --max-time 2 rebel-base; done'

![image](https://user-images.githubusercontent.com/3519706/210515619-aa8ec763-1d65-4bd3-ad6f-660ad093186a.png)

As expected from the application of the default deny policy, all requests now time out.

### Visualizing with Hubble

We installed Hubble, Cilium's observability component, on the Koornacht cluster.

You can use its CLI to visualize packet drops:
hubble observe --verdict DROPPED

You can see an `x-wing` pod trying to reach out to `rebel-base` pods:
```
Aug  9 21:48:46.993: default/x-wing-577dc9f65c-btpvm:60358 (ID:108306) <> default/rebel-base-77ffc55c87-74cvg:80 (ID:87963) policy-verdict:none DENIED (TCP Flags: SYN)
Aug  9 21:48:46.993: default/x-wing-577dc9f65c-btpvm:60358 (ID:108306) <> default/rebel-base-77ffc55c87-74cvg:80 (ID:87963) Policy denied DROPPED (TCP Flags: SYN)
```
On each of these lines, the `default/x-wing-577dc9f65c-btpvm` client pod is trying to reach the `default/rebel-base-77ffc55c87-74cvg` pod on port TCP/80, sending a `SYN` TCP flag. 
These packets are dropped because of the default deny policy, and the client pod never receives a `SYN-ACK` TCP reply.

### Allowing Cross-Cluster traffic

We want to allow the Koornacht `x-wing` pods to access the `rebel-base` pods on both the local and Tion clusters. Since all traffic is now denied by default, we need to add a new Network Policy to allow this specific traffic.

This `CiliumNetworkPolicy` resource allows the pods with a `name=x-wing` label located in the `koornacht` cluster to reach out to any pod with a `name=rebel-base` label.

---yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: "x-wing-to-rebel-base"
spec:
  description: "Allow x-wing in Koornacht to contact rebel-base"
  endpointSelector:
    matchLabels:
      name: x-wing
      io.cilium.k8s.policy.cluster: koornacht
  egress:
  - toEndpoints:
    - matchLabels:
        name: rebel-base
---
Using the </> Editor tab, save this manifest to `x-wing-to-rebel-base.yaml`, then apply it in the >_ Terminal tab:
kubectl --context kind-koornacht apply -f x-wing-to-rebel-base.yaml

Try the request again:
kubectl --context kind-koornacht exec -ti deployments/x-wing -- /bin/sh -c 'for i in $(seq 1 10); do curl --max-time 2 rebel-base; done'

The requests are still dropped. Our default deny policy blocks both ingress and egress connections for all pods, but the new policy we've added only allows egress connectivity. We also need to allow ingress connections to reach the `rebel-base` pods. 
Let's fix this with a new `CiliumNetworkPolicy` resource:

---yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: "rebel-base-from-x-wing"
spec:
  description: "Allow rebel-base to be contacted by Koornacht's x-wing"
  endpointSelector:
    matchLabels:
      name: rebel-base
  ingress:
  - fromEndpoints:
    - matchLabels:
        name: x-wing
        io.cilium.k8s.policy.cluster: koornacht
---
Using the </> Editor tab, save this manifest to `rebel-base-from-x-wing.yaml`, then apply it in the >_ Terminal tab:
kubectl --context kind-koornacht apply -f rebel-base-from-x-wing.yaml

Now test the service again:
kubectl --context kind-koornacht exec -ti deployments/x-wing -- /bin/sh -c 'for i in $(seq 1 10); do curl --max-time 2 rebel-base; done'

It works, but only partially, as only the requests to the Koornacht cluster go through:
```
curl: (28) Connection timed out after 2000 milliseconds
curl: (28) Connection timed out after 2000 milliseconds
curl: (28) Connection timed out after 2000 milliseconds
{"Cluster": "Koornacht", "Planet": "N'Zoth"}
curl: (28) Connection timed out after 2000 milliseconds
curl: (28) Connection timed out after 2000 milliseconds
{"Cluster": "Koornacht", "Planet": "N'Zoth"}
{"Cluster": "Koornacht", "Planet": "N'Zoth"}
{"Cluster": "Koornacht", "Planet": "N'Zoth"}
curl: (28) Connection timed out after 2001 milliseconds
command terminated with exit code 28
```
This is because we haven't applied any specific policies to the Tion cluster, where the default deny policy was also deployed.

We need to apply the `rebel-base-from-x-wing` Network Policy to the Tion cluster to allow the ingress connection:
kubectl --context kind-tion apply -f rebel-base-from-x-wing.yaml

Test once more:
kubectl --context kind-koornacht exec -ti deployments/x-wing -- /bin/sh -c 'for i in $(seq 1 10); do curl --max-time 2 rebel-base; done'

The requests all go through, and we have successfully secured our service across clusters!




























