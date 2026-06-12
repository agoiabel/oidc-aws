# oidc-aws

GitHub Actions → AWS authentication via OIDC federation, with no long-lived access keys stored anywhere.

## What this does

Instead of storing `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in GitHub secrets, each workflow run requests a short-lived JWT from GitHub's OIDC provider and exchanges it directly for temporary AWS credentials via `sts:AssumeRoleWithWebIdentity`. The credentials expire after the run; there are no static keys to rotate or leak.

```
GitHub Actions run
  │
  ├─ 1. Requests a signed JWT from GitHub's OIDC endpoint
  │       (token.actions.githubusercontent.com)
  │
  ├─ 2. Calls sts:AssumeRoleWithWebIdentity with that JWT
  │       → AWS verifies the token against the registered IdP
  │       → IAM trust policy checks the repo + branch claim
  │
  └─ 3. Receives temporary credentials (≈1 hour TTL)
          AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN
```

## Infrastructure

All AWS resources are managed with Terraform under [terraform/](terraform/).

### Resources created

| Resource | Name | Purpose |
|---|---|---|
| `aws_iam_openid_connect_provider` | `github` | Registers GitHub's OIDC server as a trusted IdP in the AWS account |
| `aws_iam_role` | `github-actions-{repo}` | The role workflows assume; trust policy is the OIDC gate |
| `aws_iam_role_policy` | `github-actions-permissions` | Permissions granted once the role is assumed |

### OIDC provider

Registers `https://token.actions.githubusercontent.com` with audience `sts.amazonaws.com`. This is a single per-account resource — multiple roles can reference the same provider.

The `thumbprint_list` is left empty because AWS validates GitHub tokens against its own trusted CA library and ignores any configured thumbprints for this IdP.

### IAM trust policy

The trust policy locks role assumption to a specific repository and branch using two OIDC claim conditions:

```
aud = sts.amazonaws.com
sub = repo:{org}/{repo}:ref:refs/heads/{branch}
```

Both conditions must match. A token from a different repo, org, or branch is rejected before credentials are issued.

### IAM permissions policy

Minimal permissions scoped to a specific S3 bucket:

- `s3:GetObject` — read objects
- `s3:ListBucket` — list bucket contents
- `s3:GetBucketLocation` — resolve bucket region
- `sts:GetCallerIdentity` — identity verification (useful for debugging)

## Setup

### Prerequisites

- Terraform >= 1.0
- AWS credentials with IAM write access (for the initial `terraform apply`)
- An S3 bucket the role should be allowed to read from

### 1. Configure variables

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars`:

```hcl
aws_region     = "eu-west-1"
github_org     = "your-org-or-username"
github_repo    = "your-repo-name"
github_branch  = "main"
s3_bucket_name = "your-bucket-name"
```

### 2. Apply

```bash
cd terraform
terraform init
terraform apply
```

Note the outputs:

```
github_actions_role_arn = "arn:aws:iam::123456789012:role/github-actions-your-repo"
oidc_provider_arn       = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
role_name               = "github-actions-your-repo"
```

### 3. Wire up the workflow

Paste the `github_actions_role_arn` output into your workflow's `role-to-assume`:

```yaml
- name: Configure AWS credentials via OIDC
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::123456789012:role/github-actions-your-repo
    aws-region: eu-west-1
    role-session-name: github-actions-${{ github.run_id }}
```

## GitHub Actions workflow

[.github/workflows/aws-oidc-test.yml](.github/workflows/aws-oidc-test.yml) is a working example that:

1. Checks out the repo
2. Authenticates to AWS via OIDC using `aws-actions/configure-aws-credentials@v4`
3. Calls `aws sts get-caller-identity` to confirm the assumed role
4. Decodes and prints the raw JWT claims for debugging

Triggers: push to `main`, or manual dispatch from the GitHub UI.

### Critical permission block

```yaml
permissions:
  id-token: write   # allows GitHub to mint an OIDC JWT for this run
  contents: read    # allows repo checkout
```

Without `id-token: write` the workflow cannot request a token and the assume-role step fails with "credentials not found".

### Debugging JWT claims

The workflow includes a step that decodes the JWT payload so you can inspect exactly what claims GitHub is sending:

```bash
TOKEN=$(curl -sH "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r '.value')
echo $TOKEN | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .
```

This is safe to print — the token has already been consumed by STS at this point. Useful for confirming the `sub` claim matches what the trust policy expects.

## Variables reference

| Variable | Default | Required | Description |
|---|---|---|---|
| `aws_region` | `eu-west-1` | no | AWS region to deploy into |
| `github_org` | — | yes | GitHub org or username |
| `github_repo` | — | yes | Repository name (without org prefix) |
| `github_branch` | `main` | no | Branch allowed to assume the role |
| `s3_bucket_name` | — | yes | S3 bucket the role can read from |

## Outputs reference

| Output | Description |
|---|---|
| `github_actions_role_arn` | Paste this into `role-to-assume` in your workflow |
| `oidc_provider_arn` | ARN of the registered GitHub OIDC provider |
| `role_name` | Name of the IAM role |

## Extending permissions

To grant the role access to additional AWS services, add statements to the `github_actions_permissions` policy document in [terraform/main.tf](terraform/main.tf):

```hcl
statement {
  effect    = "Allow"
  actions   = ["ecr:GetAuthorizationToken", "ecr:BatchGetImage"]
  resources = ["*"]
}
```

Run `terraform apply` to push the change. No workflow changes needed — the role ARN stays the same.

## Security notes

- The OIDC provider is registered once per AWS account and shared. Multiple roles can reference it without duplicating the resource.
- The `sub` condition uses `StringLike` to allow wildcard matching (e.g. all branches via `repo:org/repo:*`). The current config uses an exact branch to be maximally restrictive.
- All `sts:AssumeRoleWithWebIdentity` calls are logged in CloudTrail with the `role-session-name` as the session identifier — use `github-actions-${{ github.run_id }}` to trace any credential back to a specific run.
- `terraform.tfvars` is gitignored to prevent accidental exposure of account-specific values.
