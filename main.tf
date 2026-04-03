provider "aws" {
  region = var.aws_region
}

# ── VPC ─────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "concord-consulting-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"
  tags = { Name = "concord-consulting-public-subnet" }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}a"
  tags = { Name = "concord-consulting-private-subnet-a" }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "${var.aws_region}b"
  tags = { Name = "concord-consulting-private-subnet-b" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "concord-consulting-igw" }
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "concord-consulting-rt" }
}

resource "aws_route_table_association" "rta" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.rt.id
}

# ── Security Groups ──────────────────────────────────────────
resource "aws_security_group" "web_sg" {
  name   = "concord-consulting-web-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "concord-consulting-web-sg" }
}

resource "aws_security_group" "rds_sg" {
  name   = "concord-consulting-rds-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "concord-consulting-rds-sg" }
}

# ── EC2 Instance ─────────────────────────────────────────────
resource "aws_instance" "web" {
  ami                    = var.ami_id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    amazon-linux-extras install docker -y
    service docker start
    usermod -a -G docker ec2-user
    systemctl enable docker
    yum install -y amazon-ssm-agent
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent
    aws ecr get-login-password --region ${var.aws_region} \
      | docker login --username AWS --password-stdin ${var.ecr_image}
    docker pull ${var.ecr_image}
    docker run -d \
      -p 80:3000 \
      --restart unless-stopped \
      -e PORT=3000 \
      -e DB_HOST=${aws_db_instance.mysql.address} \
      -e DB_PORT=3306 \
      -e DB_USER=${var.db_user} \
      -e DB_PASS=${var.db_pass} \
      -e DB_NAME=${var.db_name} \
      --name concord-consulting-web \
      ${var.ecr_image}
  EOF

  tags       = { Name = "concord-consulting-web-server" }
  depends_on = [aws_db_instance.mysql]
}

# ── Elastic IP — Fixed Public IP for EC2 ────────────────────
resource "aws_eip" "web" {
  instance = aws_instance.web.id
  domain   = "vpc"
  tags     = { Name = "concord-consulting-eip" }
  depends_on = [aws_internet_gateway.igw]
}

# ── RDS MySQL ────────────────────────────────────────────────
resource "aws_db_subnet_group" "rds_subnets" {
  name       = "concord-consulting-rds-subnet-group"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  tags       = { Name = "concord-consulting-rds-subnet-group" }
}

resource "aws_db_instance" "mysql" {
  identifier              = "concord-consulting-db"
  engine                  = "mysql"
  engine_version          = "8.0"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  storage_type            = "gp2"
  storage_encrypted       = true
  db_name                 = var.db_name
  username                = var.db_user
  password                = var.db_pass
  db_subnet_group_name    = aws_db_subnet_group.rds_subnets.name
  vpc_security_group_ids  = [aws_security_group.rds_sg.id]
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 0
  publicly_accessible     = false
  tags                    = { Name = "concord-consulting-mysql" }
}

# ── S3 — Static Assets ───────────────────────────────────────
resource "aws_s3_bucket" "assets" {
  bucket = "concord-consulting-assets-${var.env}"
  tags   = { Name = "concord-consulting-assets" }
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── S3 — CodePipeline Artifacts ──────────────────────────────
resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket        = "concord-consulting-pipeline-artifacts-${var.env}"
  force_destroy = true
  tags          = { Name = "concord-consulting-pipeline-artifacts" }
}

