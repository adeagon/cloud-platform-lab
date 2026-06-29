## Exercise 1

**What does the Service's selector actually match against?**

A Service selector matches Pod labels, not the Deployment itself. The Service continuously looks for Pods whose labels match its selector and routes traffic to those endpoints.

**What's the difference between ClusterIP, NodePort, and LoadBalancer Service types?**

ClusterIP exposes a Service only inside the cluster. NodePort exposes it on a port on every node. LoadBalancer asks the cloud provider to provision an external load balancer.

**What does the Ingress controller do that the Ingress resource does not?**

An Ingress resource is only a routing specification — it doesn't actually process traffic. The Ingress controller watches those resources and configures something like NGINX or an AWS Application Load Balancer to implement the routing.

## Exercise 2

**Where exactly in `describe` output does the real error appear?**

In the Events section, specifically the `Warning Failed` line which contains the full error message — in this case `not found`. Just checking pod status isn't enough; the actual failure reason is in that line.

**What's the difference between `ErrImagePull` and `ImagePullBackOff`?**

ErrImagePull means Kubernetes tried to pull the image and failed. ImagePullBackOff means it knows it failed and is now waiting with exponential backoff before trying again.

**How would this manifest differently if the image were in a private registry with no pull secret?**

The Events section would show an authorization error — something like `401 Unauthorized` or `pull access denied` — rather than `not found`. That's how you distinguish a missing pull secret from a bad image tag in a real incident.
