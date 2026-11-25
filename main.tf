data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
  enable_dns_support = true
  enable_dns_hostnames = true
  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "${var.project_name}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id = aws_vpc.main.id
  cidr_block = var.public_subnet_cidr
  availability_zone = var.availability_zone
  map_public_ip_on_launch = true
  tags = { Name = "${var.project_name}-public-subnet", Tier = "public" }
}
resource "aws_subnet" "app" {
  vpc_id = aws_vpc.main.id
  cidr_block = var.app_subnet_cidr
  availability_zone = var.availability_zone
  map_public_ip_on_launch = false
  tags = { Name = "${var.project_name}-app-subnet", Tier = "application" }
}
resource "aws_subnet" "middleware" {
  vpc_id = aws_vpc.main.id
  cidr_block = var.middleware_subnet_cidr
  availability_zone = var.availability_zone
  map_public_ip_on_launch = false
  tags = { Name = "${var.project_name}-middleware-subnet", Tier = "middleware" }
}
resource "aws_subnet" "database" {
  vpc_id = aws_vpc.main.id
  cidr_block = var.database_subnet_cidr
  availability_zone = var.availability_zone
  map_public_ip_on_launch = false
  tags = { Name = "${var.project_name}-database-subnet", Tier = "database" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "${var.project_name}-public-rt" }
}
resource "aws_route" "public_internet" {
  route_table_id = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id = aws_internet_gateway.main.id
}
resource "aws_route_table_association" "public" {
  subnet_id = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"
  depends_on = [aws_internet_gateway.main]
  tags = { Name = "${var.project_name}-nat-eip" }
}
resource "aws_nat_gateway" "main" {
  count = var.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id = aws_subnet.public.id
  depends_on = [aws_route_table_association.public]
  tags = { Name = "${var.project_name}-nat" }
}
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "${var.project_name}-private-rt" }
}
resource "aws_route" "private_nat" {
  count = var.enable_nat_gateway ? 1 : 0
  route_table_id = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = aws_nat_gateway.main[0].id
}
resource "aws_route_table_association" "app" {
  subnet_id = aws_subnet.app.id
  route_table_id = aws_route_table.private.id
}
resource "aws_route_table_association" "middleware" {
  subnet_id = aws_subnet.middleware.id
  route_table_id = aws_route_table.private.id
}
resource "aws_route_table_association" "database" {
  subnet_id = aws_subnet.database.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "public" {
  name = "${var.project_name}-sg-public"
  description = "Public Nginx entry point; administer with SSM, no SSH ingress."
  vpc_id = aws_vpc.main.id
  ingress {
    description = "HTTP"
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = var.public_http_cidrs
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project_name}-sg-public", Tier = "public" }
}
resource "aws_security_group" "app" {
  name = "${var.project_name}-sg-app"
  description = "App traffic only from public Nginx SG."
  vpc_id = aws_vpc.main.id
  ingress {
    description = "App port from Public SG"
    from_port = var.app_port
    to_port = var.app_port
    protocol = "tcp"
    security_groups = [aws_security_group.public.id]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project_name}-sg-app", Tier = "application" }
}
resource "aws_security_group" "middleware" {
  name = "${var.project_name}-sg-middleware"
  description = "Middleware ports only from Application SG."
  vpc_id = aws_vpc.main.id
  dynamic "ingress" {
    for_each = { redis = 6379, kafka = 9092, elasticsearch = 9200 }
    content {
      description = "${ingress.key} from Application SG"
      from_port = ingress.value
      to_port = ingress.value
      protocol = "tcp"
      security_groups = [aws_security_group.app.id]
    }
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project_name}-sg-middleware", Tier = "middleware" }
}
resource "aws_security_group" "database" {
  name = "${var.project_name}-sg-database"
  description = "Database ports only from Application SG."
  vpc_id = aws_vpc.main.id
  dynamic "ingress" {
    for_each = { mysql = 3306, mongodb = 27017 }
    content {
      description = "${ingress.key} from Application SG"
      from_port = ingress.value
      to_port = ingress.value
      protocol = "tcp"
      security_groups = [aws_security_group.app.id]
    }
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project_name}-sg-database", Tier = "database" }
}

resource "aws_iam_role" "ec2_ssm" {
  name = "${var.project_name}-ec2-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "${var.project_name}-ec2-ssm-profile"
  role = aws_iam_role.ec2_ssm.name
}

resource "aws_instance" "app" {
  ami = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type = var.instance_type
  subnet_id = aws_subnet.app.id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile = aws_iam_instance_profile.ec2_ssm.name
  user_data = templatefile("${path.module}/templates/app-demo.sh.tftpl", { app_port = var.app_port })
  root_block_device {
    volume_size = 12
    volume_type = "gp3"
    encrypted = true
  }
  depends_on = [aws_route_table_association.app, aws_route.private_nat, aws_iam_role_policy_attachment.ssm_core]
  tags = { Name = "${var.project_name}-app-server-01", Tier = "application" }
}

resource "aws_instance" "public" {
  ami = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type = var.instance_type
  subnet_id = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.public.id]
  iam_instance_profile = aws_iam_instance_profile.ec2_ssm.name
  associate_public_ip_address = false
  user_data = templatefile("${path.module}/templates/public-nginx.sh.tftpl", {
    app_private_ip = aws_instance.app.private_ip
    app_port = var.app_port
  })
  user_data_replace_on_change = true
  root_block_device {
    volume_size = 12
    volume_type = "gp3"
    encrypted = true
  }
  depends_on = [aws_route.public_internet, aws_iam_role_policy_attachment.ssm_core]
  tags = { Name = "${var.project_name}-public-server-01", Tier = "public" }
}
resource "aws_eip" "public_server" {
  domain = "vpc"
  instance = aws_instance.public.id
  depends_on = [aws_internet_gateway.main]
  tags = { Name = "${var.project_name}-public-server-eip" }
}

resource "aws_instance" "middleware" {
  ami = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type = var.instance_type
  subnet_id = aws_subnet.middleware.id
  vpc_security_group_ids = [aws_security_group.middleware.id]
  iam_instance_profile = aws_iam_instance_profile.ec2_ssm.name
  root_block_device {
    volume_size = 16
    volume_type = "gp3"
    encrypted = true
  }
  depends_on = [aws_route_table_association.middleware, aws_route.private_nat, aws_iam_role_policy_attachment.ssm_core]
  tags = { Name = "${var.project_name}-middleware-server-01", Tier = "middleware" }
}
resource "aws_instance" "database" {
  ami = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type = var.instance_type
  subnet_id = aws_subnet.database.id
  vpc_security_group_ids = [aws_security_group.database.id]
  iam_instance_profile = aws_iam_instance_profile.ec2_ssm.name
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted = true
  }
  depends_on = [aws_route_table_association.database, aws_route.private_nat, aws_iam_role_policy_attachment.ssm_core]
  tags = { Name = "${var.project_name}-database-server-01", Tier = "database" }
}
