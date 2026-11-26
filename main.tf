data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  subnet_matrix = {
    public = {
      cidrs  = ["10.20.0.0/25", "10.20.0.128/25"]
      public = true
    }
    application = {
      cidrs  = ["10.20.8.0/21", "10.20.16.0/21"]
      public = false
    }
    database = {
      cidrs  = ["10.20.24.0/23", "10.20.26.0/23"]
      public = false
    }
    middleware = {
      cidrs  = ["10.20.32.0/22", "10.20.36.0/22"]
      public = false
    }
  }

  subnet_definitions = merge([
    for tier, cfg in local.subnet_matrix : {
      for idx, cidr in cfg.cidrs : "${tier}-${idx + 1}" => {
        tier   = tier
        type   = tier
        cidr   = cidr
        az     = local.azs[idx]
        public = cfg.public
      }
    }
  ]...)
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "tier" {
  for_each = local.subnet_definitions

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone        = each.value.az
  map_public_ip_on_launch = each.value.public

  tags = {
    Name = "${var.project_name}-${each.key}"
    type = each.value.type
  }
}

# Public route table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-public-rt"
    type = "public"
  }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each = {
    for k, v in local.subnet_definitions : k => v
    if v.type == "public"
  }

  subnet_id      = aws_subnet.tier[each.key].id
  route_table_id = aws_route_table.public.id
}

# Optional NAT Gateway for private subnet outbound internet
resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  count         = var.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.tier["public-1"].id

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.project_name}-nat"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-private-rt"
    type = "private"
  }
}

resource "aws_route" "private_default" {
  count                  = var.enable_nat_gateway ? 1 : 0
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[0].id
}

resource "aws_route_table_association" "private" {
  for_each = {
    for k, v in local.subnet_definitions : k => v
    if v.type != "public"
  }

  subnet_id      = aws_subnet.tier[each.key].id
  route_table_id = aws_route_table.private.id
}

# NACLs: one per tier, associated with both AZ subnets.
# NACLs are stateless. Security Groups provide the service-level restrictions.
resource "aws_network_acl" "tier" {
  for_each = local.subnet_matrix

  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-${each.key}-nacl"
    type = each.key
  }
}

resource "aws_network_acl_association" "tier" {
  for_each = local.subnet_definitions

  network_acl_id = aws_network_acl.tier[each.value.tier].id
  subnet_id      = aws_subnet.tier[each.key].id
}

# Public NACL: HTTP/HTTPS inbound and ephemeral return traffic.
resource "aws_network_acl_rule" "public_ingress" {
  for_each = {
    "http"  = 80
    "https" = 443
  }

  network_acl_id = aws_network_acl.tier["public"].id
  rule_number    = each.value == 80 ? 100 : 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = each.value
  to_port        = each.value
}

