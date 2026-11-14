# Running the full lab on AWS

Time: about 45 minutes, most of it waiting for installs. Cost: about USD 0.10 per hour while the instance runs (Free-plan credits).

Commands marked **laptop** run in WSL on your machine; **EC2** run on the instance over SSH.

---

## 0. One-time prerequisites

### 0.1 A least-privilege IAM user for Terraform (AWS console, signed in as root)

Never create access keys for the root account. Instead, create one IAM user that can do exactly what VLE-9 needs and nothing else:

1. **Policy:** IAM → Policies → **Create policy** → JSON → replace the editor contents with [`infra/terraform/vle9-terraform-runner-policy.json`](../infra/terraform/vle9-terraform-runner-policy.json) (in WSL, `clip.exe < infra/terraform/vle9-terraform-runner-policy.json` copies it to the clipboard) → Next → name `VLE9TerraformRunner` → Create policy.
2. **User:** IAM → Users → **Create user** → name `vle9-terraform-user`, *no* console access → Attach policies directly → tick `VLE9TerraformRunner` → Create user.
3. **Access key:** open the user → Security credentials → **Create access key** → use case *Command Line Interface (CLI)* → Create → copy both values (the secret is shown only once).
4. **Laptop:** `aws configure` → paste the two values, region `ap-south-1`, output `json`. Check with `aws sts get-caller-identity`: the `Arn` must end in `user/vle9-terraform-user`.

The policy allows EC2 in Mumbai and IAM only on `vle9-*` roles and instance profiles. An explicit **Deny** stops it from attaching any policy except `AmazonSSMManagedInstanceCore`, so the Terraform user cannot create an admin role for itself. Never paste the secret access key into chats, files in the repo, or screenshots.

### 0.2 SSH key (laptop)

```bash
ssh-keygen -t ed25519 -f ~/.ssh/vle9-key -N '' -C vle9
```

### 0.3 GitHub repository (laptop)

Jenkins on EC2 pulls the code from GitHub. Create an **empty public** repository (for example `vle9-healthcare-devsecops`), then push:

```bash
cd ~/VLE-9-Healthcare-DevSecOps
git init -b main && git add -A && git commit -m "VLE-9 secure DevSecOps pipeline"
git remote add origin git@github.com:NetraGupta24/vle9-healthcare-devsecops.git
git push -u origin main
```

Public is fine: the repo contains no secrets (Gitleaks verifies this on every build), and all patient data is synthetic.

---

## 1. Step 1: create the secure infrastructure (laptop)

```bash
cd ~/VLE-9-Healthcare-DevSecOps/infra/terraform
cp terraform.tfvars.example terraform.tfvars
echo "allowed_cidr = \"$(curl -s https://checkip.amazonaws.com)/32\"" > terraform.tfvars
terraform init
terraform plan -out tfplan        # review: 15 to add, 0 to change, 0 to destroy
terraform apply tfplan
terraform output
```

Created: VPC, subnet, internet gateway, route table + association, locked default SG, security group + 3 rules (SSH in, 80/443 out), IAM role + policy attachment + instance profile, key pair, EC2 instance.

The instance installs everything on first boot (about 8 to 12 minutes). Watch it:

```bash
ssh -i ~/.ssh/vle9-key ubuntu@$(terraform output -raw public_ip) 'tail -f /var/log/medsecure-bootstrap.log'
# wait for: === bootstrap done
```

## 2. Steps 2-10: set up the tools and run the pipeline (EC2)

```bash
ssh -i ~/.ssh/vle9-key ubuntu@<public_ip>
git clone https://github.com/<your-user>/vle9-healthcare-devsecops.git medsecure
cd medsecure
scripts/ec2/setup-all.sh https://github.com/<your-user>/vle9-healthcare-devsecops.git
```

`setup-all.sh` runs these in order (each can also be run by itself, and all are safe to re-run):

