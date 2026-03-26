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

# ── S3 — CodePipeline Artifact Store ─────────────────────────
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
  description     = "Concord Consulting — IT, Education & Industry Website Source Code"
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
  description   = "Concord Consulting — Test, build Docker image, push to ECR, deploy to EC2"
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

# ── CloudWatch Log Group ──────────────────────────────────────
resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/aws/codebuild/concord-consulting"
  retention_in_days = 14
  tags              = { Name = "concord-consulting-codebuild-logs" }
}
