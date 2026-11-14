# Verification report

What was actually run, where, and with what result. Local runs: WSL2 (Ubuntu) + Docker Desktop on the student laptop, 2026-11-14.

## Summary

| Area | Status | Where |
|---|---|---|
| Unit tests (48) + coverage | ✅ passed, 94.7 % lines (SonarQube: 97.2 %) | local, `scripts/ci/unit-tests.sh` |
| Gitleaks stage | ✅ clean history passes; a planted fake AWS key fails the build | local (throwaway Git copy) |
| npm audit + Trivy fs (deps, secrets, IaC) | ✅ 0 HIGH/CRITICAL after fixes (below) | local, `scripts/ci/sca-scan.sh` |
| SonarQube SAST + Quality Gate | ✅ gate PASSED, 0 bugs, 0 code smells; gate FAILED as designed when a new bug was introduced | local SonarQube 26.11 Community, `scripts/ci/sonar-scan.sh` |
| Docker build | ✅ non-root uid 10001, app dir read-only, refuses to start without secrets | local |
| Trivy image gate | ✅ hardened image: 0 vulnerabilities (any severity); handout Dockerfile: CRITICAL 3 / HIGH 43, EOL Alpine, EOL Node → **blocked** | local, `scripts/demo/vulnerable-image-demo.sh` |
| OWASP ZAP baseline | ✅ 0 FAIL, 64 PASS, 2 informational WARN (after one fix, below) | local, against the hardened container |
| Jenkins Configuration as Code | ✅ loads; admin-only access (anonymous → 403); job, SonarQube server and 3 credentials created; credentials encrypted on disk | throwaway local Jenkins 2.580.2 + the project's plugins |
| Jenkinsfile | ✅ "Jenkinsfile successfully validated" (Jenkins declarative linter) | same throwaway Jenkins |
| Alert rules | ✅ `promtool check rules`: 10 rules, SUCCESS | `prom/prometheus:v3.15.0` |
| Terraform | ✅ `fmt`, `init`, `validate`; Trivy + SonarQube IaC scans | local |
| Kubernetes: hardened minikube, RBAC, PSA, NetworkPolicies, etcd encryption, deploy + auto-rollback, DAST on the cluster | ✅ 19/19 security checks + positive controls | local isolated minikube v1.39 profile |
| Monitoring stack (Prometheus, Grafana, Alertmanager) | ✅ on AWS: all 6 security alerts fired and resolved, emails delivered, dashboard provisioned (locally: config validated only, laptop RAM) | see sections below |
| **AWS: Terraform apply, EC2 setup, real Jenkins pipeline** | ✅ 15 resources created; `setup-all.sh` completed; build #1 (manual) and build #2 (**started by an SCM change**) green in all 9 stages | `m7i-flex.large`, ap-south-1, 2026-11-14 |

## Problems the security tools found in this project (and the fixes)

These are real findings from running the pipeline's own gates against the first version of the code. This is the "vulnerabilities detected early" result.

