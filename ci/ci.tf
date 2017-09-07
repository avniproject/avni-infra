resource "aws_instance" "ci" {
  ami = "${var.ami}"
  availability_zone = "${var.region}a"
  instance_type = "${var.instance_type}"
  associate_public_ip_address = true
  vpc_security_group_ids = [
    "${aws_security_group.ci_sg.id}"]
  subnet_id = "${aws_subnet.ci.id}"
  iam_instance_profile = "${aws_iam_instance_profile.ci_instance.name}"
  key_name = "${aws_key_pair.openchs.key_name}"
  root_block_device = {
    volume_size = "${var.disk_size}"
    volume_type = "gp2"
    delete_on_termination = true
  }

  provisioner "remote-exec" {
    script = "ci/provision/halyard.sh"
    connection {
      user = "ubuntu"
    }
  }
}

resource "aws_route53_record" "ci" {
  zone_id = "${data.aws_route53_zone.openchs.zone_id}"
  name = "ci.${data.aws_route53_zone.openchs.name}"
  type = "A"
  ttl = "300"
  records = [
    "${aws_instance.ci.public_ip}"
  ]
}
