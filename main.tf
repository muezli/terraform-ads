trigger:
  branches:
    include:
      - main

pr:
  branches:
    include:
      - "*"

pool:
  vmImage: ubuntu-latest

variables:
  # Azure DevOps Service Connection name
  azureServiceConnection: "sc-azure-terraform"

  # Folder containing Terraform files
  workingDir: "infra"

  # tfvars path (relative to repo root)
  tfvarsFile: "infra/env/main.tfvars"

  # Optional: pin terraform version if your task supports it in your org;
  # if not, remove this and rely on agent/extension defaults.
  terraformVersion: "1.7.5"

  # AzureRM backend (state)
  backendResourceGroup: "rg-tfstate"
  backendStorageAccount: "sttfstateprod001"
  backendContainer: "tfstate"
  backendKey: "main.tfstate"

  # Azure DevOps Environment name (set approvals in Pipelines > Environments)
  adoEnvironmentName: "infra-main"

stages:
  # 1) INIT / VALIDATE
  - stage: init
    displayName: "Init / Connectivity / Validate"
    jobs:
      - job: init
        displayName: "Init + Validate"
        steps:
          - checkout: self

          # Minimal "connectivity/auth" check (very small bash)
          - task: AzureCLI@2
            displayName: "Azure connectivity check"
            inputs:
              azureSubscription: "$(azureServiceConnection)"
              scriptType: bash
              scriptLocation: inlineScript
              inlineScript: |
                set -e
                az account show -o table

          - task: TerraformCLI@2
            displayName: "terraform init"
            inputs:
              command: init
              workingDirectory: "$(workingDir)"
              backendType: azurerm
              backendServiceArm: "$(azureServiceConnection)"
              backendAzureRmResourceGroupName: "$(backendResourceGroup)"
              backendAzureRmStorageAccountName: "$(backendStorageAccount)"
              backendAzureRmContainerName: "$(backendContainer)"
              backendAzureRmKey: "$(backendKey)"

          - task: TerraformCLI@2
            displayName: "terraform fmt -check"
            inputs:
              command: fmt
              workingDirectory: "$(workingDir)"
              commandOptions: "-check -recursive"

          - task: TerraformCLI@2
            displayName: "terraform validate"
            inputs:
              command: validate
              workingDirectory: "$(workingDir)"

  # 2) PLAN
  - stage: plan
    displayName: "Plan"
    dependsOn: init
    condition: succeeded()
    jobs:
      - job: plan
        displayName: "Terraform Plan"
        steps:
          - checkout: self

          - task: TerraformCLI@2
            displayName: "terraform init"
            inputs:
              command: init
              workingDirectory: "$(workingDir)"
              backendType: azurerm
              backendServiceArm: "$(azureServiceConnection)"
              backendAzureRmResourceGroupName: "$(backendResourceGroup)"
              backendAzureRmStorageAccountName: "$(backendStorageAccount)"
              backendAzureRmContainerName: "$(backendContainer)"
              backendAzureRmKey: "$(backendKey)"

          - task: TerraformCLI@2
            displayName: "terraform plan (tfvars -> tfplan)"
            inputs:
              command: plan
              workingDirectory: "$(workingDir)"
              environmentServiceName: "$(azureServiceConnection)"
              commandOptions: >
                -input=false
                -var-file="$(Build.SourcesDirectory)/$(tfvarsFile)"
                -out="$(Build.ArtifactStagingDirectory)/tfplan"

          - publish: "$(Build.ArtifactStagingDirectory)/tfplan"
            artifact: "tfplan"

  # 3) APPLY (main only + gated by Environment approvals)
  - stage: apply
    displayName: "Apply (main only, gated)"
    dependsOn: plan
    condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))
    jobs:
      - deployment: apply
        displayName: "Terraform Apply"
        environment: "$(adoEnvironmentName)"   # approvals/checks live here
        strategy:
          runOnce:
            deploy:
              steps:
                - checkout: self

                - download: current
                  artifact: "tfplan"

                - task: TerraformCLI@2
                  displayName: "terraform init"
                  inputs:
                    command: init
                    workingDirectory: "$(workingDir)"
                    backendType: azurerm
                    backendServiceArm: "$(azureServiceConnection)"
                    backendAzureRmResourceGroupName: "$(backendResourceGroup)"
                    backendAzureRmStorageAccountName: "$(backendStorageAccount)"
                    backendAzureRmContainerName: "$(backendContainer)"
                    backendAzureRmKey: "$(backendKey)"

                - task: TerraformCLI@2
                  displayName: "terraform apply (from approved plan)"
                  inputs:
                    command: apply
                    workingDirectory: "$(workingDir)"
                    environmentServiceName: "$(azureServiceConnection)"
                    commandOptions: >
                      -input=false
                      "$(Pipeline.Workspace)/tfplan/tfplan"
