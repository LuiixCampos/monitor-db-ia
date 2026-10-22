// =====================================================================
// monitor-db-ia na Azure: uma VM Linux com Docker rodando o lab inteiro.
// Acesso (SSH, Grafana e n8n) liberado só para o seu IP.
// Desliga sozinha todo dia no horário escolhido (economia).
//
//   az group create -n rg-monitor-db-ia -l brazilsouth
//   az deployment group create -g rg-monitor-db-ia -f deploy/azure/main.bicep -p @deploy/azure/parametros.json
// =====================================================================
@description('Prefixo dos recursos')
param nome string = 'monitordbia'

@description('Região (brazilsouth = São Paulo)')
param location string = resourceGroup().location

@description('Tamanho da VM. D4s_v5 (4 vCPU, 16 GB) roda PRD + HML + carga; D8s_v5 para ligar todos os bancos.')
param tamanhoVm string = 'Standard_D4s_v5'

@description('Usuário administrador da VM')
param usuario string = 'azureuser'

@description('Sua chave pública SSH (conteúdo do arquivo .pub)')
@secure()
param chaveSsh string

@description('Seu IP público (ex.: 200.100.50.25). Só ele acessa SSH, Grafana e n8n.')
param meuIp string

@description('Repositório do projeto')
param repositorio string = 'https://github.com/LuiixCampos/monitor-db-ia.git'

@description('Senha dos bancos do lab (só letras e números)')
@secure()
param senhaLab string

@description('Senha do usuário de monitoramento (só letras e números)')
@secure()
param senhaMonitor string

@description('Senha do SA do SQL Server (maiúscula, minúscula e número). Vazia se não usar o SQL Server.')
@secure()
param senhaSqlServer string = ''

@description('Chave de criptografia do n8n (texto longo aleatório)')
@secure()
param chaveN8n string

@allowed(['claude', 'azure_openai', 'ollama'])
@description('IA dos diagnósticos. Sem GPU na VM, use claude ou azure_openai.')
param iaProvedor string = 'claude'

@description('Chave da API da Anthropic (quando iaProvedor = claude)')
@secure()
param anthropicApiKey string = ''

@description('Perfis do docker compose que sobem junto (ex.: --profile carga --profile hml --profile mysql)')
param perfis string = '--profile carga --profile hml'

@description('Escala da base ampliada (1 = ~24 mi linhas por ambiente)')
param escalaBase string = '1'

@description('Tamanho do disco de dados (GB)')
param discoGb int = 128

@description('Horário para desligar a VM todo dia (HHmm). Vazio = não desliga.')
param desligarAs string = '2200'

var envLab = join([
  'POSTGRES_USER=labadmin'
  'POSTGRES_PASSWORD=${senhaLab}'
  'POSTGRES_DB=lab'
  'MONITOR_PASSWORD=${senhaMonitor}'
  'N8N_ENCRYPTION_KEY=${chaveN8n}'
  'GRAFANA_PASSWORD=${senhaLab}'
  'ORACLE_PASSWORD=${senhaLab}'
  'ORACLE_APP_PASSWORD=${senhaLab}'
  'MSSQL_SA_PASSWORD=${senhaSqlServer}'
  'ESCALA_BASE=${escalaBase}'
  'GANHO_MIN_PCT=20'
  'JANELA_PRD='
  'IA_PROVEDOR=${iaProvedor}'
  'IA_FALLBACK_OLLAMA=0'
  'ANTHROPIC_API_KEY=${anthropicApiKey}'
  ''
], '\n')

var cloudInit = replace(replace(replace(replace(loadTextContent('cloud-init.yaml'),
  '__ENV_B64__', base64(envLab)),
  '__USUARIO__', usuario),
  '__REPO__', repositorio),
  '__PERFIS__', perfis)

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${nome}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'ssh-grafana-n8n-so-meu-ip'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '${meuIp}/32'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['22', '3000', '5678']
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${nome}-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.20.0.0/16'] }
    subnets: [
      {
        name: 'lab'
        properties: {
          addressPrefix: '10.20.1.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

resource ip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${nome}-ip'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: { domainNameLabel: toLower('${nome}-${uniqueString(resourceGroup().id)}') }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${nome}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: { id: vnet.properties.subnets[0].id }
          publicIPAddress: { id: ip.id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: '${nome}-vm'
  location: location
  properties: {
    hardwareProfile: { vmSize: tamanhoVm }
    osProfile: {
      computerName: nome
      adminUsername: usuario
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${usuario}/.ssh/authorized_keys'
              keyData: chaveSsh
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 64
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
      dataDisks: [
        {
          lun: 0
          createOption: 'Empty'
          diskSizeGB: discoGb
          managedDisk: { storageAccountType: 'Premium_LRS' }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id }]
    }
  }
}

resource desligar 'Microsoft.DevTestLab/schedules@2018-09-15' = if (!empty(desligarAs)) {
  name: 'shutdown-computevm-${vm.name}'
  location: location
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: { time: desligarAs }
    timeZoneId: 'E. South America Standard Time'
    targetResourceId: vm.id
    notificationSettings: { status: 'Disabled' }
  }
}

output ipPublico string = ip.properties.ipAddress
output grafana string = 'http://${ip.properties.dnsSettings.fqdn}:3000'
output n8n string = 'http://${ip.properties.dnsSettings.fqdn}:5678'
output ssh string = 'ssh ${usuario}@${ip.properties.dnsSettings.fqdn}'
