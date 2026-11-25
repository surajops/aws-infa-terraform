variable "aws_region" {
  type    = string
  default = "ap-south-1"
}
variable "project_name" {
  type    = string
  default = "himu-three-tier-lab"
}
variable "environment" {
  type    = string
  default = "lab"
}
variable "availability_zone" {
  type    = string
  default = "ap-south-1a"
}
variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}
variable "public_subnet_cidr" {
  type    = string
  default = "10.20.1.0/24"
}
variable "app_subnet_cidr" {
  type    = string
  default = "10.20.2.0/24"
}
variable "middleware_subnet_cidr" {
  type    = string
  default = "10.20.3.0/24"
}
variable "database_subnet_cidr" {
  type    = string
  default = "10.20.4.0/24"
}
variable "instance_type" {
  type    = string
  default = "t3.micro"
}
variable "app_port" {
  type    = number
  default = 8000
}
variable "public_http_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}
variable "enable_nat_gateway" {
  type    = bool
  default = true
}
