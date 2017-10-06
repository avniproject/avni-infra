resource "aws_elb" "loadbalancer" {
  name = "${var.environment}-openchs-load-balancer"

  subnets = [
    "${aws_subnet.subneta.id}",
    "${aws_subnet.subnetb.id}"]

  security_groups = [
    "${aws_security_group.elb_sg.id}"]

  listener {
    instance_port = "${var.server_port}"
    instance_protocol = "http"
    lb_port = 80
    lb_protocol = "http"
  }

  health_check {
    healthy_threshold = 2
    unhealthy_threshold = 2
    timeout = 3
    target = "HTTP:${var.server_port}/"
    interval = 30
  }

  instances = [
    "${aws_instance.server.*.id}"
  ]
  cross_zone_load_balancing = true
  idle_timeout = 400
  connection_draining = true
  connection_draining_timeout = 400

  tags {
    Name = "${var.environment}-openchs-server-load-balancer"
  }
}