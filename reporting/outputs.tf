output "server_ip" {
  value = "${aws_instance.server.public_ip}"
}

output "database_url" {
  value = "${aws_instance.server.public_ip}"
}

output "address" {
  value = "${aws_route53_record.server.name}"
}
