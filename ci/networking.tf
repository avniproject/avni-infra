resource "aws_vpc" "ci" {
  cidr_block = "10.1.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
  enable_classiclink = false
}


resource "aws_subnet" "ci" {
  vpc_id = "${aws_vpc.ci.id}"
  cidr_block = "${aws_vpc.ci.cidr_block}"
  availability_zone = "${var.region}a"
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "ci" {
  vpc_id = "${aws_vpc.ci.id}"
}

resource "aws_route_table" "ci" {
  vpc_id = "${aws_vpc.ci.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.ci.id}"
  }
}

resource "aws_route_table_association" "external_main" {
  subnet_id = "${aws_subnet.ci.id}"
  route_table_id = "${aws_route_table.ci.id}"
}

resource "aws_security_group" "ci_sg" {
  name = "ci-sg"
  description = "Allowed Ports"
  vpc_id = "${aws_vpc.ci.id}"

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
      "${aws_vpc.ci.cidr_block}"
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


data "aws_route53_zone" "openchs" {
  name         = "openchs.org"
  private_zone = false
}

