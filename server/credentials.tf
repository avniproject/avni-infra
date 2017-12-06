resource "aws_iam_user" "server" {
  name = "${var.environment}_server"
}

resource "aws_iam_access_key" "server_key" {
  user = "${aws_iam_user.server.name}"
}

resource "aws_iam_role" "server_role" {
  name = "${var.environment}_server_role"
  assume_role_policy = "${file("server/policy/server-role.json")}"
}

resource "aws_iam_role_policy" "server_instance_role_policy" {
  name = "${var.environment}_server_instance_role_policy"
  policy = "${file("server/policy/server-instance-role-policy.json")}"
  role = "${aws_iam_role.server_role.id}"
}


resource "aws_iam_instance_profile" "server_instance" {
  name = "${var.environment}_server_instance"
  path = "/"
  role = "${aws_iam_role.server_role.name}"
}


data "aws_acm_certificate" "ssl_certificate" {
  domain   = "*.openchs.org"
  statuses = ["ISSUED"]
}