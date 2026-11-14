# Step 1 - Security group (restrict ports) and IAM role (least privilege).

# ---------------------------------------------------------------- Security group
# Inbound: ONLY SSH, and only from your own IP. Every web UI (Jenkins,
# SonarQube, Grafana, Prometheus, the app) is reached through an SSH tunnel,
# so nothing else is exposed to the internet and all traffic is encrypted.
# Outbound: only HTTP/HTTPS (apt, Docker images, GitHub, Helm charts).
# DNS and NTP to the Amazon-provided resolvers are not filtered by SGs.
resource "aws_security_group" "devsecops" {
  name        = "${var.name_prefix}-devsecops-host"
  description = "VLE-9 DevSecOps host: SSH from one IP only"
  vpc_id      = aws_vpc.lab.id
  tags        = { Name = "${var.name_prefix}-devsecops-host" }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.devsecops.id
  description       = "SSH (key only) from the student's IP"
  cidr_ipv4         = var.allowed_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "web" {
  for_each          = var.open_web_ports ? { jenkins = 8080, sonarqube = 9000 } : {}
  security_group_id = aws_security_group.devsecops.id
  description       = "${each.key} from the student's IP (optional; prefer the SSH tunnel)"
  cidr_ipv4         = var.allowed_cidr
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}

resource "aws_vpc_security_group_egress_rule" "web_out" {
  for_each          = { http = 80, https = 443 }
  security_group_id = aws_security_group.devsecops.id
  description       = "Outbound ${upper(each.key)} for packages, images and Git"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}

# ---------------------------------------------------------------- IAM role
# The instance gets a role with exactly ONE AWS-managed policy:
# AmazonSSMManagedInstanceCore (Session Manager as a break-glass login when
# your IP changes). No S3, EC2, IAM or other permissions: if the host is
# compromised, its credentials are useless for attacking the AWS account.
# IMDSv2 + hop limit 1 (instance.tf) also stops containers from stealing
# even these credentials.
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "devsecops_host" {
  name                 = "${var.name_prefix}-devsecops-host"
  description          = "VLE-9 EC2 host: Session Manager only (least privilege)"
  assume_role_policy   = data.aws_iam_policy_document.ec2_assume.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.devsecops_host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "devsecops_host" {
  name = "${var.name_prefix}-devsecops-host"
  role = aws_iam_role.devsecops_host.name
}
