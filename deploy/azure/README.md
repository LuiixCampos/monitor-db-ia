# monitor-db-ia na Azure

Uma VM Linux com Docker roda o lab inteiro, do mesmo jeito que no PC. O `main.bicep` cria a rede,
a VM, um disco de dados e um desligamento automático diário. SSH, Grafana e n8n ficam liberados
só para o seu IP.

| Peça | O que é |
|---|---|
| VM | Ubuntu 24.04, `Standard_D4s_v5` (4 vCPU, 16 GB). Para ligar todos os bancos, use `Standard_D8s_v5` |
| Disco de dados | 128 GB Premium SSD em `/dados`, onde o Docker guarda os bancos |
| Rede | IP público fixo; NSG libera as portas 22, 3000 e 5678 só para o `meuIp` |
| IA | Sem GPU, o padrão é `claude` (API da Anthropic) ou `azure_openai`, pelo gateway de IA |
| Custo | VM desligada todo dia às 22h (`desligarAs`). Consulte o valor na calculadora da Azure antes de subir |

## Subir

Pré-requisitos: Azure CLI (`az`), uma assinatura e uma chave SSH (`ssh-keygen -t ed25519`).

1. Copie `parametros.exemplo.json` para `parametros.json` (ele não vai para o Git) e preencha:
   seu IP (`curl ifconfig.me`), a chave pública SSH, as senhas e a chave da API da Anthropic.
2. Crie o grupo e faça o deploy:
   ```
   az login
   az group create -n rg-monitor-db-ia -l brazilsouth
   az deployment group create -g rg-monitor-db-ia -f deploy/azure/main.bicep -p @deploy/azure/parametros.json
   ```
3. A saída mostra o IP e os endereços do Grafana e do n8n. A primeira subida leva uns 15 minutos
   (instalar o Docker, baixar as imagens e gerar a base). Para acompanhar:
   ```
   ssh azureuser@<endereço> "tail -f /var/log/subir-lab.log"
   ```
4. No n8n (porta 5678), importe os fluxos de `n8n/workflows` e configure as credenciais, igual ao PC.

## Ligar, desligar e apagar

```
az vm start      -g rg-monitor-db-ia -n monitordbia-vm
az vm deallocate -g rg-monitor-db-ia -n monitordbia-vm     # para de cobrar a VM (o disco continua)
az group delete  -n rg-monitor-db-ia                        # apaga tudo
```

## Cuidados

- O `.env` da VM é montado a partir dos parâmetros e fica nos metadados da VM (customData). Para um
  piloto real, guarde as senhas no Azure Key Vault.
- Com `iaProvedor = claude` ou `azure_openai`, o texto da query e o plano saem da VM para o provedor
  de IA. No lab a base é fictícia; num cliente, isso precisa de aprovação de segurança.
- Próximo passo para produção: trocar os bancos em container pelos serviços gerenciados (Azure Database
  for PostgreSQL Flexible Server, Azure SQL, Azure Database for MySQL) e cadastrá-los em `monitor.ambientes`.
