output "vpc_id" {
  value = aws_vpc.main.id
}

output "availability_zones" {
  value = local.azs
}

output "subnet_ids_by_type" {
  value = {
    for tier in keys(local.subnet_matrix) :
    tier => [
      for subnet_key, subnet in aws_subnet.tier :
      subnet.id if local.subnet_definitions[subnet_key].type == tier
    ]
  }
}

output "subnet_cidrs_by_type" {
  value = {
    for tier in keys(local.subnet_matrix) :
    tier => [
      for subnet_key, subnet in aws_subnet.tier :
      subnet.cidr_block if local.subnet_definitions[subnet_key].type == tier
    ]
  }
}

output "public_server_ip" {
  value = aws_eip.public.public_ip
}

output "private_server_ips" {
  value = {
    application = aws_instance.application.private_ip
    middleware  = aws_instance.middleware.private_ip
    database    = aws_instance.database.private_ip
  }
}

output "security_group_ids" {
  value = {
    public     = aws_security_group.public.id
    application = aws_security_group.application.id
    middleware = aws_security_group.middleware.id
    database   = aws_security_group.database.id
  }
}

output "test_urls" {
  value = {
    frontend    = "http://${aws_eip.public.public_ip}"
    application = "http://${aws_eip.public.public_ip}"
    mongo       = "http://${aws_eip.public.public_ip}"
    mysql       = "http://${aws_eip.public.public_ip}"
    elasticsearch = "http://${aws_eip.public.public_ip}"
    redis       = "http://${aws_eip.public.public_ip}"
    kafka       = "http://${aws_eip.public.public_ip}"
  }
}
