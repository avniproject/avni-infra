data "template_file" "config" {
  template = "${file("reporting/provision/reporting.sh.tpl")}"

  vars {
    db_host = "${aws_db_instance.reporting.address}"
    db_port = "${aws_db_instance.reporting.port}"
    db_user = "${aws_db_instance.reporting.username}"
    db_name = "${aws_db_instance.reporting.name}"
    db_password = "${aws_db_instance.reporting.password}"
  }
}

resource "aws_instance" "server" {
  ami = "${var.ami}"
  availability_zone = "${var.region}a"
  instance_type = "${var.instance_type}"
  associate_public_ip_address = true
  vpc_security_group_ids = [
    "${aws_security_group.server_sg.id}"]
  subnet_id = "${aws_subnet.subneta.id}"
  iam_instance_profile = "${aws_iam_instance_profile.reporting_instance.name}"
  key_name = "${aws_key_pair.openchs.key_name}"
  root_block_device = {
    volume_size = "${var.disk_size}"
    volume_type = "gp2"
    delete_on_termination = true
  }

  provisioner "file" {
    content = "${data.template_file.config.rendered}"
    destination = "~/reporting.sh"
    connection {
      user = "${var.default_ami_user}"
      private_key = "${file("reporting/key/${aws_key_pair.openchs.key_name}.pem")}"
    }
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x ~/reporting.sh",
      "~/reporting.sh"
    ]
    connection {
      user = "${var.default_ami_user}"
      private_key = "${file("reporting/key/${aws_key_pair.openchs.key_name}.pem")}"
    }
  }
}

resource "aws_route53_record" "server" {
  zone_id = "${data.aws_route53_zone.openchs.zone_id}"
  name = "reporting.${data.aws_route53_zone.openchs.name}"
  type = "A"

  alias {
    evaluate_target_health = true
    name = "${aws_elb.loadbalancer.dns_name}"
    zone_id = "${aws_elb.loadbalancer.zone_id}"
  }
}
