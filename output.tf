output "server_public_ip"       { value = aws_instance.web.public_ip }
output "website_url"            { value = "http://${aws_instance.web.public_ip}" }
output "s3_bucket_name"         { value = aws_s3_bucket.assets.bucket }
output "rds_endpoint"           { value = aws_db_instance.mysql.address }
output "rds_port"               { value = aws_db_instance.mysql.port }
output "ecr_repository_url"     { value = aws_ecr_repository.app.repository_url }
output "codecommit_clone_url"   { value = aws_codecommit_repository.app.clone_url_http }
output "codepipeline_name"      { value = aws_codepipeline.app.name }
output "codebuild_project_name" { value = aws_codebuild_project.app.name }

output "elastic_ip" {
  value       = aws_eip.web.public_ip
  description = "Fixed Elastic IP — never changes after stop/start"
}

output "cloudfront_url" {
  value       = "https://${aws_cloudfront_distribution.web.domain_name}"
  description = "Secure HTTPS CloudFront URL — use this instead of EC2 IP"
}
output "cloudfront_domain" {
  value       = aws_cloudfront_distribution.web.domain_name
  description = "CloudFront domain name"
}

output "cloudwatch_dashboard_url" {
  value       = "https://eu-west-1.console.aws.amazon.com/cloudwatch/home?region=eu-west-1#dashboards:name=concord-consulting-dashboard"
  description = "CloudWatch dashboard URL — view all metrics here"
}
output "cloudwatch_logs_url" {
  value       = "https://eu-west-1.console.aws.amazon.com/cloudwatch/home?region=eu-west-1#logsV2:log-groups/log-group/$252Faws$252Fcodebuild$252Fconcord-consulting"
  description = "CloudWatch CodeBuild logs URL"
}