| Script | What it does |
|---|---|
| `00-bootstrap.sh` | (already ran as EC2 user data) packages, Docker, Jenkins, Trivy, kubectl, minikube, Helm |
| *01* | the `git clone` above (manual) |
| `02-start-sonarqube.sh` | SonarQube + PostgreSQL; rotates `admin/admin`; creates a non-admin `jenkins` user + token |
| `03-start-minikube.sh` | minikube with Calico, etcd Secret encryption and API audit log; applies `k8s/base`; builds the `jenkins-deployer` kubeconfig; proves encryption |
| `04-install-monitoring.sh` | kube-prometheus-stack + ServiceMonitor, alert rules, Grafana dashboard, Mailpit |
| `05-configure-jenkins.sh` (sudo) | plugins, admin user, credentials, SonarQube server, pipeline job (all as code); starts build #1 |
| `06-port-forwards.sh start` | exposes the in-cluster UIs on the instance's localhost |

All generated passwords are in `~/.medsecure/` on the instance (mode 600):

```bash
cat ~/.medsecure/jenkins-admin-password
cat ~/.medsecure/sonarqube-admin-password
cat ~/.medsecure/grafana-admin-password
grep PASSWORD ~/.medsecure/app-secrets.env      # MedSecure staff logins
```

## 3. Open the UIs through the SSH tunnel (laptop)

```bash
cd ~/VLE-9-Healthcare-DevSecOps/infra/terraform
$(terraform output -raw tunnel_command)          # keep this terminal open
```

| UI | URL | Login |
|---|---|---|
| Jenkins | http://localhost:18080 | admin / `jenkins-admin-password` |
| SonarQube | http://localhost:19000 | admin / `sonarqube-admin-password` |
| MedSecure app | http://localhost:18081 | `dr.mehta`, `nurse.priya`, `desk.ravi` / from `app-secrets.env` |
| Grafana | http://localhost:13000 | admin / `grafana-admin-password` |
| Prometheus | http://localhost:19090 | (none; only reachable via the tunnel) |
| Alertmanager | http://localhost:19093 | |
| Alert inbox (Mailpit) | http://localhost:18025 | |

## 4. Watch the pipeline

Jenkins → `medsecure-devsecops` → build #1. The first run takes about 10 minutes (images, Trivy database, SonarQube plugins). Later runs take about 4 minutes. After build #1 the job is parameterised (`BASE_IMAGE`, `RUN_DAST`) and polls GitHub every 2 minutes, so every `git push` to `main` starts a build.

Then follow [DEMO.md](DEMO.md) to show every expected output.

## 5. Stop, restart, destroy

```bash
# laptop - pause (keeps everything, stops the hourly charge; disk still ~USD 0.09/day)
aws ec2 stop-instances --instance-ids $(terraform output -raw instance_id)
aws ec2 start-instances --instance-ids $(terraform output -raw instance_id)
terraform apply -refresh-only        # updates public_ip / tunnel_command outputs

# EC2 - after a start
cd ~/medsecure && scripts/ec2/03-start-minikube.sh && scripts/ec2/06-port-forwards.sh start
# (SonarQube and Jenkins start automatically)

# laptop - finished with the lab
terraform destroy
```

If your home IP changes, SSH is refused (that is the security group working). Fix:
`echo "allowed_cidr = \"$(curl -s https://checkip.amazonaws.com)/32\"" > terraform.tfvars && terraform apply`.
Session Manager also works as a break-glass login: `aws ssm start-session --target <instance_id>`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `terraform apply`: `AccessDenied ... iam:CreateRole` | Step 0.1: `VLE9TerraformRunner` not attached to the user, or `aws sts get-caller-identity` shows a different user |
| `InvalidClientTokenId` | the access key was deleted or deactivated: create a new one (0.1 step 3) and run `aws configure` again |
| SSH times out | Your IP changed; see above |
| `setup-all.sh`: "Bootstrap not finished" | wait, then `tail /var/log/medsecure-bootstrap.log` |
| `docker: permission denied` | log out and in again (new docker group membership), or run `setup-all.sh`, which handles it |
| SonarQube never becomes UP | `docker logs sonarqube`; check `sysctl vm.max_map_count` is 524288 |
| Build fails at *Container Scan* after weeks | a new CVE appeared upstream: rebuild with the newest base digest (that is the gate working) |
| Port-forward URLs return 000 | `scripts/ec2/06-port-forwards.sh stop && scripts/ec2/06-port-forwards.sh start` |
| Grafana shows "No data" | wait 1 to 2 minutes after a deploy; check Prometheus → Status → Targets → `patient-api` is UP |