resource "aws_network_acl_rule" "public_ingress_ephemeral" {
  network_acl_id = aws_network_acl.tier["public"].id
  rule_number    = 120
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "public_egress" {
  network_acl_id = aws_network_acl.tier["public"].id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

# Application NACL: inbound from public subnets on app ports.
resource "aws_network_acl_rule" "app_ingress_public" {
  for_each = {
    "public-1" = "10.20.0.0/25"
    "public-2" = "10.20.0.128/25"
  }

  network_acl_id = aws_network_acl.tier["application"].id
  rule_number    = each.key == "public-1" ? 100 : 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = each.value
  from_port      = 8080
  to_port        = 8085
}

resource "aws_network_acl_rule" "app_ingress_ephemeral" {
  for_each = {
    "public-1"     = "10.20.0.0/25"
    "public-2"     = "10.20.0.128/25"
    "middleware-1" = "10.20.32.0/22"
    "middleware-2" = "10.20.36.0/22"
    "database-1"   = "10.20.24.0/23"
    "database-2"   = "10.20.26.0/23"
  }

  network_acl_id = aws_network_acl.tier["application"].id
  rule_number    = 200 + index(keys({
    "public-1"     = "10.20.0.0/25"
    "public-2"     = "10.20.0.128/25"
    "middleware-1" = "10.20.32.0/22"
    "middleware-2" = "10.20.36.0/22"
    "database-1"   = "10.20.24.0/23"
    "database-2"   = "10.20.26.0/23"
  }), each.key)

  egress       = false
  protocol     = "tcp"
  rule_action  = "allow"
  cidr_block   = each.value
  from_port    = 1024
  to_port      = 65535
}

resource "aws_network_acl_rule" "app_egress" {
  network_acl_id = aws_network_acl.tier["application"].id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

# Middleware NACL: app subnet CIDRs to Redis, Kafka and Elasticsearch ports.
resource "aws_network_acl_rule" "middleware_ingress" {
  for_each = {
    "app-1-redis" = { cidr = "10.20.8.0/21", port = 6379, rule = 100 }
    "app-2-redis" = { cidr = "10.20.16.0/21", port = 6379, rule = 110 }
    "app-1-kafka" = { cidr = "10.20.8.0/21", port = 9092, rule = 120 }
    "app-2-kafka" = { cidr = "10.20.16.0/21", port = 9092, rule = 130 }
    "app-1-es"    = { cidr = "10.20.8.0/21", port = 9200, rule = 140 }
    "app-2-es"    = { cidr = "10.20.16.0/21", port = 9200, rule = 150 }
  }

  network_acl_id = aws_network_acl.tier["middleware"].id
  rule_number    = each.value.rule
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = each.value.cidr
  from_port      = each.value.port
  to_port        = each.value.port
}

resource "aws_network_acl_rule" "middleware_ingress_ephemeral" {
  for_each = {
    "app-1" = "10.20.8.0/21"
    "app-2" = "10.20.16.0/21"
  }

  network_acl_id = aws_network_acl.tier["middleware"].id
  rule_number    = each.key == "app-1" ? 200 : 210
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = each.value
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "middleware_egress" {
  network_acl_id = aws_network_acl.tier["middleware"].id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

# Database NACL: app subnet CIDRs to MySQL and MongoDB ports.
resource "aws_network_acl_rule" "database_ingress" {
  for_each = {
    "app-1-mysql" = { cidr = "10.20.8.0/21", port = 3306, rule = 100 }
    "app-2-mysql" = { cidr = "10.20.16.0/21", port = 3306, rule = 110 }
    "app-1-mongo" = { cidr = "10.20.8.0/21", port = 27017, rule = 120 }
    "app-2-mongo" = { cidr = "10.20.16.0/21", port = 27017, rule = 130 }
  }

  network_acl_id = aws_network_acl.tier["database"].id
  rule_number    = each.value.rule
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = each.value.cidr
  from_port      = each.value.port
  to_port        = each.value.port
}

resource "aws_network_acl_rule" "database_ingress_ephemeral" {
  for_each = {
    "app-1" = "10.20.8.0/21"
    "app-2" = "10.20.16.0/21"
  }

  network_acl_id = aws_network_acl.tier["database"].id
  rule_number    = each.key == "app-1" ? 200 : 210
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = each.value
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "database_egress" {
  network_acl_id = aws_network_acl.tier["database"].id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

# Security Groups
resource "aws_security_group" "public" {
  name        = "${var.project_name}-public-sg"
  description = "Public HTTP entry point"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.public_http_cidrs
  }

  egress {
    from_port   = 8080
    to_port     = 8085
    protocol    = "tcp"
    cidr_blocks = ["10.20.8.0/21", "10.20.16.0/21"]
  }

  egress {
    from_port   = 80
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-public-sg"
    type = "public"
  }
}

resource "aws_security_group" "application" {
  name   = "${var.project_name}-application-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 8080
    to_port         = 8085
    protocol        = "tcp"
    security_groups = [aws_security_group.public.id]
  }

  egress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = ["10.20.32.0/22", "10.20.36.0/22"]
  }

  egress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = ["10.20.32.0/22", "10.20.36.0/22"]
  }

  egress {
    from_port   = 9200
    to_port     = 9200
    protocol    = "tcp"
    cidr_blocks = ["10.20.32.0/22", "10.20.36.0/22"]
  }

  egress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["10.20.24.0/23", "10.20.26.0/23"]
  }

  egress {
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    cidr_blocks = ["10.20.24.0/23", "10.20.26.0/23"]
  }

  egress {
    from_port   = 80
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-application-sg"
    type = "application"
  }
}

resource "aws_security_group" "middleware" {
  name   = "${var.project_name}-middleware-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.application.id]
  }

  ingress {
    from_port       = 9092
    to_port         = 9092
    protocol        = "tcp"
    security_groups = [aws_security_group.application.id]
  }

  ingress {
    from_port       = 9200
    to_port         = 9200
    protocol        = "tcp"
    security_groups = [aws_security_group.application.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-middleware-sg"
    type = "middleware"
  }
}

resource "aws_security_group" "database" {
  name   = "${var.project_name}-database-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.application.id]
  }

  ingress {
    from_port       = 27017
    to_port         = 27017
    protocol        = "tcp"
    security_groups = [aws_security_group.application.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-database-sg"
    type = "database"
  }
}

# EC2 SSM role: allows management without opening SSH.
resource "aws_iam_role" "ec2_ssm" {
  name = "${var.project_name}-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "${var.project_name}-ec2-ssm-profile"
  role = aws_iam_role.ec2_ssm.name
}

# Database mock endpoints
resource "aws_instance" "database" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type           = var.database_instance_type
  subnet_id               = aws_subnet.tier["database-1"].id
  vpc_security_group_ids  = [aws_security_group.database.id]
  iam_instance_profile    = aws_iam_instance_profile.ec2_ssm.name

  user_data = <<-EOF
    #!/bin/bash
    set -eux
    apt-get update -y
    apt-get install -y nginx
    cat >/etc/nginx/sites-available/default <<'NGINX'
    server { listen 27017; location / { return 200 "hello from mongo\n"; } }
    server { listen 3306; location / { return 200 "hello from MySQL\n"; } }
    NGINX
    nginx -t
    systemctl restart nginx
  EOF

  root_block_device {
    volume_size = 16
    volume_type = "gp3"
    encrypted   = true
  }

  depends_on = [aws_route_table_association.private, aws_iam_role_policy_attachment.ssm_core]

  tags = {
    Name = "${var.project_name}-database-server-az-a"
    type = "database"
  }
}

# Middleware mock endpoints
resource "aws_instance" "middleware" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type           = var.middleware_instance_type
  subnet_id               = aws_subnet.tier["middleware-1"].id
  vpc_security_group_ids  = [aws_security_group.middleware.id]
  iam_instance_profile    = aws_iam_instance_profile.ec2_ssm.name

  user_data = <<-EOF
    #!/bin/bash
    set -eux
    apt-get update -y
    apt-get install -y nginx
    cat >/etc/nginx/sites-available/default <<'NGINX'
    server { listen 9200; location / { return 200 "hello from ES\n"; } }
    server { listen 6379; location / { return 200 "hello from redis\n"; } }
    server { listen 9092; location / { return 200 "hello from kafka\n"; } }
    NGINX
    nginx -t
    systemctl restart nginx
  EOF

  root_block_device {
    volume_size = 24
    volume_type = "gp3"
    encrypted   = true
  }

  depends_on = [aws_route_table_association.private, aws_iam_role_policy_attachment.ssm_core]

  tags = {
    Name = "${var.project_name}-middleware-server-az-a"
    type = "middleware"
  }
}

