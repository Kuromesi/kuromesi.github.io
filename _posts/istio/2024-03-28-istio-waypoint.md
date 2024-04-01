---
title: Istio Waypoint 学习
date: 2024-03-28 13:15:06 +0800
categories: [Cloud Native, Istio]
tags: [istio, waypoint]
author: kuromesi
mermaid: true
---

```go
func WaypointsCollection(Gateways krt.Collection[*v1beta1.Gateway]) krt.Collection[Waypoint] {
	return krt.NewCollection(Gateways, func(ctx krt.HandlerContext, gateway *v1beta1.Gateway) *Waypoint {
        // constants.WaypointGatewayClassName: "istio-waypoint"
		if gateway.Spec.GatewayClassName != constants.WaypointGatewayClassName {
			// Not a gateway
			return nil
		}
		if len(gateway.Status.Addresses) == 0 {
			// gateway.Status.Addresses should only be populated once the Waypoint's deployment has at least 1 ready pod, it should never be removed after going ready
			// ignore Kubernetes Gateways which aren't waypoints
			return nil
		}
		sa := gateway.Annotations[constants.WaypointServiceAccount]
		return &Waypoint{
			Named:             krt.NewNamed(gateway),
			ForServiceAccount: sa,
			Addresses:         getGatewayAddrs(gateway),
		}
	}, krt.WithName("Waypoints"))
}
```

```go
type Collection[T any] interface {
	// GetKey returns an object by it's key, if present. Otherwise, nil is returned.
	GetKey(k Key[T]) *T

	// List returns all objects in the queried namespace.
	// Order of the list is undefined.
	// Note: not all T types have a "Namespace"; a non-empty namespace is only valid for types that do have a namespace.
	List(namespace string) []T

	EventStream[T]
}
```

```yaml
apiVersion: v1
kind: Service
metadata:
  annotations:
    istio.io/for-service-account: bookinfo-productpage
  creationTimestamp: "2024-03-18T06:51:22Z"
  labels:
    gateway.istio.io/managed: istio.io-mesh-controller
  name: bookinfo-productpage-istio-waypoint
  namespace: default
  ownerReferences:
  - apiVersion: gateway.networking.k8s.io/v1beta1
    kind: Gateway
    name: bookinfo-productpage
    uid: 408cfc63-bb0e-43a9-bddf-cde0cf6288b1
  resourceVersion: "5067"
  uid: 47a6fef9-d533-4330-a0f3-5f470b0d1df7
spec:
  clusterIP: 10.96.187.82
  clusterIPs:
  - 10.96.187.82
  internalTrafficPolicy: Cluster
  ipFamilies:
  - IPv4
  ipFamilyPolicy: SingleStack
  ports:
  - appProtocol: tcp
    name: status-port
    port: 15021
    protocol: TCP
    targetPort: 15021
  - appProtocol: hbone
    name: mesh
    port: 15008
    protocol: TCP
    targetPort: 15008
  selector:
    istio.io/gateway-name: bookinfo-productpage
  sessionAffinity: None
  type: ClusterIP
status:
  loadBalancer: {}
```

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  annotations:
    gateway.istio.io/controller-version: "5"
    istio.io/for-service-account: bookinfo-productpage
  creationTimestamp: "2024-03-18T06:51:22Z"
  generation: 1
  name: bookinfo-productpage
  namespace: default
  resourceVersion: "5089"
  uid: 408cfc63-bb0e-43a9-bddf-cde0cf6288b1
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - allowedRoutes:
      namespaces:
        from: Same
    name: mesh
    port: 15008
    protocol: HBONE
...
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  annotations:
    ambient.istio.io/redirection: disabled
    istio.io/for-service-account: bookinfo-productpage
    istio.io/rev: default
    prometheus.io/path: /stats/prometheus
    prometheus.io/port: "15020"
    prometheus.io/scrape: "true"
  creationTimestamp: "2024-03-18T06:51:22Z"
  generateName: bookinfo-productpage-istio-waypoint-9654556ff-
  labels:
    gateway.istio.io/managed: istio.io-mesh-controller
    istio.io/gateway-name: bookinfo-productpage
    pod-template-hash: 9654556ff
    service.istio.io/canonical-name: bookinfo-productpage-istio-waypoint
    service.istio.io/canonical-revision: latest
    sidecar.istio.io/inject: "false"
  name: bookinfo-productpage-istio-waypoint-9654556ff-nxdv7
  namespace: default
  ownerReferences:
  - apiVersion: apps/v1
    blockOwnerDeletion: true
    controller: true
    kind: ReplicaSet
    name: bookinfo-productpage-istio-waypoint-9654556ff
    uid: 01a228a1-cf4d-443c-8564-d76e533e3743
  resourceVersion: "163753"
  uid: 695cf651-2626-4ecf-ba0d-5b804e4ffb78
...
```

通过 `podWorkloadBuilder` 函数遍历所有 pod workload，查找处于相同命名空间中，或者具有相同 service account 的 waypoint 作为 pod 的 waypoint。

```go
func fetchWaypoints(ctx krt.HandlerContext, Waypoints krt.Collection[Waypoint], ns, sa string) []Waypoint {
	return krt.Fetch(ctx, Waypoints,
		krt.FilterNamespace(ns), krt.FilterGeneric(func(a any) bool {
			w := a.(Waypoint)
			return w.ForServiceAccount == "" || w.ForServiceAccount == sa
		}))
}
```