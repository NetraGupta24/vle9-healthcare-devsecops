# The single EC2 host that runs Jenkins, SonarQube, minikube (app +
# Prometheus/Grafana), Trivy and OWASP ZAP.

# Latest Ubuntu 24.04 LTS (Noble) from Canonical's official AWS account.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "lab" {
  key_name   = "${var.name_prefix}-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "aws_instance" "devsecops" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.devsecops.id]
  key_name               = aws_key_pair.lab.key_name
  iam_instance_profile   = aws_iam_instance_profile.devsecops_host.name

  # Explicit public IP for SSH (the subnet does not hand them out by default).
  associate_public_ip_address = true

  # Installs Docker, Jenkins, Trivy, kubectl, minikube and Helm on first boot.
  user_data = file("${path.module}/../../scripts/ec2/00-bootstrap.sh")

  # IMDSv2 only, and hop limit 1: containers (one network hop further away)
  # cannot reach the metadata service, which blocks SSRF credential theft.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  # Encrypted at rest (AWS-managed KMS key): disk, snapshots and swap.
  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    encrypted             = true
    delete_on_termination = true
    tags                  = { Name = "${var.name_prefix}-devsecops-root" }
  }

  tags = { Name = "${var.name_prefix}-devsecops-host" }

  lifecycle {
    # A newer AMI or an edited bootstrap script must not silently replace
    # (and wipe) a running lab host.
    ignore_changes = [ami, user_data]
  }
}
