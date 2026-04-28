Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

# Load .env
Get-Content (Join-Path $repoRoot ".env") |
    Where-Object { $_ -match "^\s*[^#\s]" -and $_ -match "=" } |
    ForEach-Object {
        $parts = $_ -split "=", 2
        [System.Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Split("#")[0].Trim(), "Process")
    }

# Pin bootstrap inputs (live mainnet addresses)
$env:BOOTSTRAP_VAULT       = "0xf79c2dc829cd3a2d8ceec353bdb1b2414ba1eee0"
$env:BOOTSTRAP_DISTRIBUTOR = "0x5757DA9014EE91055b244322a207EE6F066378B0"
$env:BOOTSTRAP_REAL_TREASURY = "0xe5f5Ef79b3DFF47EcDf7842645222e43AD0ed080"

$sender     = "0xe5f5Ef79b3DFF47EcDf7842645222e43AD0ed080"
$ledgerPath = "m/44'/60'/2'/0/0"

Write-Host "Broadcasting BootstrapRewards deploy via Ledger..." -ForegroundColor Cyan
Write-Host "  Vault         : $env:BOOTSTRAP_VAULT"
Write-Host "  Distributor   : $env:BOOTSTRAP_DISTRIBUTOR"
Write-Host "  Real Treasury : $env:BOOTSTRAP_REAL_TREASURY"
Write-Host ""

forge script script/DeployBootstrap.s.sol:DeployBootstrap `
    --rpc-url $env:ARBITRUM_RPC_URL `
    --sender $sender `
    --ledger --hd-paths $ledgerPath `
    --broadcast `
    --verify `
    --etherscan-api-key $env:ETHERSCAN_API_KEY `
    --verifier-url $env:ETHERSCAN_VERIFIER_URL `
    --slow 2>&1 | Tee-Object -FilePath bootstrap-deploy.log
