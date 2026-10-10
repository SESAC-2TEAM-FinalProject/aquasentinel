<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 5.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_acm_certificate.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate) | resource |
| [aws_acm_certificate_validation.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate_validation) | resource |
| [aws_route53_health_check.alb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_health_check) | resource |
| [aws_route53_record.cert_validation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route53_record.failover](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_lb.gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/lb) | data source |
| [aws_lbs.gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/lbs) | data source |
| [aws_route53_zone.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route53_zone) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | 이 리전 EKS 클러스터 이름 — AWS LBC가 ALB에 붙이는 elbv2.k8s.aws/cluster 태그값과 매칭해 ALB를 조회한다. enable\_failover\_routing=true일 때 필수. | `string` | `null` | no |
| <a name="input_create_certificate"></a> [create\_certificate](#input\_create\_certificate) | true면 ACM 인증서를 발급한다(persistent 컴포넌트). false면 다른 호출(4-edge)이 이미 만든 인증서가 있다고 가정하고 이 모듈은 레코드만 다룬다. | `bool` | `true` | no |
| <a name="input_domain_name"></a> [domain\_name](#input\_domain\_name) | 이미 Route53에 존재하는 Hosted Zone 이름 (apex 그대로 사용). 나중에 프로젝트 전용 도메인을 구매하면 이 값만 바꾸면 된다. | `string` | n/a | yes |
| <a name="input_enable_failover_routing"></a> [enable\_failover\_routing](#input\_enable\_failover\_routing) | true면 이 리전의 Gateway API ALB를 Route53 Failover 레코드(apex, alias)로 등록한다. 서울/도쿄 둘 다 true로 두고 failover\_role로만 구분한다. | `bool` | `false` | no |
| <a name="input_enable_health_check"></a> [enable\_health\_check](#input\_enable\_health\_check) | true면 이 리전 ALB에 Route53 헬스체크를 만들어 PRIMARY 레코드에 연결한다. 서울(PRIMARY)에만 켠다 — 도쿄는 헬스체크 없이 PRIMARY 장애 시에만 응답. | `bool` | `false` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | n/a | `string` | n/a | yes |
| <a name="input_failover_hostnames"></a> [failover\_hostnames](#input\_failover\_hostnames) | Failover 레코드를 만들 호스트 이름 목록. ""는 apex(루트 도메인), 나머지는 서브도메인 prefix(예: "auth" → auth.<domain\_name>). enable\_failover\_routing=true일 때만 사용. | `list(string)` | <pre>[<br/>  ""<br/>]</pre> | no |
| <a name="input_failover_role"></a> [failover\_role](#input\_failover\_role) | PRIMARY 또는 SECONDARY. enable\_failover\_routing=true일 때만 사용 — 서울=PRIMARY, 도쿄=SECONDARY. | `string` | `"SECONDARY"` | no |
| <a name="input_gateway_name"></a> [gateway\_name](#input\_gateway\_name) | Gateway API Gateway 리소스 이름 (manifests/gateway-api/gateway.yaml 기준). | `string` | `"aquasentinel-gw"` | no |
| <a name="input_gateway_namespace"></a> [gateway\_namespace](#input\_gateway\_namespace) | Gateway API Gateway 리소스의 네임스페이스 (manifests/gateway-api/gateway.yaml 기준). | `string` | `"ingress"` | no |
| <a name="input_health_check_path"></a> [health\_check\_path](#input\_health\_check\_path) | 헬스체크 HTTP(S) 경로. 대시보드 앱의 health/readiness 엔드포인트가 정해지면 그 값으로 바꾼다. | `string` | `"/"` | no |
| <a name="input_include_wildcard_san"></a> [include\_wildcard\_san](#input\_include\_wildcard\_san) | true면 *.domain\_name도 SAN에 포함해 Grafana·Argo CD 등 서브도메인 노출을 대비한다. | `bool` | `true` | no |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | n/a | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | n/a | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alb_dns_name"></a> [alb\_dns\_name](#output\_alb\_dns\_name) | enable\_failover\_routing=false면 null. |
| <a name="output_certificate_arn"></a> [certificate\_arn](#output\_certificate\_arn) | 검증 완료된 인증서 ARN. create\_certificate=false면 null — 호출하는 쪽이 persistent의 remote\_state에서 직접 읽어야 한다. |
| <a name="output_domain_name"></a> [domain\_name](#output\_domain\_name) | n/a |
| <a name="output_health_check_id"></a> [health\_check\_id](#output\_health\_check\_id) | enable\_health\_check=false면 null. |
| <a name="output_zone_id"></a> [zone\_id](#output\_zone\_id) | n/a |
<!-- END_TF_DOCS -->