variable "aws_region" {
  description = "AWS region (Mumbai)."
  type        = string
  default     = "ap-south-1"
}

variable "name_prefix" {
  description = "Prefix for every resource name. The Terraform runner policy only allows IAM roles that start with it."
  type        = string
  default     = "vle9"
}

variable "allowed_cidrs" {
  description = "The ONLY addresses allowed to connect (SSH), each your public IP as a /32, e.g. [\"49.206.10.111/32\"] (curl -s https://checkip.amazonaws.com). List every network you work from."
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidrs) > 0 && alltrue([for c in var.allowed_cidrs : can(cidrhost(c, 0)) && !startswith(c, "0.0.0.0/")])
    error_message = "allowed_cidrs must contain valid CIDRs and must not include 0.0.0.0/0 (the whole internet)."
  }
}

variable "instance_type" {
  description = "Free-plan eligible type with enough RAM for Jenkins + SonarQube + minikube. Uses credits: about USD 0.10/hour in ap-south-1 - stop it when not in use."
  type        = string
  default     = "m7i-flex.large" # 2 vCPU, 8 GiB

  validation {
    condition     = contains(["m7i-flex.large", "c7i-flex.large", "t3.small", "t3.micro"], var.instance_type)
    error_message = "Use a Free-plan eligible type. Only m7i-flex.large (8 GiB) can run the full lab."
  }
}

variable "root_volume_gb" {
  description = "Encrypted gp3 root volume size (GiB). Container images need about 20 GiB."
  type        = number
  default     = 30
}

variable "ssh_public_key_path" {
  description = "Public half of the SSH key used to log in (create with: ssh-keygen -t ed25519 -f ~/.ssh/vle9-key)."
  type        = string
  default     = "~/.ssh/vle9-key.pub"
}

variable "open_web_ports" {
  description = "If true, ALSO open Jenkins (8080) and SonarQube (9000) to allowed_cidrs. Default false: use the SSH tunnel, which encrypts the traffic."
  type        = bool
  default     = false
}

variable "vpc_cidr" {
  description = "CIDR of the dedicated lab VPC."
  type        = string
  default     = "10.90.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR of the single public subnet."
  type        = string
  default     = "10.90.1.0/24"
}
