# KMS Key for Vault Auto-Unseal
resource "aws_kms_key" "vault" {
  description             = "${local.cluster_name} Vault auto-unseal key"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name    = "${local.cluster_name}-vault-key"
    Purpose = "vault-auto-unseal"
  })
}

resource "aws_kms_alias" "vault" {
  name          = "alias/${local.cluster_name}-vault"
  target_key_id = aws_kms_key.vault.key_id
}