resource "aws_s3_bucket_public_access_block" "pipeline_artifacts" {
  bucket                  = aws_s3_bucket.pipeline_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── ECR Repository ───────────────────────────────────────────
resource "aws_ecr_repository" "app" {
  name                 = "concord-consulting-web"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = { Name = "concord-consulting-ecr" }
}

# ── CodeCommit Repository ─────────────────────────────────────
resource "aws_codecommit_repository" "app" {
  repository_name = "concord-consulting-web"
  description     = "Concord Consulting website source code"
  tags            = { Name = "concord-consulting-repo" }
}

# ── SSM Parameter Store ───────────────────────────────────────
resource "aws_ssm_parameter" "db_host" {
  name  = "/concordconsulting/prod/DB_HOST"
  type  = "SecureString"
  value = aws_db_instance.mysql.address
}

resource "aws_ssm_parameter" "db_user" {
  name  = "/concordconsulting/prod/DB_USER"
  type  = "SecureString"
  value = var.db_user
}

resource "aws_ssm_parameter" "db_pass" {
  name  = "/concordconsulting/prod/DB_PASS"
  type  = "SecureString"
  value = var.db_pass
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/concordconsulting/prod/DB_NAME"
  type  = "SecureString"
  value = var.db_name
}

# ── IAM — EC2 Role ────────────────────────────────────────────
resource "aws_iam_role" "ec2_role" {
  name = "concord-consulting-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ecr" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ec2_cloudwatch" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "concord-consulting-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# ── IAM — CodeBuild Role ──────────────────────────────────────
resource "aws_iam_role" "codebuild_role" {
  name = "concord-consulting-codebuild-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "codebuild_policy" {
  name = "concord-consulting-codebuild-policy"
  role = aws_iam_role.codebuild_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:GetBucketLocation"]
        Resource = [
          aws_s3_bucket.pipeline_artifacts.arn,
          "${aws_s3_bucket.pipeline_artifacts.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
          "ssm:SendCommand",
          "ssm:GetCommandInvocation"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = "*"
      }
    ]
  })
}

# ── IAM — CodePipeline Role ───────────────────────────────────
resource "aws_iam_role" "codepipeline_role" {
  name = "concord-consulting-codepipeline-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "concord-consulting-codepipeline-policy"
  role = aws_iam_role.codepipeline_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "codecommit:GetBranch",
          "codecommit:GetCommit",
          "codecommit:UploadArchive",
          "codecommit:GetUploadArchiveStatus",
          "codecommit:CancelUploadArchive"
        ]
        Resource = aws_codecommit_repository.app.arn
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"]
        Resource = aws_codebuild_project.app.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:GetBucketVersioning",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.pipeline_artifacts.arn,
          "${aws_s3_bucket.pipeline_artifacts.arn}/*"
        ]
      }
    ]
  })
}

# ── CodeBuild Project ─────────────────────────────────────────
resource "aws_codebuild_project" "app" {
  name          = "concord-consulting-build"
  description   = "Concord Consulting — build, test, push, deploy"
  service_role  = aws_iam_role.codebuild_role.arn
  build_timeout = 20

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    type            = "LINUX_CONTAINER"
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    privileged_mode = true

    environment_variable {
      name  = "AWS_REGION"
      value = var.aws_region
    }
    environment_variable {
      name  = "ECR_REPO"
      value = aws_ecr_repository.app.name
    }
    environment_variable {
      name  = "EC2_INSTANCE_ID"
      value = aws_instance.web.id
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/concord-consulting"
      stream_name = "build-log"
    }
  }

  tags = { Name = "concord-consulting-codebuild" }
}

# ── CodePipeline ──────────────────────────────────────────────
resource "aws_codepipeline" "app" {
  name     = "concord-consulting-pipeline"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    location = aws_s3_bucket.pipeline_artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["source_output"]
      configuration = {
        RepositoryName       = aws_codecommit_repository.app.repository_name
        BranchName           = "main"
        PollForSourceChanges = "true"
      }
    }
  }

  stage {
    name = "Build"
    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      configuration = {
        ProjectName = aws_codebuild_project.app.name
      }
    }
  }

  tags = { Name = "concord-consulting-pipeline" }
}

# ── CloudWatch — CodeBuild Log Group ─────────────────────────
resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/aws/codebuild/concord-consulting"
  retention_in_days = 14
  tags              = { Name = "concord-consulting-codebuild-logs" }
}

# ── CloudWatch — Application Log Group ───────────────────────
resource "aws_cloudwatch_log_group" "app" {
  name              = "/concord-consulting/app"
  retention_in_days = 14
  tags              = { Name = "concord-consulting-app-logs" }
}

# ── CloudWatch — EC2 CPU Alarm ────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "ec2_cpu_high" {
  alarm_name          = "concord-consulting-ec2-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "EC2 CPU above 80% for 4 minutes"
  treat_missing_data  = "notBreaching"
  dimensions          = { InstanceId = aws_instance.web.id }
  tags                = { Name = "concord-consulting-ec2-cpu-alarm" }
}

