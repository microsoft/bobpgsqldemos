targetScope = 'resourceGroup'

@minLength(1)
param environmentName string

@description('Azure region for the Function app resources.')
param location string = resourceGroup().location

@description('Existing Microsoft Foundry AIServices account name.')
param foundryAccountName string

@description('HorizonDB reader endpoint used by the least-privilege agent role.')
param databaseHost string

@description('HorizonDB primary endpoint used only by guarded action functions.')
param databaseWriteHost string

param databaseName string = 'postgres'
param databaseUser string = 'caldova_agent'

@secure()
param databasePassword string

param chatDeploymentName string = 'caldova-agent-chat'

var resourceToken = toLower(uniqueString(subscription().id, resourceGroup().id, environmentName, location))
var functionAppName = 'func-caldova-mcp-${take(resourceToken, 8)}'
var planName = 'plan-caldova-mcp-${take(resourceToken, 8)}'
var storageName = 'stcaldovamcp${take(resourceToken, 10)}'
var identityName = 'id-caldova-mcp-${take(resourceToken, 8)}'
var workspaceName = 'log-caldova-mcp-${take(resourceToken, 8)}'
var insightsName = 'appi-caldova-mcp-${take(resourceToken, 8)}'
var deploymentContainerName = 'app-package'
var tags = {
  'azd-env-name': environmentName
  workload: 'caldova-agent-mcp'
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {}
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deploymentContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

resource storageBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, identity.id, 'Storage Blob Data Owner')
  scope: storage
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
  }
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
  }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: insightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
  }
}

resource monitoringMetricsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(insights.id, identity.id, 'Monitoring Metrics Publisher')
  scope: insights
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
  }
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  tags: union(tags, {
    'azd-service-name': 'mcp'
  })
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    httpsOnly: true
    serverFarmId: plan.id
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: identity.id
          }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 10
      }
      runtime: {
        name: 'python'
        version: '3.12'
      }
    }
    siteConfig: {
      alwaysOn: false
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
    }
  }
  dependsOn: [
    deploymentContainer
    storageBlobOwner
  ]
}

resource appSettings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: functionApp
  name: 'appsettings'
  properties: {
    AzureWebJobsStorage__credential: 'managedidentity'
    AzureWebJobsStorage__clientId: identity.properties.clientId
    AzureWebJobsStorage__blobServiceUri: storage.properties.primaryEndpoints.blob
    APPLICATIONINSIGHTS_CONNECTION_STRING: insights.properties.ConnectionString
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'ClientId=${identity.properties.clientId};Authorization=AAD'
    AzureWebJobsFeatureFlags: 'EnableMcpCustomHandlerPreview'
    PYTHONPATH: '/home/site/wwwroot/.python_packages/lib/site-packages'
    CALDOVA_AGENT_DATABASE_HOST: databaseHost
    CALDOVA_AGENT_DATABASE_WRITE_HOST: databaseWriteHost
    CALDOVA_AGENT_DATABASE_NAME: databaseName
    CALDOVA_AGENT_DATABASE_USER: databaseUser
    CALDOVA_AGENT_DATABASE_PASSWORD: databasePassword
  }
}

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: foundryAccountName
}

resource chatDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundryAccount
  name: chatDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: 50
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-5-mini'
      version: '2025-08-07'
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
}

output AZURE_FUNCTION_NAME string = functionApp.name
output CALDOVA_MCP_URL string = 'https://${functionApp.properties.defaultHostName}/mcp'
output CALDOVA_FOUNDRY_ENDPOINT string = foundryAccount.properties.endpoint
output CALDOVA_FOUNDRY_MODEL string = chatDeployment.name