| # | Found by | Finding | Fix |
|---|---|---|---|
| 1 | **Trivy IaC** (KSV-0056, HIGH) | the deployer Role could create/patch **Services**: a compromised pipeline could redirect patient traffic | Services moved to the admin-only `k8s/base`; the deployer has read-only access |
| 2 | Trivy IaC (AWS-0164, HIGH) | subnet gave every instance a public IP | subnet `map_public_ip_on_launch = false`; the instance requests one explicitly |
| 3 | Trivy IaC (AWS-0104, CRITICAL) | egress to 0.0.0.0/0 | accepted risk (80/443 only, registries need it), documented with expiry in `.trivyignore.yaml` |
| 4 | Trivy IaC (KSV-0109, HIGH) | ConfigMap key `TOKEN_TTL_SECONDS` looked like a secret | renamed to `SESSION_TTL_SECONDS` (false positive, but clearer) |
| 5 | **Trivy secret scan** + **Gitleaks** | a literal JWT and a Basic-auth header in the alert demo script | built at runtime from parts; no literal credentials in Git |
| 6 | **Gitleaks** (curl-auth-user) | `curl -u admin:admin` in the SonarQube setup | kept in one variable marked `gitleaks:allow` with the reason (it is SonarQube's public factory default, rotated by that script) |
| 7 | **OWASP ZAP** (10024, FAIL) | HTML forms had no `method`, i.e. GET: without JavaScript, **password, national ID and phone would be sent in the URL** (logs, proxies, history) | all forms `method="post"`, plus a regression unit test |
| 8 | **SonarQube** (S9383, 2 bugs) | promises without error handling (UI click handler, server start-up) | handled; the Quality Gate failed on the first attempted fix until it was correct |
| 9 | SonarQube (kubernetes S6870/S6897) | no ephemeral-storage request/limit | added |
| 10 | Trivy (MEDIUM) | Mailpit without CPU limit, uid ≤ 10000 | CPU limit, uid 10002 |
| 11 | Testing the setup itself | SonarQube refuses webhooks to private addresses (SSRF protection), so the classic `waitForQualityGate` webhook cannot work on one host | the scanner waits for the gate itself (`sonar.qualitygate.wait=true`); SSRF protection stays on |
| 12 | Testing the setup itself | JCasC: `crumbIssuer.excludeClientIPFromCrumb` and `remotingSecurity` no longer exist in current Jenkins | removed |
| 13 | Testing the setup itself | minikube 1.39 switched its default runtime to containerd: `docker load` into the node would fail | image loading uses `ctr images import` (docker fallback kept) |
| 14 | Trivy blind spot | Trivy does not report CVEs in the Node.js binary, and the handout image *with our hardening* scanned clean although Node 18 is EOL | extra gates in `trivy-image.sh`: end-of-life OS and Node.js version |
| 15 | First `terraform apply` | AWS rejects an apostrophe in a security-group rule description ("student's IP"); `plan` cannot detect this | description reworded; re-applied 1 resource |
| 16 | EC2 bootstrap log | Ubuntu 24.04 starts sshd on demand, so `systemctl reload ssh` fails while it is idle (hardening still applied: verified with `sshd -T`) | `systemctl try-reload-or-restart ssh.service` |
| 17 | `05-configure-jenkins.sh` on EC2 | the plugin manager refuses a plugin list file without a `.txt`/`.yaml` name | `mktemp --suffix=.txt` |
| 18 | **Alert demo on AWS** | `PHIBulkAccess` did not fire for 80 reads: the counter series appeared already at 80, so `increase()` saw no change | all PHI counters start at 0 (like the login counters) + regression test; pushed → build #2 → alert fired |
| 19 | Grafana login on AWS | the admin password Secret kept the file's trailing newline, so the real password contained `\n` and could not be typed | Secret created without the newline; Grafana restarted |
| 20 | Disk usage on AWS | root volume 89 % full after setup (scanner images, cluster, 4 GiB swap): 30 GiB is too small | freed 0.9 GiB (minikube cache) → 86 %; resizing to 40 GiB proposed |

Accepted risks that remain are listed in [SECURITY-CONTROLS.md §3](SECURITY-CONTROLS.md#3-accepted-risks-documented-time-limited).

## Measured results

* Image `medsecure-patient-api`: Alpine 3.24.4, Node 24.22.3, runs as `10001:10001`, 108 SBOM components, **0** known vulnerabilities.
* `node:18-alpine` handout build: CRITICAL 3, HIGH 43, MEDIUM 55, LOW 38; Alpine 3.21.3 end-of-life.
* SonarQube: 1,710 lines, coverage 97.2 %, bugs 0, code smells 0, duplications 0 %, 1 accepted vulnerability (public IP).
* ZAP baseline: 64 rules passed, 0 FAIL; WARN: *Non-Storable Content* (intended `no-store`), *Authentication Request Identified* (informational).

## Kubernetes (real cluster, local)

Run on an isolated minikube v1.39.0 profile (Kubernetes v1.37.0, containerd, Calico) started by the project's own `scripts/ec2/03-start-minikube.sh`. Same versions as the EC2 setup.

| Check | Result |
|---|---|
| `03-start-minikube.sh`: Calico, `EncryptionConfiguration`, audit policy, `k8s/base` | ✅ cluster up; all base objects created |
| RBAC proof printed by `make-jenkins-kubeconfig.sh` | ✅ yes: create/patch deployments, get *its* Secret · no: delete, exec, other Secrets, kube-system, rolebindings |
| Secrets encrypted in etcd | ✅ raw etcd value starts with `k8s:enc:secretbox:v1:key1:` |
| `load-image.sh` as a user **without** the minikube profile (the Jenkins path) | ✅ `ctr images import` into containerd, image verified with `crictl` |
| `deploy.sh` with the **jenkins-deployer** kubeconfig + secrets file | ✅ Secret created by server-side apply, 2/2 pods Ready under Pod Security `restricted` |
| ZAP stage against the NodePort (`zap-baseline.sh`, node IP discovered automatically) | ✅ 0 FAIL, 64 PASS |
| `scripts/demo/security-checks.sh` | ✅ **19 passed, 0 failed** |
| Positive controls for the "blocked" checks | ✅ PSA message `violates PodSecurity "restricted:latest"`; metrics reachable from `monitoring` (blocked elsewhere); internet reachable from an unrestricted pod (so the block in `healthcare` is the NetworkPolicy) |
| Automatic rollback (`deploy.sh` with a non-existent image) | ✅ `ImagePullBackOff` → "rolling back" → previous image 2/2 Ready; old pods kept serving the whole time (`maxUnavailable: 0`) |

## Monitoring

| Check | Result |
|---|---|
| Alert rules | ✅ `promtool check rules`: 10 rules, SUCCESS |
| Helm values | ✅ `helm template` of kube-prometheus-stack **93.3.0** renders with `monitoring/kube-prometheus-stack-values.yaml` |
| ServiceMonitor, rules, dashboard ConfigMap, Mailpit | ✅ `kubectl kustomize monitoring/` renders; dashboard JSON valid (18 panels) |
| App metrics | ✅ `/metrics` on port 9464 exposes `auth_login_failures_total`, `auth_unauthorized_requests_total`, `phi_records_accessed_total`, ... (unit test); scraped successfully from the `monitoring` namespace on the cluster |
| Live install on the local cluster | ⚠️ **stopped on purpose**: with Docker Desktop's other containers, the laptop ran out of RAM (swap 100 % used), so the test cluster was deleted to protect the other running containers. The stack is sized for the 8 GiB EC2 host, where `04-install-monitoring.sh` runs it |

Locally only the configuration could be validated; the live run happened on AWS (next section).

## AWS deployment (2026-11-14, ap-south-1)

Infrastructure: `terraform apply` as the least-privilege IAM user `vle9-terraform-user` → 15 resources (VPC, subnet, IGW, route table, locked default SG, SG with SSH from one /32 + egress 80/443, IAM role with only SSM core, encrypted 30 GiB gp3, IMDSv2 hop limit 1, `m7i-flex.large` Ubuntu 24.04).

| Step | Result |
|---|---|
| EC2 bootstrap (user data) | ✅ finished in ~3 min; Docker 29.1, Java 21, Jenkins 2.580.2, Trivy 0.76.2, kubectl 1.37.2, minikube 1.39.0, Helm 4.3.2; `sshd -T`: no root login, no passwords, MaxAuthTries 3 |
| `02-start-sonarqube.sh` | ✅ default admin password rotated, non-admin `jenkins` token |
| `03-start-minikube.sh` | ✅ Calico, RBAC proof as expected, Secrets `k8s:enc:secretbox` in etcd |
| `04-install-monitoring.sh` | ✅ 7 monitoring pods Running, 10 MedSecure rules loaded, both app pods scraped (`up`) |
| `05-configure-jenkins.sh` | ✅ (after fix #17) plugins, admin, 3 credentials, SonarQube server, job; build #1 queued |
| **Build #1** (manual) | ✅ all 9 stages: Gitleaks clean · 48/48 tests · npm audit + Trivy fs clean · Quality Gate PASSED · image gate passed (Alpine 3.24.4, Node 24.22.3) · deployed `1-64c32c6` · ZAP 0 FAIL / 64 PASS · 13 reports archived, ZAP HTML report published |
| **Build #2** | ✅ "**Started by an SCM change**" (pollSCM) after pushing fix #18; all 9 stages green; deployed `2-0ec881a` |
| `security-checks.sh` on EC2 | ✅ 19 passed, 0 failed |
| `trigger-alerts.sh all` | ✅ responses: 401 ×45, 403 ×8, 200 ×80, brute force 401 ×18 then 429 ×12 (rate limit) |
| Alerts firing | ✅ FailedLoginBurst, AccountLockedOut, UnauthorizedAccessSpike, PrivilegeEscalationAttempt, PatientAPIHighCPU (99.85 % of limit), PHIBulkAccess (after fix #18) |
| Alertmanager routing + email | ✅ security alerts → `security-team@`, availability → `oncall@` (a real `PatientAPIDown` before the first deploy, RESOLVED after it); every security alert also sent its RESOLVED email |
| Grafana | ✅ (after fix #19) login works; dashboard "MedSecure - Healthcare Security Monitoring" provisioned in folder MedSecure; Prometheus + Alertmanager data sources |

Expected noise seen during the demo (not bugs): `KubeQuotaFullyUsed` (info, suppressed: the namespace may have exactly one NodePort), `CPUThrottlingHigh` (pending, caused by the CPU-burn demo), `NodeFilesystemSpaceFillingUp` (pending: linear prediction after the image downloads; see fix #20).

Not checked by me: the UIs in a browser through the SSH tunnel (that is your screenshot step, DEMO.md), and the SonarQube "Accept" triage of the public-IP finding.

Test-only adjustments used locally (not in the repo's EC2 path): an isolated minikube profile `vle9-test` with its own `MINIKUBE_HOME`/`KUBECONFIG`; `MINIKUBE_START_ARGS=--base-image=...kicbase:v0.0.51` to reuse an already-downloaded node image (slow network); SonarQube secrets in a scratch directory.
