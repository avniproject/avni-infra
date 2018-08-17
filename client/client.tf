data "template_file" "policy" {
  template = "${file("client/config/policy.json.tpl")}"

  vars {
    environment = "${var.environment}"
  }
}

data "aws_route53_zone" "openchs" {
  name = "openchs.org"
  private_zone = false
}


resource "aws_s3_bucket" "app" {
  bucket = "${var.environment}.${data.aws_route53_zone.openchs.name}"
  acl = "public-read"
  policy = "${data.template_file.policy.rendered}"

  website {
    index_document = "index.html"
  }
}


resource "aws_route53_record" "app_url" {
  zone_id = "${data.aws_route53_zone.openchs.zone_id}"
  name = "${var.environment}.${data.aws_route53_zone.openchs.name}"
  type = "A"

  alias {
    evaluate_target_health = false
    name = "${aws_s3_bucket.app.bucket_domain_name}"
    zone_id = "${aws_s3_bucket.app.hosted_zone_id}"
  }
}
