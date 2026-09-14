locals {
  name = "${var.project_name}-${var.environment}"

  subnet_lengths_valid = (
    length(var.public_subnet_cidrs) == length(var.availability_zones) &&
    length(var.app_subnet_cidrs) == length(var.availability_zones) &&
    length(var.data_subnet_cidrs) == length(var.availability_zones)
  )
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, { Name = "${local.name}-vpc" })

  lifecycle {
    precondition {
      condition     = local.subnet_lengths_valid
      error_message = "Each subnet CIDR list must have one entry per availability zone."
    }
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${local.name}-igw" })
}

resource "aws_subnet" "public" {
  count = length(var.availability_zones)

  availability_zone       = var.availability_zones[count.index]
  cidr_block              = var.public_subnet_cidrs[count.index]
  map_public_ip_on_launch = false
  vpc_id                  = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${local.name}-public-${count.index + 1}"
    Tier = "public"
  })
}

resource "aws_subnet" "app" {
  count = length(var.availability_zones)

  availability_zone       = var.availability_zones[count.index]
  cidr_block              = var.app_subnet_cidrs[count.index]
  map_public_ip_on_launch = false
  vpc_id                  = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${local.name}-app-${count.index + 1}"
    Tier = "application"
  })
}

resource "aws_subnet" "data" {
  count = length(var.availability_zones)

  availability_zone       = var.availability_zones[count.index]
  cidr_block              = var.data_subnet_cidrs[count.index]
  map_public_ip_on_launch = false
  vpc_id                  = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${local.name}-data-${count.index + 1}"
    Tier = "data"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${local.name}-public-rt" })
}

resource "aws_route" "public_default" {
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
  route_table_id         = aws_route_table.public.id
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  route_table_id = aws_route_table.public.id
  subnet_id      = aws_subnet.public[count.index].id
}

resource "aws_route_table" "app" {
  count = length(var.availability_zones)

  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${local.name}-app-${count.index + 1}-rt" })
}

resource "aws_route_table_association" "app" {
  count = length(aws_subnet.app)

  route_table_id = aws_route_table.app[count.index].id
  subnet_id      = aws_subnet.app[count.index].id
}

resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${local.name}-data-rt" })
}

resource "aws_route_table_association" "data" {
  count = length(aws_subnet.data)

  route_table_id = aws_route_table.data.id
  subnet_id      = aws_subnet.data[count.index].id
}
