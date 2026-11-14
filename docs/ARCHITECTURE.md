# Architecture

## Pipeline: every stage is a gate

```mermaid
flowchart TD
    push["git push (main)"] --> co["Checkout<br/>image tag = build-sha"]
    co --> gl{"Secrets Scan<br/>Gitleaks: full history"}
    gl -- leak --> stop1["❌ blocked"]
    gl --> ut{"Unit Tests<br/>48 tests, coverage"}
    ut -- fail --> stop2["❌ blocked"]
    ut --> sca{"SCA + IaC Scan<br/>npm audit, trivy fs<br/>(deps, secrets, Dockerfile, K8s, Terraform)"}
    sca -- HIGH/CRITICAL --> stop3["❌ blocked"]
    sca --> sast{"SAST + Quality Gate<br/>SonarQube"}
    sast -- gate failed --> stop4["❌ blocked"]
    sast --> build["Build Image<br/>hardened Dockerfile"]
    build --> trivy{"Container Scan<br/>Trivy: CVEs, EOL OS, EOL Node<br/>+ SBOM"}
    trivy -- fail --> stop5["❌ never deployed"]
    trivy --> deploy{"Deploy<br/>jenkins-deployer SA<br/>Secret from Jenkins credentials<br/>rollout status"}
    deploy -- unhealthy --> rb1["↩ rollout undo"]
    deploy --> dast{"DAST<br/>OWASP ZAP baseline"}
    dast -- FAIL rule --> rb2["↩ rollout undo"]
    dast --> live["✅ live in namespace healthcare"]
```

## Runtime: who can talk to whom

```mermaid
flowchart LR
    subgraph internet["Internet"]
      you["You (one /32)"]
      gh["GitHub, registries"]
    end
    subgraph sg["Security group"]
      direction TB
      ssh["22/tcp in, from /32 only"]
      out["80, 443 out only"]
    end
    you --> ssh
    out --> gh
    subgraph host["EC2 host (localhost only)"]
      jenkins[":8080 Jenkins"]
      sonar[":9000 SonarQube"]
      pf["port-forwards :8081 :3000 :9090 :9093 :8025"]
    end
    ssh -. "SSH tunnel" .-> jenkins & sonar & pf
    subgraph k8s["minikube"]
      subgraph hc["healthcare (PSA restricted, default deny)"]
        api["patient-api :3000 (API) / :9464 (metrics)"]
      end
      subgraph mon["monitoring"]
        prom["Prometheus"]
      end
      other["any other namespace"]
    end
    pf --> api
    prom -- ":9464 allowed" --> api
    other -- ":3000 allowed" --> api
    other -. ":9464 blocked" .-x api
    api -. "egress except DNS blocked" .-x gh
```

## Data protection path for one patient record

1. A receptionist registers a patient: browser → `POST /api/patients` with a Bearer JWT (memory only, 15 min).
2. `authenticate` checks the HS256 signature, issuer, audience, expiry, revocation and the role. `authorize('doctor','receptionist')` checks the role.
3. The zod `strictObject` schema validates every field; unknown fields are rejected.
4. `store.create` encrypts the whole record with AES-256-GCM (random IV, record ID as AAD). Only ciphertext stays in memory.
5. An audit event `{action:create, actor, role, patientId}` is written, and the `phi_records_accessed_total` counter goes up.
6. A later read is decrypted for the response and filtered by role (minimum necessary).

The encryption key exists only in the Kubernetes Secret (encrypted in etcd), which only the pod (as an env var) and the `jenkins-deployer` ServiceAccount can read.
