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