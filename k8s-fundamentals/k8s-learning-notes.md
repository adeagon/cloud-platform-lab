## Exercise 1

**What does the Service's selector actually match against?**

A Service selector matches Pod labels, not the Deployment itself. The Service continuously looks for Pods whose labels match its selector and routes traffic to those endpoints.

**What's the difference between ClusterIP, NodePort, and LoadBalancer Service types?**

ClusterIP exposes a Service only inside the cluster. NodePort exposes it on a port on every node. LoadBalancer asks the cloud provider to provision an external load balancer.

**What does the Ingress controller do that the Ingress resource does not?**

An Ingress resource is only a routing specification — it doesn't actually process traffic. The Ingress controller watches those resources and configures something like NGINX or an AWS Application Load Balancer to implement the routing.
