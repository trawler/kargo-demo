# Kargo Promotion Flow POC

This document describes the complete promotion flow for applications in the kargo-demo repository, including the GitOps-based promotion process across multi-region deployments.

## Table of Contents

1. [Kargo Terminology](#1-kargo-terminology)
2. [Architecture Overview](#2-architecture-overview)
3. [Implementation Details](#3-implementation-details)
4. [Promotion Flow](#4-promotion-flow)

---

## 1. Kargo Terminology

### Warehouse = Application Watcher

A **Warehouse** is a subscription configuration that watches for changes to specific artifacts in our Git repository:

```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Warehouse
metadata:
  name: cert-manager-warehouse
spec:
  subscriptions:
    - git:
        repoURL: https://github.com/org/kargo-demo.git
        branch: main
        includePaths:
          - helm/cert-manager  # Watches only this app
```

### Stage = Environment + Deployment Workflow

A **Stage** represents a deployment target with its promotion logic:

```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: cert-manager-stage
spec:
  subscriptions:
    warehouse: cert-manager-warehouse  # Listens to this watcher
  promotionTemplate:
    # HOW to promote (extract version, create tag, deploy, etc.)
  autoPromotionEnabled: true
```

### Freight = Deployable Snapshot

**Freight** is a snapshot of artifact versions that represents a deployable unit:

- Git commit SHA + tag/branch
- Container image tags  
- Helm chart versions

---

## 2. Architecture Overview

### Multi-Region Setup

**Stage Region:**

- Separate Kargo installation
- Watches `main` branch for changes
- Auto-promotes and creates Git tags via API
- Deploys to stage clusters

**Prod Region:**

- Separate Kargo installation (independent from stage)
- Watches Git tags
- Requires manual approval
- Updates ApplicationSet files
- Deploys to prod clusters

**Communication:** The two Kargo instances communicate only through Git. Stage creates tags, prod watches tags.

### Per-App Resources

**Each application has dedicated Kargo resources with path/tag filtering:**

#### Stage Region (per app)

```yaml
# Warehouse - watches specific app paths
apiVersion: kargo.akuity.io/v1alpha1
kind: Warehouse
metadata:
  name: cert-manager-warehouse
spec:
  subscriptions:
    - git:
        repoURL: https://github.com/org/kargo-demo.git
        branch: main
        includePaths:
          - helm/cert-manager  # Only this app

---
# Stage - auto-promotes, creates tag
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: cert-manager-stage
spec:
  subscriptions:
    warehouse: cert-manager-warehouse
  promotionTemplate:
    spec:
      vars:
        - name: appName
          value: cert-manager  # Hardcoded per Stage
      steps:
        - task:
            name: create-git-tag
            kind: PromotionTask
  autoPromotionEnabled: true
```

#### Prod Region (per app)

```yaml
# Warehouse - watches specific app tags
apiVersion: kargo.akuity.io/v1alpha1
kind: Warehouse
metadata:
  name: cert-manager-warehouse
spec:
  subscriptions:
    - git:
        repoURL: https://github.com/org/kargo-demo.git
        allowTags: ^cert-manager-v[0-9]+\.[0-9]+\.[0-9]+$  # Only this app's tags

---
# Stage - manual approval, updates ApplicationSet
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: cert-manager-prod
spec:
  subscriptions:
    warehouse: cert-manager-warehouse
  promotionTemplate:
    spec:
      vars:
        - name: appName
          value: cert-manager
      steps:
        - task:
            name: update-applicationset
            kind: PromotionTask
  autoPromotionEnabled: false  # Manual approval required
```

---

## 3. Implementation Details

### Tag Creation via Git Platform API

**Challenge:** Kargo doesn't have a native `git-tag` promotion step.

**Solution:** Use Kargo's `http` step to call GitLab/GitHub API:

```yaml
- uses: http
  config:
    url: https://api.github.com/repos/trawler/kargo-demo/git/refs
    method: POST
    headers:
      Authorization: Bearer ${{ vars.githubToken }}
      Accept: application/vnd.github.v3+json
    body: |
      {
        "ref": "refs/tags/cert-manager-v1.18.1",
        "sha": "${{ commitFrom(vars.repoURL).ID }}"
      }
```

**Why this works:**

- Kargo's `http` step is designed for external integrations
- Creates real Git tags (immutable)
- Prod warehouse can use `allowTags` pattern matching
- Enables multi-region Kargo deployments

### How Stage Knows Which Tag to Create

**App name:** Hardcoded in Stage's `vars.appName` (each app has its own Stage)

**Version:** Dynamically extracted from `Chart.yaml` using `yaml-parse`:

```yaml
- uses: yaml-parse
  as: parse-version
  config:
    path: ./repo/helm/${{ vars.appName }}/Chart.yaml
    outputs:
      - name: depVersion
        fromExpression: dependencies[0].version
      - name: chartVersion
        fromExpression: version
```

**Tag composition:** `{appName}-{version}` → `cert-manager-v1.18.1`

### Version Extraction Logic

Version extraction uses Kargo's [`yaml-parse`](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/yaml-parse) step to extract version information from `Chart.yaml`.

**Configuration:**

Each app configures its `fromExpression` in the stage configuration. The `yaml-parse` step extracts the version using the configured expression:

```yaml
- uses: yaml-parse
  as: parse-version
  config:
    path: './helm/cert-manager/Chart.yaml'
    outputs:
    - name: version
      fromExpression: dependencies[0].version
```

**Example for cert-manager:**

- `fromExpression: dependencies[0].version` extracts `"v1.18.1"` from Chart.yaml
- Final tag: `cert-manager-v1.18.1`

**Note:** The `fromExpression` is configured per app in the stage settings, and the actual tag creation will be handled in the `create-git-tag` PromotionTask using Kargo's built-in promotion steps.

### ApplicationSet Update

Updates ApplicationSet files using `yaml-update` step:

```yaml
- uses: yaml-update
  config:
    path: ./repo/applicationset/applicationset-prod-control-control.yaml
    updates:
      - key: .spec.generators[0].list.elements[] | select(.appName == "cert-manager") | .appRevision
        value: cert-manager-v1.18.1
```

---

## 4. Promotion Flow

### High-Level Flow

```
┌─────────────────────────────────────────────────────────────┐
│  Developer commits version update to main branch            │
│  Example: "chore(cert-manager): bump version to v1.18.1"    │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  Stage Region: Warehouse (cert-manager-warehouse)           │
│  - Watches main with includePaths: [helm/cert-manager]      │
│  - Detects change, creates Freight                          │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  Stage Region: Stage (cert-manager-stage)                   │
│  1. Auto-promotes (no approval needed)                      │
│  2. Extracts version from Chart.yaml                        │
│  3. Creates tag via GitLab/GitHub API                       │
│  4. Deploys to stage clusters                               │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  Prod Region: Warehouse (cert-manager-warehouse)            │
│  - Watches tags: ^cert-manager-v[0-9]+\.[0-9]+\.[0-9]+$     │
│  - Detects new tag, creates Freight                         │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  Prod Region: Stage (cert-manager-prod)                     │
│  1. Waits for manual approval                               │
│  2. Extracts tag name from Freight                          │
│  3. Updates ApplicationSet files                            │
│  4. Commits to main branch                                  │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  ArgoCD ApplicationSet                                      │
│  - Detects ApplicationSet change                            │
│  - Syncs application to prod clusters                       │
└─────────────────────────────────────────────────────────────┘
```

### Stage Promotion (Auto-promoted)

**Trigger:** Commit to `main` that changes `helm/cert-manager/`

**Process:**

1. Warehouse creates Freight (path filter ensures only cert-manager triggers)
2. Stage auto-promotes:
   - Clones repo at commit from Freight
   - Extracts version from `helm/cert-manager/Chart.yaml`
   - Composes tag: `cert-manager-{version}`
   - Creates tag via Git platform API (GitLab/GitHub)
3. (Optional) Deploys to stage clusters via ArgoCD integration

**Result:** Git tag `cert-manager-v1.18.1` created

**PromotionTask:** `create-git-tag`

### Prod Promotion (Manual approval)

**Trigger:** New tag `cert-manager-v1.18.1` detected

**Process:**

1. Warehouse creates Freight (tag filter ensures only cert-manager tags trigger)
2. Admin approves via Kargo UI
3. Prod promotes:
   - Clones repo at `main` branch
   - Extracts tag name from Freight
   - Updates ApplicationSet files:
     - Sets `appRevision: cert-manager-v1.18.1`
   - Commits and pushes to `main`
4. ArgoCD syncs to prod clusters

**Result:** Prod clusters deploy from tag `cert-manager-v1.18.1`

**PromotionTask:** `update-applicationset`