# Application endpoints proxy to middleware/database mock services
resource "aws_instance" "application" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type           = var.app_instance_type
  subnet_id               = aws_subnet.tier["application-1"].id
  vpc_security_group_ids  = [aws_security_group.application.id]
  iam_instance_profile    = aws_iam_instance_profile.ec2_ssm.name

  user_data = <<-EOF
    #!/bin/bash
    set -eux
    apt-get update -y
    apt-get install -y nginx
    cat >/etc/nginx/sites-available/default <<'NGINX'
    server { listen 8080; location / { proxy_pass http://${aws_instance.database.private_ip}:27017; } }
    server { listen 8081; location / { proxy_pass http://${aws_instance.database.private_ip}:3306; } }
    server { listen 8082; location / { proxy_pass http://${aws_instance.middleware.private_ip}:9200; } }
    server { listen 8083; location / { proxy_pass http://${aws_instance.middleware.private_ip}:6379; } }
    server { listen 8084; location / { proxy_pass http://${aws_instance.middleware.private_ip}:9092; } }
    server { listen 8085; location / { return 200 "hello from Application Server\n"; } }
    NGINX
    nginx -t
    systemctl restart nginx
  EOF

  root_block_device {
    volume_size = 16
    volume_type = "gp3"
    encrypted   = true
  }

  depends_on = [aws_route_table_association.private, aws_iam_role_policy_attachment.ssm_core]

  tags = {
    Name = "${var.project_name}-application-server-az-a"
    type = "application"
  }
}

# Public reverse proxy; host headers select backend response.
resource "aws_instance" "public" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type           = var.public_instance_type
  subnet_id               = aws_subnet.tier["public-1"].id
  vpc_security_group_ids  = [aws_security_group.public.id]
  iam_instance_profile    = aws_iam_instance_profile.ec2_ssm.name

  user_data = <<-EOF
    #!/bin/bash
    set -eux
    apt-get update -y
    apt-get install -y nginx
    cat >/etc/nginx/sites-available/default <<'NGINX'
    server {
      listen 80;
      server_name opstree.com;
      location / { return 200 "hello from frontend server\n"; }
    }
    server {
      listen 80;
      server_name application.opstree.com;
      location / { proxy_pass http://${aws_instance.application.private_ip}:8085; }
    }
    server {
      listen 80;
      server_name mongo.opstree.com;
      location / { proxy_pass http://${aws_instance.application.private_ip}:8080; }
    }
    server {
      listen 80;
      server_name mysql.opstree.com;
      location / { proxy_pass http://${aws_instance.application.private_ip}:8081; }
    }
    server {
      listen 80;
      server_name es.opstree.com;
      location / { proxy_pass http://${aws_instance.application.private_ip}:8082; }
    }
    server {
      listen 80;
      server_name redis.opstree.com;
      location / { proxy_pass http://${aws_instance.application.private_ip}:8083; }
    }
    server {
      listen 80;
      server_name kafka.opstree.com;
      location / { proxy_pass http://${aws_instance.application.private_ip}:8084; }
    }
    NGINX
    nginx -t
    systemctl restart nginx
  EOF

  root_block_device {
    volume_size = 12
    volume_type = "gp3"
    encrypted   = true
  }

  depends_on = [aws_route.public_default, aws_iam_role_policy_attachment.ssm_core]

  tags = {
    Name = "${var.project_name}-public-server-az-a"
    type = "public"
  }
}

resource "aws_eip" "public" {
  domain   = "vpc"
  instance = aws_instance.public.id

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.project_name}-public-eip"
    type = "public"
  }
}
