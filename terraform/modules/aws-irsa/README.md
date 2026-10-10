<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |

## Providers

No providers.

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_this"></a> [this](#module\_this) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks | ~> 5.0 |

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_namespace_service_accounts"></a> [namespace\_service\_accounts](#input\_namespace\_service\_accounts) | 이 Role을 assume할 수 있는 "namespace:service\_account" 목록. 보통 1개지만, 같은 권한을 여러 SA가 공유해야 하면 여러 개를 넣는다. | `list(string)` | n/a | yes |
| <a name="input_oidc_provider_arn"></a> [oidc\_provider\_arn](#input\_oidc\_provider\_arn) | aws-eks 모듈 output.oidc\_provider\_arn. 이 클러스터 안 파드만 이 Role을 assume할 수 있다. | `string` | n/a | yes |
| <a name="input_policy_arns"></a> [policy\_arns](#input\_policy\_arns) | 이 Role에 attach할 IAM Policy ARN 맵(key는 임의 식별자). 정책 내용 자체는 호출하는 쪽이 만든다. | `map(string)` | `{}` | no |
| <a name="input_role_name"></a> [role\_name](#input\_role\_name) | IAM Role 이름. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | n/a | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_role_arn"></a> [role\_arn](#output\_role\_arn) | serviceAccount.annotations."eks.amazonaws.com/role-arn"에 그대로 넣는다. |
<!-- END_TF_DOCS -->