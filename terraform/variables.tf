variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "github_org" {
  description = "Your GitHub org or username"
  type        = string
}

variable "github_repo" {
  description = "Your GitHub repository name (without the org prefix)"
  type        = string
}

variable "github_branch" {
  description = "Branch allowed to assume the role"
  type        = string
  default     = "main"
}

variable "s3_bucket_name" {
  description = "Name of the S3 bucket GitHub Actions is allowed to read from"
  type        = string
}