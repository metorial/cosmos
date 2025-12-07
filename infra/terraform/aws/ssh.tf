# SSH Key Pair
resource "aws_key_pair" "main" {
  key_name   = var.ssh_key_name != "" ? var.ssh_key_name : "${local.cluster_name}-key"
  public_key = var.ssh_public_key != "" ? var.ssh_public_key : file("~/.ssh/id_rsa.pub")

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-key"
  })
}
