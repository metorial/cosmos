# IAM Role for EC2 instances to use SSM and describe instances
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

# IAM Policy for EC2 autodiscovery
data "aws_iam_policy_document" "ec2_describe" {
  statement {
    effect = "Allow"

    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
    ]

    resources = ["*"]
  }
}

# IAM Policy for SSM Parameter Store
data "aws_iam_policy_document" "ssm" {
  statement {
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:PutParameter",
    ]

    resources = [
      "arn:aws:ssm:${var.aws_region}:*:parameter/${local.cluster_name}/*"
    ]
  }
}

# Bastion IAM Role
resource "aws_iam_role" "bastion" {
  name               = "${local.cluster_name}-bastion-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy" "bastion_ec2" {
  name   = "${local.cluster_name}-bastion-ec2-policy"
  role   = aws_iam_role.bastion.id
  policy = data.aws_iam_policy_document.ec2_describe.json
}

resource "aws_iam_role_policy" "bastion_ssm" {
  name   = "${local.cluster_name}-bastion-ssm-policy"
  role   = aws_iam_role.bastion.id
  policy = data.aws_iam_policy_document.ssm.json
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${local.cluster_name}-bastion-profile"
  role = aws_iam_role.bastion.name

  tags = local.common_tags
}

# Consul Server IAM Role
resource "aws_iam_role" "consul_server" {
  name               = "${local.cluster_name}-consul-server-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy" "consul_server_ec2" {
  name   = "${local.cluster_name}-consul-server-ec2-policy"
  role   = aws_iam_role.consul_server.id
  policy = data.aws_iam_policy_document.ec2_describe.json
}

resource "aws_iam_role_policy" "consul_server_ssm" {
  name   = "${local.cluster_name}-consul-server-ssm-policy"
  role   = aws_iam_role.consul_server.id
  policy = data.aws_iam_policy_document.ssm.json
}

resource "aws_iam_instance_profile" "consul_server" {
  name = "${local.cluster_name}-consul-server-profile"
  role = aws_iam_role.consul_server.name

  tags = local.common_tags
}

# Vault Server IAM Role
resource "aws_iam_role" "vault_server" {
  name               = "${local.cluster_name}-vault-server-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy" "vault_server_ec2" {
  name   = "${local.cluster_name}-vault-server-ec2-policy"
  role   = aws_iam_role.vault_server.id
  policy = data.aws_iam_policy_document.ec2_describe.json
}

resource "aws_iam_role_policy" "vault_server_ssm" {
  name   = "${local.cluster_name}-vault-server-ssm-policy"
  role   = aws_iam_role.vault_server.id
  policy = data.aws_iam_policy_document.ssm.json
}

resource "aws_iam_instance_profile" "vault_server" {
  name = "${local.cluster_name}-vault-server-profile"
  role = aws_iam_role.vault_server.name

  tags = local.common_tags
}

# Nomad Server IAM Role
resource "aws_iam_role" "nomad_server" {
  name               = "${local.cluster_name}-nomad-server-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy" "nomad_server_ec2" {
  name   = "${local.cluster_name}-nomad-server-ec2-policy"
  role   = aws_iam_role.nomad_server.id
  policy = data.aws_iam_policy_document.ec2_describe.json
}

resource "aws_iam_role_policy" "nomad_server_ssm" {
  name   = "${local.cluster_name}-nomad-server-ssm-policy"
  role   = aws_iam_role.nomad_server.id
  policy = data.aws_iam_policy_document.ssm.json
}

resource "aws_iam_instance_profile" "nomad_server" {
  name = "${local.cluster_name}-nomad-server-profile"
  role = aws_iam_role.nomad_server.name

  tags = local.common_tags
}

# Nomad Client IAM Role
resource "aws_iam_role" "nomad_client" {
  name               = "${local.cluster_name}-nomad-client-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy" "nomad_client_ec2" {
  name   = "${local.cluster_name}-nomad-client-ec2-policy"
  role   = aws_iam_role.nomad_client.id
  policy = data.aws_iam_policy_document.ec2_describe.json
}

resource "aws_iam_role_policy" "nomad_client_ssm" {
  name   = "${local.cluster_name}-nomad-client-ssm-policy"
  role   = aws_iam_role.nomad_client.id
  policy = data.aws_iam_policy_document.ssm.json
}

resource "aws_iam_instance_profile" "nomad_client" {
  name = "${local.cluster_name}-nomad-client-profile"
  role = aws_iam_role.nomad_client.name

  tags = local.common_tags
}
