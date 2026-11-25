# Himu Three-Tier AWS Lab — Terraform

Creates a single-AZ AWS lab architecture in ap-south-1:

- Public subnet: Nginx reverse-proxy EC2 with Elastic IP.
- Application subnet: private EC2 running a demo HTTP service on TCP/8000.
- Middleware subnet: private EC2 reserved for Redis, Kafka and Elasticsearch.
- Database subnet: private EC2 reserved for MySQL and MongoDB.
- VPC DNS, Internet Gateway, one NAT Gateway, public/private route tables,
  tier-specific Security Groups, EC2 SSM IAM role and instance profile.

**Important:** Middleware and database software is NOT installed by this project.
Only their EC2 instances, subnet placement and inbound network rules are created.
Install and secure those services in a later step.

## Design assumptions

- Learning/lab architecture, not HA production.
- One AZ (`ap-south-1a`) and one NAT Gateway to keep the design simple.
- Ubuntu Server 24.04 LTS AMI resolved using Canonical's public SSM parameter.
- Use Systems Manager Session Manager for administration; no inbound SSH rule.
- Public Nginx listens on HTTP/80. TLS/HTTPS is not configured.
- Security Group egress is open for this lab; inbound is restricted by SG references.
- Public -> App: TCP/8000.
- App -> Middleware: TCP/6379, 9092, 9200.
- App -> Database: TCP/3306, 27017.
- No Middleware -> Database inbound rule is created.
- The CIDR ranges must not overlap with any connected VPC/on-premises networks.

## Prerequisites

Install Terraform 1.5+ and AWS CLI. Configure credentials using `aws configure`
or AWS IAM Identity Center. Verify identity:

```bash
aws sts get-caller-identity
```

The AWS identity needs permission to create VPC, EC2, IAM role/profile, EIP,
NAT Gateway, route tables, routes and Security Groups.

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

Review the plan before applying. These are billable resources.

After deployment:

```bash
terraform output
terraform output -raw test_url
```

Open the test URL. You should see "Application Server is reachable". The request
goes to public Nginx, then across the private VPC network to the app instance.

## Connect to EC2

AWS Console -> EC2 -> Instances -> select an instance -> Connect ->
Session Manager -> Connect.

The instances have an instance profile with `AmazonSSMManagedInstanceCore`.
Private instances use the NAT Gateway for outbound access to Systems Manager
and package repositories. Your AWS IAM user/role also needs permission to start
SSM sessions.

## Verification

On the public instance:

```bash
curl -i http://127.0.0.1/nginx-health
curl -i http://<APP_PRIVATE_IP>:8000/
sudo nginx -t
sudo systemctl status nginx
```

On the application instance:

```bash
sudo systemctl status himu-demo-app
sudo ss -lntp | grep 8000
```

If the test page fails, inspect `/var/log/cloud-init-output.log` on both instances,
check the public route to the IGW, public SG TCP/80, app SG TCP/8000 from public SG,
and the application service logs with `journalctl -u himu-demo-app`.

A TCP port will only accept connections once the corresponding software is
installed, configured to listen on the instance's private interface, and running.

## Cost warning

This project creates four EC2 instances, EBS volumes, one NAT Gateway, two
Elastic IP allocations (NAT and public server), and data transfer. NAT Gateways
have hourly and per-GB processing charges. Check current AWS pricing for
ap-south-1 before deploying.

If private instances do not need outbound internet, set
`enable_nat_gateway = false` in `terraform.tfvars`; then private instances will
need VPC endpoints or another route for Systems Manager connectivity.

## Destroy

```bash
terraform destroy
```

Review the destroy plan. Back up any data you need first.
