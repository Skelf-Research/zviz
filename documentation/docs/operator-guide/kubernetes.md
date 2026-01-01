# Kubernetes Integration

This guide covers deploying ZigViz as a Kubernetes RuntimeClass.

## Overview

ZigViz integrates with Kubernetes through the RuntimeClass API. Pods can select ZigViz as their runtime using the `runtimeClassName` field.

## Prerequisites

- Kubernetes 1.26+
- containerd 1.6+
- ZigViz installed on worker nodes

## Installation

### Step 1: Install ZigViz on Worker Nodes

On each node that will run ZigViz workloads:

```bash
curl -fsSL https://zigviz.io/install.sh | sh
```

### Step 2: Configure containerd

Add ZigViz runtime to containerd configuration:

```bash
cat >> /etc/containerd/config.toml << 'EOF'

# ZigViz Runtime
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zigviz]
  runtime_type = "io.containerd.runc.v2"
  pod_annotations = ["zigviz.io/*"]
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zigviz.options]
    BinaryName = "/usr/local/bin/zigviz"
EOF
```

Restart containerd:

```bash
systemctl restart containerd
```

### Step 3: Label Nodes

Label nodes where ZigViz is available:

```bash
kubectl label nodes <node-name> zigviz.io/enabled=true
```

### Step 4: Create RuntimeClass

```yaml
# zigviz-runtimeclass.yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: zigviz
  labels:
    app.kubernetes.io/name: zigviz
handler: zigviz
overhead:
  podFixed:
    memory: "10Mi"
    cpu: "50m"
scheduling:
  nodeSelector:
    zigviz.io/enabled: "true"
```

```bash
kubectl apply -f zigviz-runtimeclass.yaml
```

## Using ZigViz

### Basic Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-pod
spec:
  runtimeClassName: zigviz
  containers:
  - name: app
    image: alpine:latest
    command: ["sleep", "infinity"]
```

### With Security Profile

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ci-job
  annotations:
    zigviz.io/profile: "ci-runner"
spec:
  runtimeClassName: zigviz
  containers:
  - name: build
    image: node:20
    command: ["npm", "test"]
```

### With Custom Settings

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: custom-pod
  annotations:
    zigviz.io/profile: "minimal"
    zigviz.io/audit: "true"
    zigviz.io/broker-timeout: "5000"
    zigviz.io/strict-mode: "true"
spec:
  runtimeClassName: zigviz
  containers:
  - name: app
    image: my-app:latest
```

## Pod Annotations

| Annotation | Description | Default |
|------------|-------------|---------|
| `zigviz.io/profile` | Security profile name | `default` |
| `zigviz.io/audit` | Enable audit logging | `false` |
| `zigviz.io/broker-timeout` | Broker timeout in ms | `1000` |
| `zigviz.io/strict-mode` | Fail on unknown syscalls | `false` |
| `zigviz.io/network-policy` | Network policy override | (from profile) |

## Deployments and StatefulSets

### Deployment Example

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: secure-app
  template:
    metadata:
      labels:
        app: secure-app
      annotations:
        zigviz.io/profile: "web-server"
    spec:
      runtimeClassName: zigviz
      containers:
      - name: web
        image: nginx:latest
        ports:
        - containerPort: 80
        resources:
          limits:
            memory: "256Mi"
            cpu: "500m"
```

### StatefulSet Example

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: secure-db
spec:
  serviceName: secure-db
  replicas: 3
  selector:
    matchLabels:
      app: secure-db
  template:
    metadata:
      labels:
        app: secure-db
      annotations:
        zigviz.io/profile: "database"
    spec:
      runtimeClassName: zigviz
      containers:
      - name: db
        image: postgres:15
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 10Gi
```

## Jobs and CronJobs

### Job Example

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: build-job
spec:
  template:
    metadata:
      annotations:
        zigviz.io/profile: "ci-runner"
    spec:
      runtimeClassName: zigviz
      restartPolicy: Never
      containers:
      - name: build
        image: golang:1.21
        command: ["go", "build", "-o", "app", "."]
        volumeMounts:
        - name: source
          mountPath: /src
      volumes:
      - name: source
        persistentVolumeClaim:
          claimName: source-code
```

### CronJob Example

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: security-scan
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      template:
        metadata:
          annotations:
            zigviz.io/profile: "scanner"
        spec:
          runtimeClassName: zigviz
          restartPolicy: OnFailure
          containers:
          - name: scanner
            image: aquasec/trivy:latest
            args: ["image", "--exit-code", "1", "myapp:latest"]
```

## Network Policies

ZigViz respects Kubernetes NetworkPolicies and adds its own layer:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: zigviz-pods
spec:
  podSelector:
    matchLabels:
      app: secure-app
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: database
    ports:
    - protocol: TCP
      port: 5432
```

## Resource Management

### Pod Overhead

ZigViz adds overhead to pods:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: zigviz
handler: zigviz
overhead:
  podFixed:
    memory: "10Mi"  # Broker memory
    cpu: "50m"      # Broker CPU
```

### Resource Quotas

Account for overhead in quotas:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: zigviz-quota
  namespace: secure-workloads
spec:
  hard:
    requests.cpu: "10"
    requests.memory: "20Gi"
    limits.cpu: "20"
    limits.memory: "40Gi"
```

## Monitoring

### Prometheus ServiceMonitor

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: zigviz
spec:
  selector:
    matchLabels:
      app: zigviz
  endpoints:
  - port: metrics
    interval: 30s
```

### Grafana Dashboard

Import the ZigViz dashboard from the [Grafana catalog](https://grafana.com/grafana/dashboards/XXXXX).

## Troubleshooting

### Pod Stuck in ContainerCreating

```bash
# Check events
kubectl describe pod <pod-name>

# Check containerd logs
journalctl -u containerd -f

# Check ZigViz logs
kubectl logs -l app.kubernetes.io/name=zigviz
```

### Permission Denied Errors

```bash
# Check profile requirements
zigviz compile --check-host <profile>

# Enable audit mode
kubectl annotate pod <pod-name> zigviz.io/audit=true
```

### Performance Issues

```bash
# Check metrics
kubectl exec -it <pod-name> -- /bin/sh -c "curl localhost:9090/metrics"

# Run diagnostics
zigviz benchmark
```

## See Also

- [containerd Setup](containerd.md)
- [Monitoring](monitoring.md)
- [Performance Tuning](performance.md)
