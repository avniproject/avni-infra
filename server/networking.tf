resource "aws_vpc" "vpc" {
  cidr_block = "${lookup(var.cidr_map, var.environment, "172.1.0.0/16")}"
  enable_dns_support = true
  enable_dns_hostnames = true
  enable_classiclink = false
}


resource "aws_subnet" "subneta" {
  vpc_id = "${aws_vpc.vpc.id}"
  cidr_block = "${cidrsubnet("${aws_vpc.vpc.cidr_block}", 8, 1)}"
  availability_zone = "${var.region}a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "subnetb" {
  vpc_id = "${aws_vpc.vpc.id}"
  cidr_block = "${cidrsubnet("${aws_vpc.vpc.cidr_block}", 8, 2)}"
  availability_zone = "${var.region}b"
  map_public_ip_on_launch = false
}

resource "aws_internet_gateway" "internet_gateway" {
  vpc_id = "${aws_vpc.vpc.id}"
}

resource "aws_route_table" "route_table" {
  vpc_id = "${aws_vpc.vpc.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.internet_gateway.id}"
  }
}

resource "aws_route_table_association" "external_main" {
  subnet_id = "${aws_subnet.subneta.id}"
  route_table_id = "${aws_route_table.route_table.id}"
}

resource "aws_security_group" "server_sg" {
  name = "server-sg"
  description = "Allowed Ports"
  vpc_id = "${aws_vpc.vpc.id}"

  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = [
      "0.0.0.0/0"]
  }

  ingress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [
      "${aws_vpc.vpc.cidr_block}"
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

resource "aws_security_group" "db_sg" {
  name = "db-sg"
  description = "Allowed Ports On Db"
  vpc_id = "${aws_vpc.vpc.id}"

  ingress {
    from_port = 0
    to_port = 5432
    protocol = "tcp"
    cidr_blocks = [
      "${aws_vpc.vpc.cidr_block}"
    ]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [
      "${aws_vpc.vpc.cidr_block}"]
  }
}

data "aws_route53_zone" "openchs" {
  name = "openchs.org"
  private_zone = false
}

