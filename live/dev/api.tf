resource "aws_apigatewayv2_api" "kb" {
  name          = "${local.name}-query-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_headers = ["content-type"]
    allow_methods = ["POST","OPTIONS"]
    allow_origins = ["*"]  # lock down later
  }
}

resource "aws_apigatewayv2_integration" "kb" {
  api_id                 = aws_apigatewayv2_api.kb.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.query.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "kb" {
  api_id    = aws_apigatewayv2_api.kb.id
  route_key = "POST /query"
  target    = "integrations/${aws_apigatewayv2_integration.kb.id}"
}

resource "aws_lambda_permission" "kb" {
  statement_id  = "AllowAPIGWInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.query.arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.kb.execution_arn}/*/*"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.kb.id
  name        = "default"
  auto_deploy = true
}

output "query_api_endpoint" {
  value = "${aws_apigatewayv2_api.kb.api_endpoint}/query"
}
