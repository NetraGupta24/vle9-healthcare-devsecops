# Viva questions and answers

**1. What is DevSecOps, and how is it different from DevOps?**
DevOps automates build → test → deploy. DevSecOps adds automated security checks to every stage ("shift left"), so security problems are found minutes after a commit instead of in an audit months later. Here, 6 of the 9 pipeline stages are security gates.

**2. What is PHI and why does it need special handling?**
Protected Health Information: any health data linked to a person (name + diagnosis, national ID, phone...). HIPAA (US), and the DPDP Act / DISHA guidelines (India), require access control, audit trails, integrity, authentication and encryption. A leak harms patients and brings large fines.

**3. SAST vs DAST vs SCA vs container scanning?**
* **SAST** (SonarQube) reads the *source code* without running it: bugs, injection patterns, IaC mistakes.
* **DAST** (OWASP ZAP) attacks the *running app* from outside: missing headers, information leaks, insecure forms.
* **SCA** (npm audit, trivy fs) checks *third-party dependencies* against CVE databases.
* **Container scanning** (Trivy image) checks *everything inside the image*: OS packages, runtime, libraries, baked-in secrets.
They find different things. In this lab, for example, only ZAP found that the HTML forms used GET.

**4. Why does the pipeline fail instead of just reporting?**
A report nobody reads protects nothing. `--exit-code 1` (Trivy), the Quality Gate (SonarQube) and FAIL rules (ZAP) make a vulnerable build impossible to deploy. Exceptions must be written down (`.trivyignore.yaml`) with a reason and an expiry date.

**5. Why is the handout's Secret YAML insecure?**
`cGFzc3dvcmQ=` is just base64 for `password`: anyone can decode it, and once it is committed it stays in Git history forever. Here, secrets are generated randomly, kept in the Jenkins credential store, injected at deploy time, encrypted inside etcd, and readable only by the app and the deployer ServiceAccount.

**6. How is patient data encrypted?**
At rest: each record is encrypted with AES-256-GCM (random IV, record ID as additional authenticated data), so the store only ever holds ciphertext. GCM also detects tampering. The key lives only in a Kubernetes Secret that is itself encrypted in etcd; the EC2 disk is encrypted too. In transit: everything goes through an SSH tunnel (production would use TLS at an ingress).

**7. What does RBAC least privilege look like here?**
Two levels:
* App users: doctor / nurse / receptionist see different fields (minimum necessary).
* Kubernetes: the Jenkins ServiceAccount can patch the Deployment and update one Secret, nothing more. It cannot delete, exec into pods, read other secrets, or change Services, RBAC or NetworkPolicies. `kubectl auth can-i` proves it.

**8. Why does the Docker image run as non-root with a read-only filesystem?**
If an attacker exploits the app, they get the process's privileges. As uid 10001 with no capabilities, no privilege escalation and a read-only root filesystem, they cannot install tools, change the code or escape easily. Pod Security Admission `restricted` makes the API server reject any pod that does not follow these rules.

**9. Why is the image built on Node 24 instead of the handout's Node 18?**
Node 18 and its Alpine 3.21 base are end-of-life (no security patches). The handout image has 3 CRITICAL and 43 HIGH CVEs; ours has 0. Trivy does not see CVEs in the Node binary itself, so the pipeline also checks the Node version.

**10. What do NetworkPolicies add?**
By default every pod can talk to every pod and to the internet. Default-deny plus a few explicit allows means: only Prometheus can read metrics, and app pods cannot open outbound connections, so stolen data cannot be sent out directly. They need a CNI that enforces them (Calico); minikube's default network plugin ignores them.

**11. Which attacks do the alerts detect?**
Brute force / credential stuffing (failed-login burst, lockouts), token forgery or scanning (unauthorised spike), insider misuse (forbidden-role attempts), data exfiltration (bulk PHI reads) and crypto-mining (sustained CPU), plus downtime and errors. `scripts/demo/trigger-alerts.sh` simulates each one.

**12. Why only port 22 in the security group?**
Every web UI is reached through an SSH tunnel, so admin consoles are never exposed to the internet, traffic is encrypted, and only your key and your IP can connect. IMDSv2 with hop limit 1 also stops a compromised container from stealing the instance's IAM credentials.

**13. What would you change for production?**
Managed Kubernetes (EKS) with private nodes; RDS with KMS for data; TLS ingress; AWS Secrets Manager / External Secrets; ECR with image signing (cosign) and an admission policy that only allows signed images; separate build agents; staging + production environments; WAF; centralised logs (CloudWatch / SIEM); VPC flow logs; egress through a filtering proxy.

**14. What is an SBOM and why does healthcare care?**
A Software Bill of Materials lists every component inside the image (here CycloneDX, 108 components). When a new CVE appears you can tell instantly whether you are affected. Regulators such as the FDA now require SBOMs for medical-device software.
