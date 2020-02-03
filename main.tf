# Provider
provider "aws" {
  # access_key = "XXXXXXXXXX"
  # secret_key = "YYYYYYYYYY"
  region = "ap-northeast-1"
}

# account_id
data "aws_caller_identity" "self" {}

# secrets manager
resource "aws_secretsmanager_secret" "box_credentials" {
  name = "${var.system_name}-box-credentials"
}

# apigw
resource "aws_api_gateway_rest_api" "box_webhook_api" {
  name = "${var.system_name}-box-sync-api"
}


resource "aws_api_gateway_resource" "box_webhook_resource" {
  rest_api_id = "${aws_api_gateway_rest_api.box_webhook_api.id}"
  parent_id   = "${aws_api_gateway_rest_api.box_webhook_api.root_resource_id}"
  path_part   = "webhook"
}

resource "aws_api_gateway_method" "box_webhook_method" {
  rest_api_id   = "${aws_api_gateway_rest_api.box_webhook_api.id}"
  resource_id   = "${aws_api_gateway_resource.box_webhook_resource.id}"
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_itg" {
  rest_api_id      = "${aws_api_gateway_rest_api.box_webhook_api.id}"
  resource_id      = "${aws_api_gateway_method.box_webhook_method.resource_id}"
  http_method      = "${aws_api_gateway_method.box_webhook_method.http_method}"
  content_handling = "CONVERT_TO_TEXT"

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = "${aws_lambda_function.box_webhook_handler.invoke_arn}"
}

resource "aws_api_gateway_deployment" "box_webhook_api_deployment" {
  depends_on = [
    aws_api_gateway_integration.lambda_itg
  ]

  rest_api_id = "${aws_api_gateway_rest_api.box_webhook_api.id}"
  stage_name  = "test"

  variables = {
    deployed_at = "${timestamp()}"
  }
}

# lambda
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "src"
  output_path = "lambda.zip"
}

resource "aws_lambda_function" "box_webhook_handler" {
  function_name = "${var.system_name}-box-webhook-handler"

  filename         = "${data.archive_file.lambda_zip.output_path}"
  handler          = "lambda.lambda_handler"
  runtime          = "python3.6"
  role             = "${aws_iam_role.lambda_iam_role.arn}"
  source_code_hash = "${data.archive_file.lambda_zip.output_base64sha256}"
  memory_size      = 128
  timeout          = 60

  environment {
    variables = {
      PYTHONPATH  = "/var/task/libs:/var/runtime"
      SECRET_NAME = "${aws_secretsmanager_secret.box_credentials.name}"
      BUCKET_NAME = "${aws_s3_bucket.box_sync_data.id}"
    }
  }
}

resource "aws_lambda_permission" "allow_apigw_to_call_box_webhook_handler" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.box_webhook_handler.function_name}"
  principal     = "apigateway.amazonaws.com"
  source_arn    = "arn:aws:execute-api:ap-northeast-1:${data.aws_caller_identity.self.account_id}:${aws_api_gateway_rest_api.box_webhook_api.id}/*/${aws_api_gateway_method.box_webhook_method.http_method}${aws_api_gateway_resource.box_webhook_resource.path}"
}


# iam
resource "aws_iam_role" "lambda_iam_role" {
  name = "${var.system_name}-lambda-iam-role"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy" "lambda_access_policy" {
  name   = "${var.system_name}-lambda-access-policy"
  role   = "${aws_iam_role.lambda_iam_role.id}"
  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:CreateLogGroup",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:*"
      ],
      "Resource": "${aws_s3_bucket.box_sync_data.arn}/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": [
        "${aws_secretsmanager_secret.box_credentials.arn}"
      ]
    }
  ]
}
POLICY
}

# s3
resource "aws_s3_bucket" "box_sync_data" {
  bucket = "${var.system_name}-box-sync-data"
  acl    = "private"
}
variable "system_name" {
  default="arai-test"
}
