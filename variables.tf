variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  type    = string
  default = "aws-assignments"
}

variable "vpc_cidr" {
  description = "VPC CIDR; /17 provides 32768 addresses"
  type        = string
  default     = "10.20.0.0/17"
}

variable "public_http_cidrs" {
  description = "Public client CIDRs allowed to reach HTTP"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "public_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "app_instance_type" {
  type    = string
  default = "t3.small"
}

variable "middleware_instance_type" {
  type    = string
  default = "t3.small"
}

variable "database_instance_type" {
  type    = string
  default = "t3.small"
}

variable "enable_nat_gateway" {
  description = "NAT Gateway incurs hourly and data-processing charges"
  type        = bool
  default     = true
}
