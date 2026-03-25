variable "aws_region"  { default = "eu-west-1" }
variable "ami_id"      { default = "ami-0c02fb55956c7d316" } # Amazon Linux 2
variable "my_ip"       { description = "Your IP in CIDR format, e.g. 1.2.3.4/32" }
variable "ecr_image"   { description = "Full ECR image URI for initial EC2 bootstrap — e.g. 123456789.dkr.ecr.eu-west-1.amazonaws.com/concord-web:latest" }
variable "env"         { default = "prod" }

# Database credentials — pass via terraform.tfvars
# NEVER hardcode these values here
variable "db_name" { default = "concorddb" }
variable "db_user" { description = "RDS master username" }
variable "db_pass" { description = "RDS master password"; sensitive = true }
