output "vpc_id" {
  value = aws_vpc.main.id
}
output "subnet_ids" {
  value = {
    public     = aws_subnet.public.id
    application = aws_subnet.app.id
    middleware = aws_subnet.middleware.id
    database   = aws_subnet.database.id
  }
}
output "public_server_ip" {
  value = aws_eip.public_server.public_ip
}
output "private_instance_ips" {
  value = {
    application = aws_instance.app.private_ip
    middleware  = aws_instance.middleware.private_ip
    database    = aws_instance.database.private_ip
  }
}
output "security_group_ids" {
  value = {
    public     = aws_security_group.public.id
    application = aws_security_group.app.id
    middleware = aws_security_group.middleware.id
    database   = aws_security_group.database.id
  }
}
output "test_url" {
  value = "http://${aws_eip.public_server.public_ip}"
}
