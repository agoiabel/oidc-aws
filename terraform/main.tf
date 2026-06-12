terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ─────────────────────────────────────────────────────────────
# 1. Register GitHub's OIDC server as a trusted identity
#    provider in this AWS account. One per account, not one
#    per role — all roles in this account can reference it.
# ─────────────────────────────────────────────────────────────
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  # GitHub's OIDC audience — must match the `audience` in the
  # GitHub Actions workflow's `id-token` permission block.
  client_id_list = ["sts.amazonaws.com"]

  # thumbprint_list is omitted: AWS validates GitHub tokens against its own
  # trusted CA library and ignores any configured thumbprints for this IdP.
  thumbprint_list = []
}

# ─────────────────────────────────────────────────────────────
# 2. IAM Role — the trust policy is the OIDC gate.
#    Only the exact repo+branch specified can assume it.
# ─────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # Verify the token targets this account's OIDC provider.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Lock to a specific repo and branch.
    # sub format: repo:{org}/{repo}:ref:refs/heads/{branch}
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:ref:refs/heads/${var.github_branch}"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "github-actions-${var.github_repo}"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json

  tags = {
    ManagedBy  = "terraform"
    Repository = "${var.github_org}/${var.github_repo}"
    Branch     = var.github_branch
  }
}

# ─────────────────────────────────────────────────────────────
# 3. Permissions granted to the role once assumed.
#    Scoped to a specific bucket. Keep it minimal.
# ─────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "github_actions_permissions" {
  statement {
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
    resources = [
      "arn:aws:s3:::${var.s3_bucket_name}",
      "arn:aws:s3:::${var.s3_bucket_name}/*",
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions_permissions" {
  name   = "github-actions-permissions"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_permissions.json
}