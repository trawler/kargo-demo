# Kargo Demo POC Setup Instructions

This guide walks you through setting up a simplified POC environment in your kargo-demo repo that replicates the production ApplicationSet deployment model for Kargo testing.

## Overview

- **3 Kind Clusters**: kind-kargo-test, kind-prod, kind-stage
- **1 Application**: cert-manager (for simplicity)
- **Architecture**: Management cluster runs ArgoCD → deploys ApplicationSets → ApplicationSets generate Applications → Applications deploy workloads
- **Purpose**: Test Kargo integration with a simplified version of production setup

---

## Directory Structure

Create this structure in your kargo-demo repo:

```
kargo-demo/
├── helm/
│   └── argo-cd-applicationsets/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── applicationset-stage.yaml
│           ├── applicationset-prod.yaml
│           └── applicationset-kargo-test.yaml
└── apps/
    └── argo-cd-applicationsets/
        ├── app-stage.yaml
        ├── app-prod.yaml
        └── app-kargo-test.yaml
```

---

## Step 1: Create Helm Chart Files

### File: `helm/argo-cd-applicationsets/Chart.yaml`

```yaml
apiVersion: v2
name: argo-cd-applicationsets
description: Manages ApplicationSets for multi-cluster deployments
type: application
version: 1.0.0
appVersion: "1.0.0"
```

### File: `helm/argo-cd-applicationsets/values.yaml`

```yaml
global:
  argoApp:
    environment: stage  # Will be overridden per environment
```

---

## Step 2: Create ApplicationSet Templates

### File: `helm/argo-cd-applicationsets/templates/applicationset-stage.yaml`

```yaml
{{ if eq .Values.global.argoApp.environment "stage" }}
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: stage-appset
  namespace: argocd
spec:
  goTemplate: true
  generators:
  - matrix:
      generators:
      - list:
          elements:
          - name: kind-stage
            environment: stage
      - list:
          elements:
          - appName: cert-manager
            appRevision: HEAD
            deletePrevention: false
  template:
    metadata:
      name: '{{ .name }}-{{ .appName }}'
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: https://charts.jetstack.io
        chart: cert-manager
        targetRevision: '{{ .appRevision }}'
        helm:
          releaseName: cert-manager
          values: |
            installCRDs: true
      destination:
        server: https://0.0.0.0:50702
        namespace: cert-manager
      syncPolicy:
        automated:
          prune: false
          selfHeal: true
{{ end }}
```

### File: `helm/argo-cd-applicationsets/templates/applicationset-prod.yaml`

```yaml
{{ if eq .Values.global.argoApp.environment "prod" }}
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: prod-appset
  namespace: argocd
spec:
  goTemplate: true
  generators:
  - matrix:
      generators:
      - list:
          elements:
          - name: kind-prod
            environment: prod
      - list:
          elements:
          - appName: cert-manager
            appRevision: HEAD
            deletePrevention: false
  template:
    metadata:
      name: '{{ .name }}-{{ .appName }}'
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: https://charts.jetstack.io
        chart: cert-manager
        targetRevision: '{{ .appRevision }}'
        helm:
          releaseName: cert-manager
          values: |
            installCRDs: true
      destination:
        server: https://0.0.0.0:50716
        namespace: cert-manager
      syncPolicy:
        automated:
          prune: false
          selfHeal: true
{{ end }}
```

### File: `helm/argo-cd-applicationsets/templates/applicationset-kargo-test.yaml`

```yaml
{{ if eq .Values.global.argoApp.environment "kargo-test" }}
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: kargo-test-appset
  namespace: argocd
spec:
  goTemplate: true
  generators:
  - matrix:
      generators:
      - list:
          elements:
          - name: kind-kargo-test
            environment: kargo-test
      - list:
          elements:
          - appName: cert-manager
            appRevision: HEAD
            deletePrevention: false
  template:
    metadata:
      name: '{{ .name }}-{{ .appName }}'
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: https://charts.jetstack.io
        chart: cert-manager
        targetRevision: '{{ .appRevision }}'
        helm:
          releaseName: cert-manager
          values: |
            installCRDs: true
      destination:
        server: https://127.0.0.1:62085
        namespace: cert-manager
      syncPolicy:
        automated:
          prune: false
          selfHeal: true
{{ end }}
```

---

## Step 3: Create Management Applications

These Applications are deployed on each management cluster and tell ArgoCD to deploy the ApplicationSets.

### File: `apps/argo-cd-applicationsets/app-stage.yaml`

