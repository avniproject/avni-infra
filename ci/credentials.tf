resource "aws_key_pair" "openchs" {
  key_name = "${var.key_name}"
  public_key = "${var.ssh_public_key}"
}

resource "aws_iam_user" "ci" {
  name = "ci"
}

resource "aws_iam_access_key" "ci_key" {
  user = "${aws_iam_user.ci.name}"
}

resource "aws_iam_role" "ci_role" {
  name = "ci_role"
  assume_role_policy = "${file("ci/policy/ci-role.json")}"
}

resource "aws_iam_role_policy" "ci_instance_role_policy" {
  name = "ci_instance_role_policy"
  policy = "${file("ci/policy/ci-instance-role-policy.json")}"
  role = "${aws_iam_role.ci_role.id}"
}


resource "aws_iam_instance_profile" "ci_instance" {
  name = "ci_instance"
  path = "/"
  role = "${aws_iam_role.ci_role.name}"
}

