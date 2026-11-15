# Security controls

Every control below is implemented in this repository. The "Proof" column says how to see it working.

## 1. Mapping to the HIPAA Security Rule (technical safeguards, 45 CFR 164.312)

| Safeguard | What it requires | How MedSecure meets it | Proof |
|---|---|---|---|
| **(a)(1) Access control**: unique user IDs | Each user has an identity | Named staff accounts (`dr.mehta`, `nurse.priya`, `desk.ravi`); the JWT `sub` is the user | `app/src/auth.js` |
| (a)(1) **Minimum necessary** | Users see only what their job needs | Role matrix: receptionist sees no diagnosis or notes; nurse and receptionist see a masked national ID; only doctors may write clinical data | `app/src/routes/patients.js`, tests in `app/test/patients.test.js` |
| (a)(2)(iii) Automatic logoff | Sessions end | Tokens expire after 15 min; logout revokes the token; the UI keeps the token in memory only | `auth.test.js` → "logout revokes the token" |
| (a)(2)(iv) **Encryption** | PHI encrypted at rest | AES-256-GCM per record, bound to the record ID; key only in the K8s Secret; EBS volume encrypted; K8s Secrets encrypted in etcd | `phiCrypto.test.js` → "store keeps no plaintext PHI", `security-checks.sh` §4 |
| **(b) Audit controls** | Record who accessed PHI | JSON audit event per read/create/update/denied access (actor, role, patient ID, IP, request ID; never the PHI itself); K8s API audit log for Secrets, exec and RBAC | `kubectl -n healthcare logs deploy/patient-api \| grep audit` |
| **(c)(1) Integrity** | PHI not improperly altered | GCM authentication tag: any change to stored ciphertext makes decryption fail; input validation rejects malformed data | `phiCrypto.test.js` → "tampered ciphertext is rejected" |
| **(d) Authentication** | Verify identity | scrypt-hashed passwords, constant-time compare, timing-safe for unknown users, lockout after 5 failures, per-IP rate limit, HS256-only JWT (rejects `alg:none` and forged tokens) | `auth.test.js` |
| **(e)(1) Transmission security** | Protect PHI in transit | All access goes through an SSH tunnel (no public web ports); HSTS header. *A real deployment terminates TLS at an ingress (cert-manager / ACM).* | `infra/terraform/security.tf` |
| 164.308(a)(1) **Risk analysis** | Find vulnerabilities | SAST, SCA, IaC scan, container scan, DAST on every commit | Jenkins reports |
| 164.308(a)(6) **Incident response** | Detect and respond | Prometheus alerts for brute force, lockouts, unauthorised access, privilege abuse, bulk PHI reads and CPU anomalies, routed to a security-team inbox | `monitoring/prometheus-rules.yaml`, `scripts/demo/trigger-alerts.sh` |

## 2. Controls by layer

### Infrastructure (Step 1), in `infra/terraform/`
* Dedicated VPC; the VPC's **default security group has no rules** (CIS 5.4).
* Security group: inbound **only TCP 22 from your own /32 addresses**; outbound only 80/443. The `allowed_cidrs` variable refuses `0.0.0.0/0`.
* No public IP by default on the subnet; the instance asks for one explicitly.
* IAM instance role with **one** managed policy (SSM core). It has no S3, EC2 or IAM rights.
* **IMDSv2 required, hop limit 1**, so containers cannot steal the instance credentials (SSRF).
* Root volume **gp3, encrypted**.
* SSH: keys only, no root login, no password authentication (`00-bootstrap.sh`).
* The Terraform IAM user can only create IAM roles named `vle9-*`, and an explicit **Deny** stops it from attaching any policy other than SSM core to them (`vle9-terraform-runner-policy.json`). This prevents privilege escalation through Terraform.
* Downloaded binaries (kubectl, minikube, helm, plugin manager) are checked against their published SHA-256.

### Application (Step 3), in `app/`
* **No hardcoded secrets.** `config.js` has no defaults for secrets and refuses to start if one is missing or weak (JWT ≥ 32 chars, 32-byte key, passwords ≥ 12).
* **Input validation**: strict allow-list schemas (zod `strictObject`) with exact formats for names, phone, national ID, date of birth and blood group; unknown fields are rejected (mass assignment); size limits (10 KB body); no `<`/`>` or control characters in free text.
* **Output encoding**: the UI renders with `textContent`, never `innerHTML`; strict CSP (`script-src 'self'`, no inline code).
* **Headers**: CSP, `frame-ancestors 'none'`, nosniff, HSTS, COOP/COEP/CORP, `Referrer-Policy: no-referrer`, `Permissions-Policy`, `Cache-Control: no-store` (PHI must not be cached), no `X-Powered-By`.
* **Errors**: generic messages only, no stack traces; same 401 for wrong user and wrong password (no account enumeration).
* Forms use POST, so if JavaScript fails, credentials and PHI never end up in URLs (found by ZAP, see VERIFICATION.md).
* Metrics on a **separate port** that is not part of the public Service; labels never contain IDs or PHI.

