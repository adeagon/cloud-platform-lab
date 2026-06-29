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

## Exercise 3

**Why does `kubectl get endpoints` being empty tell you it's a selector problem, not a pod problem?**

The endpoints list is populated by the selector matching pod labels. If pods are Running but endpoints is empty, the only explanation is the selector isn't matching anything — the pods aren't the problem, the label query is. That's the diagnostic logic: healthy pods + empty endpoints = selector mismatch.

**Why is this bug hard to spot?**

Every individual component looks healthy. `kubectl get pods` shows Running. `kubectl get service` shows the Service exists. `kubectl get ingress` shows the Ingress is configured. Nothing is obviously broken until you specifically check `kubectl get endpoints`. Most people's instinct is to look at pods first — and pods look fine. The bug hides in the gap between the Service and the pods.

## Exercise 4

**What is the backoff in CrashLoopBackOff?**

CrashLoopBackOff means the container repeatedly exits shortly after starting, so Kubernetes enters an exponential restart backoff to avoid constantly restarting a broken application.

**Why `--previous`?**

`kubectl logs --previous` shows the logs from the last terminated container instance, not the currently running one. It's useful when a container crashes and restarts quickly, because the current container may not have produced any logs yet.

**Difference between a pod that crashes on startup vs. one that crashes after running a while?**

Startup crash: The application fails during initialization (e.g., missing env var or bad config) and never becomes Ready, so it never serves traffic. Runtime crash: The application starts successfully, becomes Ready, serves traffic, and then crashes later due to issues like memory leaks, bugs, or dependency failures. Users may experience intermittent failures until the pod restarts.

## Exercise 5

**Readiness failing vs liveness failing — why does the difference matter?**

Readiness probe fails: The pod stays running but is removed from the Service's endpoints, so it stops receiving traffic. Liveness probe fails: Kubernetes assumes the application is unhealthy and restarts the container. Readiness protects users from sending traffic to an app that isn't ready, while liveness attempts to recover an application that's become stuck or broken.

**What happens if you set liveness too aggressively?**

If the liveness probe has a timeout or threshold that's too strict, Kubernetes may restart a healthy but slow application, causing unnecessary restart loops, downtime, and instability.

**When would you use a `startupProbe`?**

Use a `startupProbe` for applications that take a long time to start, such as large Java applications, databases, or services performing lengthy initialization. It disables liveness and readiness checks until startup succeeds, preventing Kubernetes from restarting the application before it has finished initializing.
