# Demo script and screenshot checklist

Run these after `setup-all.sh` and a green pipeline run. **EC2** = on the instance, **UI** = in the browser through the SSH tunnel.

## 1. Secure pipeline execution

1. UI → Jenkins → `medsecure-devsecops` → latest build → **Stage View** (or *Pipeline Overview*).
   📸 all stages green: Checkout → Secrets Scan → Unit Tests → SCA + IaC Scan → SAST + Quality Gate → Build Image → Container Scan → Deploy → DAST.
2. Build page → **Build Artifacts**: `reports/` (trivy-image.txt, sbom.cdx.json, trivy-fs.json, npm-audit.json, gitleaks.json, junit.xml, zap/zap-report.html).
   📸 *OWASP ZAP Report* link in the left menu; *Test Result* (48 tests).
3. UI → SonarQube → project *MedSecure Patient API (VLE-9)*.
   📸 Quality Gate **Passed**, coverage ≈ 97 %, 0 bugs.
   Open *Issues* → the Terraform finding "Make sure allowing public network access is safe" → **Accept** with the comment from [SECURITY-CONTROLS.md §3](SECURITY-CONTROLS.md#3-accepted-risks-documented-time-limited). 📸 (this is how SAST findings are triaged).

## 2. Vulnerabilities detected early (the gates block bad builds)

| Demo | How | Expected |
|---|---|---|
| **End-of-life base image** | Jenkins → *Build with Parameters* → `BASE_IMAGE=node:18-alpine` | ❌ fails at **Container Scan (Trivy)**: `FAIL: base OS alpine 3.21.3 is END-OF-LIFE`, `FAIL: Node.js 18.20.8 is end-of-life (minimum 22)`. Our Dockerfile's `apk upgrade` + npm removal already removes the fixable CVEs, but an unsupported OS/runtime still cannot be deployed. Deploy never runs; the live app is untouched. 📸 |
| **Handout Dockerfile** | EC2 or laptop: `scripts/demo/vulnerable-image-demo.sh` | handout Dockerfile: `CRITICAL=3 HIGH=43 MEDIUM=55 LOW=38`, EOL OS, EOL Node → BLOCKED (24 fixable HIGH/CRITICAL); hardened Dockerfile: no vulnerabilities → PASSES 📸 |
| **Leaked secret** | on a branch: add a file with a fake AWS key, push, and build that branch (or run `scripts/ci/gitleaks.sh` locally) | ❌ fails at **Secrets Scan**: `generic-api-key`/`aws-access-token`, value REDACTED. Remove the commit (rewrite history) and *rotate* the key |
| **New bug** | introduce an unhandled promise or a hardcoded password in `app/src`, push | ❌ fails at **SAST + Quality Gate**: `QUALITY GATE STATUS: FAILED` (new_violations > 0) |
| **Weakened security header** | remove `frameAncestors` from `app/src/app.js` | ❌ unit tests fail first; if forced through, ZAP rule 10020/10038 → FAIL → **automatic rollback** |

## 3. Secure container deployment

EC2:

```bash
scripts/demo/security-checks.sh
```

📸 the PASS list: PSA rejects a privileged pod; the app runs as uid 10001 with a read-only filesystem; the deployer may patch deployments but not delete, exec, read other secrets or touch kube-system; NetworkPolicies allow the API but block metrics scraping from other namespaces and block internet egress; the Secret is `k8s:enc:secretbox` in etcd; no `last-applied` copy; 401 without a token; security headers.

Useful extra evidence:

```bash
kubectl auth can-i --list -n healthcare --as=system:serviceaccount:healthcare:jenkins-deployer
kubectl -n healthcare get deploy patient-api -o jsonpath='{.spec.template.spec.containers[0].securityContext}' | jq
kubectl -n healthcare rollout history deployment/patient-api      # change-cause = Jenkins build
kubectl -n healthcare logs deploy/patient-api | grep '"type":"audit"' | head   # PHI audit trail
echo cGFzc3dvcmQ= | base64 -d     # why the handout's Secret is not "encrypted"
```

## 4. Monitoring dashboards and alerts

1. UI → Grafana → Dashboards → *MedSecure* → **MedSecure - Healthcare Security Monitoring**. 📸 the quiet baseline.
2. EC2: `scripts/demo/trigger-alerts.sh` (or one scenario at a time: `failed-logins`, `unauthorized`, `forbidden`, `bulk-phi`, `cpu`).
3. Within about 1 minute, Prometheus → **Alerts**: `UnauthorizedAccessSpike`, `PrivilegeEscalationAttempt`, `PHIBulkAccess`, `FailedLoginBurst`, `AccountLockedOut` firing. 📸
4. Grafana: spikes in *Failed logins by reason*, *Unauthorised requests by reason*, *PHI record access*, and the *Active alerts* table. 📸
5. About 3 to 4 minutes later: `PatientAPIHighCPU` (simulated crypto-miner) and the CPU panel above the 80 % line. 📸
6. UI → Mailpit (http://localhost:18025): emails to `security-team@medsecure.local`, later `[RESOLVED]` ones. 📸
7. Alertmanager (http://localhost:19093): alerts grouped by `category` (security vs availability).

Alerts clear by themselves 5 to 15 minutes after the traffic stops (they use 5 to 15 minute windows).

## 5. Application walkthrough (optional, for the report)

UI → http://localhost:18081

* Log in as `desk.ravi` (receptionist): the patient record shows **no diagnosis or notes** ("hidden for your role") and a masked national ID; you can register a patient.
* `nurse.priya`: sees diagnosis, national ID still masked; no edit form.
* `dr.mehta`: full record; *Update clinical record* (re-encrypted, audit-logged).
* Try `<script>` as a first name → rejected by validation. 📸

## Screenshot checklist

- [ ] `terraform apply` output + EC2 console (instance, SG inbound = 22 from /32 only, IAM role with one policy, encrypted volume, IMDSv2 "required")
- [ ] Jenkins pipeline all green (stage view)
- [ ] Jenkins build blocked at Container Scan (`BASE_IMAGE=node:18-alpine`)
- [ ] Trivy report (`trivy-image.txt`) + SBOM artifact
- [ ] SonarQube dashboard (Quality Gate passed) + issue triage
- [ ] ZAP report (0 FAIL)
- [ ] `security-checks.sh` all PASS
- [ ] `kubectl get pods -n healthcare` + `rollout history`
- [ ] Grafana dashboard during the attack simulation
- [ ] Prometheus alerts firing
- [ ] Mailpit alert emails
- [ ] MedSecure UI as receptionist vs doctor (minimum necessary)
