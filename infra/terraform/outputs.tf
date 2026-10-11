output "website_url" {
  description = "CloudFront URL for TalentFlow-AI"
  value       = "https://${aws_cloudfront_distribution.site.domain_name}"
}

output "s3_bucket_name" {
  value = aws_s3_bucket.site.bucket
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.site.id
}

output "github_deployment_role_arn" {
  value = aws_iam_role.github_deploy.arn
}