output "instance_id" {
  value = aws_instance.devsecops.id
}

output "public_ip" {
  description = "Changes after every stop/start (no Elastic IP, to save credits)."
  value       = aws_instance.devsecops.public_ip
}

output "ssh_command" {
  value = "ssh -i ${trimsuffix(pathexpand(var.ssh_public_key_path), ".pub")} ubuntu@${aws_instance.devsecops.public_ip}"
}

output "tunnel_command" {
  description = "Run on your laptop and keep it open; then use the localhost URLs below."
  value       = "ssh -i ${trimsuffix(pathexpand(var.ssh_public_key_path), ".pub")} -N -L 18080:localhost:8080 -L 19000:localhost:9000 -L 18081:localhost:8081 -L 13000:localhost:3000 -L 19090:localhost:9090 -L 19093:localhost:9093 -L 18025:localhost:8025 ubuntu@${aws_instance.devsecops.public_ip}"
}

output "urls_through_tunnel" {
  value = {
    jenkins      = "http://localhost:18080"
    sonarqube    = "http://localhost:19000"
    medsecure    = "http://localhost:18081"
    grafana      = "http://localhost:13000"
    prometheus   = "http://localhost:19090"
    alertmanager = "http://localhost:19093"
    alert_inbox  = "http://localhost:18025"
  }
}

output "iam_role" {
  description = "Instance role: only AmazonSSMManagedInstanceCore."
  value       = aws_iam_role.devsecops_host.name
}

output "security_group_id" {
  value = aws_security_group.devsecops.id
}

output "estimated_cost" {
  value = "${var.instance_type} ~USD 0.10/hour while running + ${var.root_volume_gb} GiB gp3 ~USD 0.09/day. Stop the instance when not in use; terraform destroy when finished."
}
