locals {
  scanner_images = {
    python = "ghcr.io/mvhungrydev/security-scanner-python:latest"
    java   = "ghcr.io/mvhungrydev/security-scanner-java:latest"
    dotnet = "ghcr.io/mvhungrydev/security-scanner-dotnet:latest"
    node   = "ghcr.io/mvhungrydev/security-scanner-node:latest"
  }
}