### Supply chain and pipeline (Steps 4-6, 10)
* Gitleaks scans the **entire Git history** of the built commit.
* `npm ci` from the lockfile with `--ignore-scripts`; `npm audit` gate.
* `trivy fs`: dependency CVEs, secrets in files, and misconfiguration in the Dockerfile, Kubernetes and Terraform files (HIGH/CRITICAL gate).
* SonarQube (JS + IaC) with Quality Gate; a **non-admin** SonarQube user runs the scans.
* Image: pinned base digest, Node 24 LTS, npm/yarn removed, `apk upgrade`, non-root, read-only app files.
* Trivy image gate: fixable HIGH/CRITICAL CVEs, **end-of-life OS**, **end-of-life Node.js**; CycloneDX SBOM archived with every build.
* Tool images pinned (Gitleaks v8.30.1, sonar-scanner 12.4, ZAP 2.17.0, Node by digest).
* Jenkins: setup wizard replaced by Configuration as Code, random admin password, no sign-up, anonymous access disabled, CSRF protection on; all credentials in the Jenkins store (masked in logs).

### Kubernetes (Step 7), in `k8s/` and `scripts/ec2/03-start-minikube.sh`
* **Pod Security Admission `restricted`** on the namespace: root, privileged, host-path and capability-adding pods are rejected by the API server.
* Pod: `runAsNonRoot`, uid 10001, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `drop: [ALL]`, seccomp `RuntimeDefault`, no ServiceAccount token, CPU/memory/ephemeral-storage limits.
* **RBAC**: the app's ServiceAccount has no permissions. `jenkins-deployer` can only create/patch Deployments, ConfigMaps and PDBs and read/update *one* Secret. It cannot delete, exec, change Services, RBAC or NetworkPolicies, or touch other namespaces.
* **Separation of duties**: namespace, RBAC, NetworkPolicies, quotas and Services are applied once by the admin (`k8s/base`); the pipeline applies only `k8s/app`.
* **NetworkPolicies (Calico enforces them)**: default deny in and out; API port open; metrics only from the `monitoring` namespace; egress only DNS, so a compromised pod cannot exfiltrate PHI.
* **Secrets**: generated randomly, synced with server-side apply (no `last-applied` copy), **encrypted in etcd with secretbox**, rotated by re-running `generate-app-secrets.sh --force` (the checksum annotation restarts the pods).
* **API audit log**: Secret and ConfigMap access (metadata only), all writes in `healthcare`, exec/port-forward, RBAC changes.
* ResourceQuota + LimitRange; PodDisruptionBudget; rolling update with `maxUnavailable: 0`; automatic `rollout undo` when a rollout or the DAST stage fails.

### Monitoring (Step 9), in `monitoring/`
| Alert | Detects | Severity |
|---|---|---|
| FailedLoginBurst | > 10 failed logins in 5 min (brute force, credential stuffing) | warning |
| AccountLockedOut | an account hit the lockout threshold | critical |
| UnauthorizedAccessSpike | > 20 requests without a valid token in 5 min | warning |
| PrivilegeEscalationAttempt | > 3 forbidden-role actions in 5 min | critical |
| PHIBulkAccess | > 50 record reads by one role in 5 min (exfiltration) | critical |
| PatientAPIHighCPU | > 80 % of CPU limit for 2 min (overload or crypto-miner) | warning |
| PatientAPIDown, HighErrorRate, PodRestarting, NodeHighCPU | availability | critical/warning |

Security alerts are emailed to `security-team@`, availability alerts to `oncall@` (Mailpit inbox).

## 3. Accepted risks (documented, time-limited)

| Finding | Tool | Why accepted | Production fix |
|---|---|---|---|
| Egress 0.0.0.0/0 on 80/443 (AWS-0104) | Trivy | Package/image registries have huge, changing IP ranges; filtering by domain needs Network Firewall (not affordable on the Free plan). Expires 2027-01-31 in `.trivyignore.yaml` | Egress proxy or AWS Network Firewall with a domain allow-list |
| Instance has a public IP (terraform S6329) | SonarQube | Needed for SSH and egress without a paid NAT gateway; only port 22 from one /32 is open. Mark as *Accepted* in SonarQube with this reason | Private subnet + NAT + SSM Session Manager / VPN |
| VPC flow logs off (AWS-0178, MEDIUM) | Trivy | CloudWatch Logs ingestion costs credits | Enable flow logs to S3/CloudWatch |
| In-memory patient store; lockout counters per pod | design | Keeps the lab on one small instance | Encrypted RDS (KMS) + shared lockout state (Redis) |
| Builds run on the Jenkins controller | design | Single-host lab | Ephemeral build agents |
| Plain HTTP inside the host | design | Traffic stays on the host or in the SSH tunnel | Ingress with TLS (cert-manager), service mesh mTLS |
