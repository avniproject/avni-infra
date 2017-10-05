output "reporting_server_ip" {
  value = "${aws_instance.reporting_server.public_ip}"
}

output "reporting_database_url" {
  value = "${aws_db_instance.reporting.address}"
}

output "reporting_address" {
  value = "${aws_route53_record.reporting.name}"
}
