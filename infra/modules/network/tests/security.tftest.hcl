mock_provider "aws" {}

variables {
  app_subnet_cidrs    = ["10.20.10.0/24", "10.20.11.0/24"]
  availability_zones  = ["ap-northeast-2a", "ap-northeast-2c"]
  data_subnet_cidrs   = ["10.20.20.0/24", "10.20.21.0/24"]
  environment         = "dev"
  project_name        = "kdt-travelplanner"
  public_subnet_cidrs = ["10.20.0.0/24", "10.20.1.0/24"]
  vpc_cidr            = "10.20.0.0/16"
}

run "network_is_private_by_default" {
  command = plan

  assert {
    condition     = aws_vpc.this.enable_dns_hostnames && aws_vpc.this.enable_dns_support
    error_message = "The VPC must provide DNS support and hostnames."
  }

  assert {
    condition = alltrue(concat(
      [for subnet in aws_subnet.public : !subnet.map_public_ip_on_launch],
      [for subnet in aws_subnet.app : !subnet.map_public_ip_on_launch],
      [for subnet in aws_subnet.data : !subnet.map_public_ip_on_launch],
    ))
    error_message = "No subnet may auto-assign public IP addresses."
  }

  assert {
    condition     = aws_route.public_default.destination_cidr_block == "0.0.0.0/0"
    error_message = "Public subnets must route through the Internet Gateway."
  }

  assert {
    condition     = length(aws_route_table.app) == 2 && length(aws_subnet.data) == 2
    error_message = "The application and data tiers must span two availability zones."
  }
}
