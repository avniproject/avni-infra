resource "aws_key_pair" "openchs" {
  key_name = "${var.key_name}"
  public_key = "${var.ssh_public_key}"
}

resource "aws_iam_user" "server" {
  name = "server"
}

resource "aws_iam_access_key" "server_key" {
  user = "${aws_iam_user.server.name}"
}

resource "aws_iam_role" "server_role" {
  name = "server_role"
  assume_role_policy = "${file("server/policy/server-role.json")}"
}

resource "aws_iam_role_policy" "server_instance_role_policy" {
  name = "server_instance_role_policy"
  policy = "${file("server/policy/server-instance-role-policy.json")}"
  role = "${aws_iam_role.server_role.id}"
}


resource "aws_iam_instance_profile" "server_instance" {
  name = "ci_instance"
  path = "/"
  role = "${aws_iam_role.server_role.name}"
}

