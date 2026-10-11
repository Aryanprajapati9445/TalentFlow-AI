variable "aws_region" {
  description = "Region for the S3 bucket and regional resources."
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  type    = string
  default = "talentflow-ai"
}

variable "github_owner" {
  type    = string
  default = "Aryanprajapati9445"
}

variable "github_repo" {
  type    = string
  default = "TalentFlow-AI"
}

variable "github_branch" {
  type    = string
  default = "main"
}

variable "alert_email" {
  description = "Optional email for budget and alarm notifications."
  type        = string
  default     = ""
}