provider "aws" {
  region = "us-east-1"  # Defina a região que você deseja usar
}

terraform {
  required_version = ">= 0.12"
  backend "s3" {
    bucket  = "terraform-state-bucket-lucas"
    key     = "terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}

################################ ALB ################################

# Criação de um Security Group para o ALB
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Allow HTTP traffic"
  vpc_id      = "vpc-037c0fa51acc1368b"  # Substitua pelo ID da sua VPC

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Criação do Load Balancer
resource "aws_lb" "app_lb" {
  name               = "app-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = ["subnet-07e598f791a16216b", "subnet-063d05a879a7ced1b"]  # Substitua pelos IDs dos seus subnets
}

# Criação de um Target Group para o ALB
resource "aws_lb_target_group" "app_tg" {
  name     = "app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = "vpc-037c0fa51acc1368b"  # Substitua pelo ID da sua VPC

  target_type = "ip"

  health_check {
    path                = "/actuator/health"  # Verifique se o caminho está correto
    interval            = 30                  # Intervalo entre os health checks
    timeout             = 5                   # Tempo limite para o health check
    healthy_threshold   = 2                   # Número de health checks bem-sucedidos para marcar como saudável
    unhealthy_threshold = 2                   # Número de health checks com falha para marcar como não saudável
    matcher             = "200"               # Código de resposta esperado
  }
}

# Criação de um Listener para o ALB
resource "aws_lb_listener" "app_listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }

  # Adicionando dependência explícita
  depends_on = [aws_lb.app_lb, aws_lb_target_group.app_tg]
}

################################ ECR ################################

# Criação de um repositório ECR
resource "aws_ecr_repository" "app" {
  name = "my-spring-native-app"
}

################################ ECS ################################

# Criação de um Security Group para o ECS
resource "aws_security_group" "ecs_sg" {
  name        = "ecs-sg"
  description = "Allow traffic from ALB"
  vpc_id      = "vpc-037c0fa51acc1368b"  # Substitua pelo ID da sua VPC

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]  # Permitir tráfego do ALB
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Criação de um cluster ECS
resource "aws_ecs_cluster" "main" {
  name = "my-ecs-cluster"
}

# Criação de uma task definition para o ECS
resource "aws_ecs_task_definition" "app" {
  family                   = "my-app-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  container_definitions    = jsonencode([
    {
      name      = "my-app-container"
      image     = "${aws_ecr_repository.app.repository_url}:latest"
      essential = true
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
        }
      ]
    }
  ])

  # Adicionando dependência explícita
  depends_on = [aws_ecr_repository.app, aws_iam_role.ecs_task_execution_role]
}

# Criação de um serviço ECS
resource "aws_ecs_service" "app" {
  name            = "my-app-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = ["subnet-07e598f791a16216b", "subnet-063d05a879a7ced1b"]
    security_groups = [aws_security_group.ecs_sg.id] # Security Group para o ECS
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app_tg.arn
    container_name   = "my-app-container"
    container_port   = 8080
  }

  # Adicionando dependência explícita
  depends_on = [aws_lb_target_group.app_tg, aws_ecs_task_definition.app]
}

# Criação de uma role para o ECS
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

################################ Cognito ################################

resource "aws_cognito_user_pool" "user_pool" {
  name = "my-user-pool"
}

# Cognito User Pool Client
resource "aws_cognito_user_pool_client" "user_pool_client" {
  name         = "my-user-pool-client"
  user_pool_id = aws_cognito_user_pool.user_pool.id
}

################################ API Gateway ################################

# Criação do API Gateway REST API
resource "aws_api_gateway_rest_api" "api" {
  name        = "my-api"
  description = "API Gateway for ALB"
}

# API Gateway Authorizer
resource "aws_api_gateway_authorizer" "cognito_authorizer" {
  name                   = "CognitoAuthorizer"
  rest_api_id            = aws_api_gateway_rest_api.api.id
  type                   = "COGNITO_USER_POOLS"
  provider_arns          = [aws_cognito_user_pool.user_pool.arn]
  identity_source        = "method.request.header.Authorization"
}

# Criação do recurso /api/test no API Gateway
resource "aws_api_gateway_resource" "api_test_resource" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "api"
}

# Criação do sub-recurso /test no API Gateway
resource "aws_api_gateway_resource" "api_test_subresource" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.api_test_resource.id
  path_part   = "test"
}

# Criação do método GET para o recurso /api/test
resource "aws_api_gateway_method" "get_api_test" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.api_test_subresource.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito_authorizer.id
}

# Integração do método GET com um backend (por exemplo, um ALB ou Lambda)
resource "aws_api_gateway_integration" "get_api_test_integration" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.api_test_subresource.id
  http_method             = aws_api_gateway_method.get_api_test.http_method
  integration_http_method = "GET"
  type                    = "HTTP"                                      # ou "AWS_PROXY" se for Lambda
  uri                     = "http://${aws_lb.app_lb.dns_name}/api/test" # URL do ALB ou outro backend

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }

  # Adicionando dependência explícita
  depends_on = [aws_lb.app_lb]
}

# Criação de uma resposta para o método GET
resource "aws_api_gateway_method_response" "get_api_test_response" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.api_test_subresource.id
  http_method = aws_api_gateway_method.get_api_test.http_method
  status_code = "200"
}

# Criação de uma resposta de integração
resource "aws_api_gateway_integration_response" "get_api_test_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.api_test_subresource.id
  http_method = aws_api_gateway_method.get_api_test.http_method
  status_code = aws_api_gateway_method_response.get_api_test_response.status_code

  # Adicionando dependência explícita
  depends_on = [aws_api_gateway_integration.get_api_test_integration]
}

# Criação de um deployment para o API Gateway
resource "aws_api_gateway_deployment" "api_deployment" {
  depends_on  = [aws_api_gateway_integration.get_api_test_integration]
  rest_api_id = aws_api_gateway_rest_api.api.id
  stage_name  = "prod"
}

################################ ROUTE 53 ################################

# Obter a zona hospedada no Route 53
data "aws_route53_zone" "my_zone" {
  name = "lucas-tech.com"  # Substitua pelo seu domínio
}

# Obter o estágio do API Gateway
data "aws_api_gateway_stage" "my_stage" {
  rest_api_id = aws_api_gateway_rest_api.api.id  # Referência ao API Gateway criado anteriormente
  stage_name  = "prod"

  # Adicionando dependência explícita
  depends_on = [aws_api_gateway_deployment.api_deployment]
}

# Criar um registro CNAME no Route 53
resource "aws_route53_record" "api_gateway_cname" {
  zone_id = data.aws_route53_zone.my_zone.zone_id
  name    = "api.lucas-tech.com"  # Subdomínio que você deseja criar
  type    = "CNAME"
  ttl     = 300  # Tempo de vida do registro DNS em segundos
  records = [data.aws_api_gateway_stage.my_stage.invoke_url]

  # Adicionando dependência explícita
  depends_on = [data.aws_api_gateway_stage.my_stage]
}