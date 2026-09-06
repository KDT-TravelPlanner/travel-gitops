mock_provider "aws" {}

variables {
  environment  = "dev"
  project_name = "kdt-travelplanner"
  service_name = "identity"
}

run "repository_is_immutable_and_scanned" {
  command = plan

  assert {
    condition     = aws_ecr_repository.this.name == "kdt-travelplanner-dev-identity"
    error_message = "Repository name must be project-environment-service."
  }

  assert {
    condition     = aws_ecr_repository.this.image_tag_mutability == "IMMUTABLE"
    error_message = "Image tags must be immutable."
  }

  assert {
    condition     = aws_ecr_repository.this.image_scanning_configuration[0].scan_on_push
    error_message = "Images must be scanned on push."
  }

  assert {
    condition     = aws_ecr_repository.this.encryption_configuration[0].encryption_type == "AES256"
    error_message = "The repository must be encrypted."
  }
}

run "rejects_uppercase_service_name" {
  command = plan

  variables {
    service_name = "Identity"
  }

  expect_failures = [var.service_name]
}