# ── CloudWatch — EC2 Status Check Alarm ──────────────────────
resource "aws_cloudwatch_metric_alarm" "ec2_status_check" {
  alarm_name          = "concord-consulting-ec2-status-check"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "EC2 status check failed — server may be down"
  treat_missing_data  = "breaching"
  dimensions          = { InstanceId = aws_instance.web.id }
  tags                = { Name = "concord-consulting-ec2-status-alarm" }
}

# ── CloudWatch — RDS CPU Alarm ────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "concord-consulting-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 120
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS CPU above 80% for 4 minutes"
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.mysql.id }
  tags                = { Name = "concord-consulting-rds-cpu-alarm" }
}

# ── CloudWatch — RDS Low Storage Alarm ───────────────────────
resource "aws_cloudwatch_metric_alarm" "rds_storage_low" {
  alarm_name          = "concord-consulting-rds-storage-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 2000000000
  alarm_description   = "RDS free storage below 2GB"
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.mysql.id }
  tags                = { Name = "concord-consulting-rds-storage-alarm" }
}

# ── CloudWatch — RDS Connections Alarm ───────────────────────
resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "concord-consulting-rds-connections"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 120
  statistic           = "Average"
  threshold           = 50
  alarm_description   = "RDS connections above 50"
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.mysql.id }
  tags                = { Name = "concord-consulting-rds-connections-alarm" }
}

# ── CloudWatch Dashboard ──────────────────────────────────────
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "concord-consulting-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "EC2 CPU Utilisation"
          region  = "eu-west-1"
          period  = 300
          stat    = "Average"
          view    = "timeSeries"
          stacked = false
          metrics = [["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.web.id]]
          yAxis   = { left = { min = 0, max = 100 } }
          annotations = {
            horizontal = [{ value = 80, label = "Alarm threshold", color = "#ff0000" }]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "RDS CPU Utilisation"
          region  = "eu-west-1"
          period  = 300
          stat    = "Average"
          view    = "timeSeries"
          stacked = false
          metrics = [["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.mysql.id]]
          yAxis   = { left = { min = 0, max = 100 } }
          annotations = {
            horizontal = [{ value = 80, label = "Alarm threshold", color = "#ff0000" }]
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "EC2 Network In/Out"
          region  = "eu-west-1"
          period  = 300
          stat    = "Sum"
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/EC2", "NetworkIn",  "InstanceId", aws_instance.web.id],
            ["AWS/EC2", "NetworkOut", "InstanceId", aws_instance.web.id]
          ]
          annotations = { horizontal = [] }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "RDS Database Connections"
          region  = "eu-west-1"
          period  = 300
          stat    = "Average"
          view    = "timeSeries"
          stacked = false
          metrics = [["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.mysql.id]]
          annotations = { horizontal = [] }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "RDS Free Storage Space"
          region  = "eu-west-1"
          period  = 300
          stat    = "Average"
          view    = "timeSeries"
          stacked = false
          metrics = [["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", aws_db_instance.mysql.id]]
          annotations = {
            horizontal = [{ value = 2000000000, label = "2GB warning", color = "#ff9900" }]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "EC2 Status Check"
          region  = "eu-west-1"
          period  = 60
          stat    = "Maximum"
          view    = "timeSeries"
          stacked = false
          metrics = [["AWS/EC2", "StatusCheckFailed", "InstanceId", aws_instance.web.id]]
          annotations = {
            horizontal = [{ value = 1, label = "Status check failed", color = "#ff0000" }]
          }
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 18
        width  = 24
        height = 6
        properties = {
          title  = "CodeBuild Logs - Recent Deployments"
          region = "eu-west-1"
          query  = "SOURCE '/aws/codebuild/concord-consulting' | fields @timestamp, @message | sort @timestamp desc | limit 50"
          view   = "table"
        }
      }
    ]
  })
}

# ── CloudFront Distribution ───────────────────────────────────
resource "aws_cloudfront_distribution" "web" {
  enabled             = true
  default_root_object = "index.html"
  comment             = "Concord Consulting HTTPS CDN"

  origin {
    domain_name = aws_eip.web.public_dns
    origin_id   = "concord-ec2-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "concord-ec2-origin"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = true
      headers      = ["Origin", "Access-Control-Request-Headers", "Access-Control-Request-Method", "Host"]
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags       = { Name = "concord-consulting-cloudfront" }
  depends_on = [aws_instance.web]
}
