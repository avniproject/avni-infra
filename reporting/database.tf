resource "aws_db_subnet_group" "reporting_db_subnet" {
  name = "reporting_main"
  subnet_ids = [
    "${aws_subnet.reportingsubneta.id}",
    "${aws_subnet.reportingsubnetb.id}"]

  tags {
    Name = "Reporting DB subnet group"
  }
}

resource "aws_db_instance" "reporting" {
  identifier = "reportingdb"
  allocated_storage = 5
  allow_major_version_upgrade = false
  apply_immediately = false
  auto_minor_version_upgrade = true
  backup_retention_period = 7
  storage_encrypted = false
  publicly_accessible = false
  skip_final_snapshot = false
  final_snapshot_identifier = "reportingdb"
  storage_type = "gp2"
  db_subnet_group_name = "${aws_db_subnet_group.reporting_db_subnet.name}"
  engine = "postgres"
  engine_version = "9.6.3"
  instance_class = "db.t2.micro"
  name = "reportingdb"
  username = "reporting_user"
  password = "password"
  vpc_security_group_ids = [
    "${aws_security_group.reporting_db_sg.id}"
  ]
  tags {
    Name = "Reporting Database"
  }
}