Deploy this on the **kind-stage** cluster:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-cd-applicationsets-stage
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/trawler/kargo-demo.git
    path: helm/argo-cd-applicationsets
    targetRevision: main
    helm:
      values: |
        global:
          argoApp:
            environment: stage
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

### File: `apps/argo-cd-applicationsets/app-prod.yaml`

Deploy this on the **kind-prod** cluster:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-cd-applicationsets-prod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/trawler/kargo-demo.git
    path: helm/argo-cd-applicationsets
    targetRevision: main
    helm:
      values: |
        global:
          argoApp:
            environment: prod
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

### File: `apps/argo-cd-applicationsets/app-kargo-test.yaml`

Deploy this on the **kind-kargo-test** cluster:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-cd-applicationsets-kargo-test
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/trawler/kargo-demo.git
    path: helm/argo-cd-applicationsets
    targetRevision: main
    helm:
      values: |
        global:
          argoApp:
            environment: kargo-test
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

---

## Step 4: Deploy to Each Cluster

### 4.1 Deploy to kind-stage

```bash
# Switch to stage cluster
kubectl config use-context kind-stage

# Create argocd namespace if needed
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Install ArgoCD (if not already installed)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Deploy the ApplicationSet management Application
kubectl apply -f apps/argo-cd-applicationsets/app-stage.yaml
```

### 4.2 Deploy to kind-prod

```bash
# Switch to prod cluster
kubectl config use-context kind-prod

# Create argocd namespace if needed
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Install ArgoCD (if not already installed)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Deploy the ApplicationSet management Application
kubectl apply -f apps/argo-cd-applicationsets/app-prod.yaml
```

### 4.3 Deploy to kind-kargo-test

```bash
# Switch to kargo-test cluster
kubectl config use-context kind-kargo-test

# Create argocd namespace if needed
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Install ArgoCD (if not already installed)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Deploy the ApplicationSet management Application
kubectl apply -f apps/argo-cd-applicationsets/app-kargo-test.yaml
```

---

## Step 5: Verify Setup

### Check ApplicationSets on each cluster

```bash
# Check stage
kubectl config use-context kind-stage
kubectl -n argocd get applicationset

# Check prod
kubectl config use-context kind-prod
kubectl -n argocd get applicationset

# Check kargo-test
kubectl config use-context kind-kargo-test
kubectl -n argocd get applicationset
```

### Check Generated Applications

```bash
# Check stage
kubectl config use-context kind-stage
kubectl -n argocd get applications

# Check prod
kubectl config use-context kind-prod
kubectl -n argocd get applications

# Check kargo-test
kubectl config use-context kind-kargo-test
kubectl -n argocd get applications
```

### Check cert-manager deployment

```bash
# Check stage
kubectl config use-context kind-stage
kubectl -n cert-manager get all

# Check prod
kubectl config use-context kind-prod
kubectl -n cert-manager get all

# Check kargo-test
kubectl config use-context kind-kargo-test
kubectl -n cert-manager get all
```

---

## Step 6: Cluster Server IPs for Reference

These are your actual kind cluster server IPs:

```
kind-kargo-test: https://127.0.0.1:62085
kind-prod:       https://0.0.0.0:50716  (or use 127.0.0.1:50716)
kind-stage:      https://0.0.0.0:50702  (or use 127.0.0.1:50702)
```

If you need to access ArgoCD UI:

```bash
# Port-forward ArgoCD on stage
kubectl config use-context kind-stage
kubectl port-forward -n argocd svc/argocd-server 8080:443

# Then access: https://localhost:8080
```

---

## Troubleshooting

### ApplicationSet not generating Applications

Check the ApplicationSet status:
```bash
kubectl -n argocd describe applicationset stage-appset
```

### Application sync failing

Check Application status:
```bash
kubectl -n argocd describe application kind-stage-cert-manager
```

### cert-manager not deploying

Check if chart exists and is accessible:
```bash
helm search repo jetstack/cert-manager
```

If not added, add the repo:
```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
```

---

## Key Differences from Production

- **Single app**: cert-manager only (vs 20+ in production)
- **Single environment per cluster**: Each kind cluster is its own environment
- **Simplified matrix**: One cluster + one app (vs production's complex matrices)
- **Localhost URLs**: All use localhost/127.0.0.1 (kind clusters are local)
- **Purpose**: Test Kargo integration without full production complexity

---

## Next Steps for Kargo Integration

Once this setup is working:

1. Add Kargo Freight and Analysis templates
2. Create Kargo Stages for promotion workflows (kargo-test → prod → stage)
3. Set up Kargo Promotions to trigger ApplicationSet updates
4. Test cross-cluster promotion scenarios

