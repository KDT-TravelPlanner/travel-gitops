mock_provider "aws" {}

variables {
  environment  = "dev"
  project_name = "kdt-travelplanner"
}

run "repository_is_immutable_and_scanned" {
  command = plan

  assert {
    condition     = aws_ecr_repository.this.image_tag_mutability == "IMMUTABLE"
    error_message = "Backend image tags must be immutable."
  }

  assert {
    condition     = aws_ecr_repository.this.image_scanning_configuration[0].scan_on_push
    error_message = "Backend images must be scanned on push."
  }

  assert {
    condition     = aws_ecr_repository.this.encryption_configuration[0].encryption_type == "AES256"
    error_message = "The repository must be encrypted."
  }
}
