terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

resource "aws_oam_sink" "this" {
  name = var.sink_name
}

resource "aws_oam_sink_policy" "this" {
  sink_identifier = aws_oam_sink.this.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowOrgAccountsToLink"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["oam:CreateLink", "oam:UpdateLink"]
        Resource  = "*"
        Condition = {
          "ForAllValues:StringEquals" = {
            "aws:PrincipalOrgID" = [var.organization_id]
            "oam:ResourceTypes" = [
              "AWS::CloudWatch::Metric",
              "AWS::Logs::LogGroup",
              "AWS::XRay::Trace",
            ]
          }
        }
      },
    ]
  })
}
