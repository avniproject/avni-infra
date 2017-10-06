resource "aws_vpc" "reportingvpc" {
  cidr_block = "172.10.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
  enable_classiclink = false
  tags {
    Name = "Reporting"
  }
}


resource "aws_subnet" "reportingsubneta" {
  vpc_id = "${aws_vpc.reportingvpc.id}"
  cidr_block = "${cidrsubnet("${aws_vpc.reportingvpc.cidr_block}", 8, 1)}"
  availability_zone = "${var.region}a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "reportingsubnetb" {
  vpc_id = "${aws_vpc.reportingvpc.id}"
  cidr_block = "${cidrsubnet("${aws_vpc.reportingvpc.cidr_block}", 8, 2)}"
  availability_zone = "${var.region}b"
  map_public_ip_on_launch = false
}

resource "aws_internet_gateway" "reporting_internet_gateway" {
  vpc_id = "${aws_vpc.reportingvpc.id}"
}

resource "aws_route_table" "reporting_route_table" {
  vpc_id = "${aws_vpc.reportingvpc.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.reporting_internet_gateway.id}"
  }

  tags {
    Name = "Reporting Route Table"
  }
}

resource "aws_route_table_association" "reporting_external_main" {
  subnet_id = "${aws_subnet.reportingsubneta.id}"
  route_table_id = "${aws_route_table.reporting_route_table.id}"
}

resource "aws_route_table_association" "reporting_external_secondary" {
  subnet_id = "${aws_subnet.reportingsubnetb.id}"
  route_table_id = "${aws_route_table.reporting_route_table.id}"
}

resource "aws_security_group" "reporting_server_sg" {
  name = "server-sg"
  description = "Allowed Ports"
  vpc_id = "${aws_vpc.reportingvpc.id}"

  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = [
      "0.0.0.0/0"]
  }

  ingress {
    from_port = 0
    to_port = "3000"
    protocol = "tcp"
    cidr_blocks = [
      "${aws_vpc.reportingvpc.cidr_block}"
    ]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [
      "0.0.0.0/0"]
  }
}

resource "aws_security_group" "reporting_db_sg" {
  name = "db-sg"
  description = "Allowed Ports On Db"
  vpc_id = "${aws_vpc.reportingvpc.id}"

  ingress {
    from_port = 0
    to_port = 5432
    protocol = "tcp"
    cidr_blocks = [
      "${aws_vpc.reportingvpc.cidr_block}"
    ]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [
      "${aws_vpc.reportingvpc.cidr_block}"]
  }
}

resource "aws_security_group" "reporting_elb_sg" {
  name = "elb-sg"
  description = "Allowed Ports on ELB"
  vpc_id = "${aws_vpc.reportingvpc.id}"

  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }

  ingress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [
      "${aws_vpc.reportingvpc.cidr_block}"
    ]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [
      "0.0.0.0/0"]
  }

  depends_on = ["aws_internet_gateway.reporting_internet_gateway"]
}


data "aws_route53_zone" "openchs" {
  name = "openchs.org"
  private_zone = false
}

