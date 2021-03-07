locals {
  subnet_cidr_blocks = [for cidr_block in cidrsubnets("${var.cidr_base}/16", 4,4) : cidrsubnets(cidr_block, 4, 4, 4 ,4)]
}

#
# VPC Resources
#

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "testing-alb-cognito-auth"
  cidr = "${var.cidr_base}/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c", "${var.aws_region}d"]
  private_subnets = local.subnet_cidr_blocks[0]
  public_subnets  = local.subnet_cidr_blocks[1]

  enable_nat_gateway = true
  single_nat_gateway  = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Terraform = "true"
    Environment = "dev"
  }
}

#
# EC2 Resources
#

resource "aws_security_group" "allow_http_from_public_subnet" {
  name        = "allow_http_from_public_subnet"
  description = "Allow HTTP traffic from all public subnets"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTP from public Subnets"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = module.vpc.public_subnets_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "allow_http_https_from_world" {
  name        = "allow_http_https_from_world"
  description = "Allow HTTP(s) Traffic from the world"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTP from public Subnets"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP from public Subnets"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_ami" "amazon_linux_2" {
  most_recent = true

  owners = ["amazon"]
  filter {
    name   = "owner-alias"
    values = ["amazon"]
  }

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-ebs"]
  }
}

resource "random_shuffle" "random_private_subnet" {
  input        = module.vpc.private_subnets
  result_count = 1
}

resource "aws_instance" "web_server" {
  ami           = data.aws_ami.amazon_linux_2.id
  instance_type = "t2.micro"
  associate_public_ip_address = true
  subnet_id = random_shuffle.random_private_subnet.result[0]
  user_data     = <<-EOF
                  #!/bin/bash
                  sudo su
                  yum -y install httpd
                  echo "<p> Hello World! </p>" >> /var/www/html/index.html
                  sudo systemctl enable httpd
                  sudo systemctl start httpd
                  EOF
  vpc_security_group_ids = [aws_security_group.allow_http_from_public_subnet.id]
}

#
# ALB Resources
#

resource "aws_lb" "alb" {
  load_balancer_type = "application"
  security_groups    = [aws_security_group.allow_http_https_from_world.id]
  subnets            = module.vpc.public_subnets
}

resource "aws_lb_listener" "alb_listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    target_group_arn = aws_lb_target_group.alb_target.arn
    type             = "forward"
  }
}

resource "aws_lb_listener_rule" "listener_rule" {
  listener_arn = aws_lb_listener.alb_listener.arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_target.id
  }

  condition {
    path_pattern {
      values = ["*"]
    }
  }
}

resource "aws_lb_target_group" "alb_target" {
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id

  health_check {
    healthy_threshold   = 3
    unhealthy_threshold = 10
    timeout             = 5
    interval            = 10
    path                = "/"
    port                = 80
  }
}

#Instance Attachment
resource "aws_lb_target_group_attachment" "web_server_attachment" {
  target_group_arn = aws_lb_target_group.alb_target.arn
  target_id        = aws_instance.web_server.id
  port             = 80
}
