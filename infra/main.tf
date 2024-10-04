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

# Criação de um cluster ECS
resource "aws_ecs_cluster" "main" {
  name = "my-ecs-cluster"
}

# Criação de um repositório ECR
resource "aws_ecr_repository" "app" {
  name = "my-spring-native-app"
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
}

# Criação de um serviço ECS
resource "aws_ecs_service" "app" {
  name            = "my-app-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  network_configuration {
    subnets         = [
        "subnet-07954d01d2b0b3ff3"
    ]
    assign_public_ip = true
  }
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