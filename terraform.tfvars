aws_region = "eu-west-1"
env        = "prod"

# Your IP address in CIDR format
# Find your IP by going to https://whatismyip.com
# Add /32 at the end — e.g. 102.89.45.123/32
my_ip = "75.155.244.239/32"

# ECR image URI — we will fill this after terraform apply creates the ECR repo
# For now use a placeholder — we will update it later
ecr_image = "052032053375.dkr.ecr.eu-west-1.amazonaws.com/concord-consulting-web:latest"

# Database credentials — use a strong password
db_name = "concordconsultingdb"
db_user = "concordconsulting_admin"
db_pass = "ConcordC0nsulting2026!"


